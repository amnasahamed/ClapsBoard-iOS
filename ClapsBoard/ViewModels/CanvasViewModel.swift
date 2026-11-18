//
//  CanvasViewModel.swift
//  ClapsBoard
//
//  View model for the canvas board with undo/redo support
//
//  HIG Compliance: Feedback & States - Haptic feedback for key actions
//

import SwiftUI
import PencilKit
import UIKit

/// Canvas view model with haptic feedback support (HIG: Feedback & States)
class CanvasViewModel: ObservableObject {
    // MARK: - Drawing State
    @Published var tool: ToolType = .pen {
        didSet {
            // HIG: Provide haptic feedback on tool change
            if tool != oldValue {
                impactFeedback.impactOccurred()
            }
            // The selection outline and its handles belong to the Select tool;
            // left behind, they sit on top of the canvas while drawing.
            if tool != .select, selectedElement != nil {
                selectedElement = nil
            }
        }
    }
    @Published var color: Color = DrawingConstants.defaultColor
    // Settings → Board → Default stroke.
    @Published var strokeWidth: CGFloat = (UserDefaults.standard.object(forKey: "defaultStrokeWidth") as? Double).map { CGFloat($0) } ?? DrawingConstants.defaultStrokeWidth
    /// Text size, separate from the pen width so changing one leaves the
    /// other alone. Same scale the text slider always used: font = value × 8.
    @Published var textSize: CGFloat = 3
    @Published var eraserSize: CGFloat = DrawingConstants.eraserSize
    @Published var textAlign: TextAlignment = .left
    @Published var currentSticker: String = DrawingConstants.stickers[0]
    @Published var gridStyle: GridStyle = .none
    @Published var showProperties: Bool = false
    @Published var isDrawing: Bool = false
    @Published var activeLayer: AnswerLayer = .base
    @Published var visibleLayers: Set<AnswerLayer> = [.base]
    
    // MARK: - Elements
    @Published var elements: [DrawingElement] = []
    @Published var selectedElement: DrawingElement?
    /// True while a finger is moving or resizing the selected element. The
    /// board reads it so the same drag doesn't also pan the canvas. Not
    /// published: it changes mid-gesture and nothing needs to redraw for it.
    var isManipulatingSelection = false
    
    // MARK: - Canvas Transform
    @Published var zoom: CGFloat = 1.0
    @Published var pan: CGPoint = .zero
    
    // MARK: - History for Undo/Redo
    private var history: [[DrawingElement]] = [[]]
    private var historyIndex: Int = 0
    private var historyDescriptions: [String] = ["Initial state"]

    var canUndo: Bool { historyIndex > 0 }
    var canRedo: Bool { historyIndex < history.count - 1 }

    /// Description of the action that will be undone
    var undoDescription: String? {
        guard historyIndex > 0 else { return nil }
        return historyDescriptions[historyIndex]
    }

    /// Description of the action that will be redone
    var redoDescription: String? {
        guard historyIndex < history.count - 1 else { return nil }
        return historyDescriptions[historyIndex + 1]
    }
    
    // MARK: - Haptic Feedback (HIG: Feedback & States)
    private let impactFeedback = UIImpactFeedbackGenerator(style: .light)
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private let notificationFeedback = UINotificationFeedbackGenerator()
    
    // MARK: - Persistence
    private let saveKey = "canvasElements"
    
    /// The Settings default last applied to `strokeWidth`.
    private var appliedDefaultStrokeWidth = UserDefaults.standard.object(forKey: "defaultStrokeWidth") as? Double
    private var defaultsObserver: NSObjectProtocol?

    init() {
        loadElements()
        // Prepare haptic engines
        impactFeedback.prepare()
        selectionFeedback.prepare()
        // Settings is a sheet over the board, so pick up a new "Default
        // stroke" as it changes instead of only at launch.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshDefaultStrokeWidth() }
        }
    }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    /// Applies the Settings default stroke only when that setting itself has
    /// changed, so a width picked in the board's own panel is not overwritten.
    func refreshDefaultStrokeWidth() {
        let stored = UserDefaults.standard.object(forKey: "defaultStrokeWidth") as? Double
        guard stored != appliedDefaultStrokeWidth else { return }
        appliedDefaultStrokeWidth = stored
        if let stored { strokeWidth = CGFloat(stored) }
    }
    
    // MARK: - Element Management
    func addElement(_ element: DrawingElement) {
        var layeredElement = element
        layeredElement.layer = activeLayer
        elements.append(layeredElement)
        commitChange()
    }

    func isVisible(_ element: DrawingElement) -> Bool {
        visibleLayers.contains(element.layer ?? .base)
    }
    
    func updateElement(_ element: DrawingElement) {
        if let index = elements.firstIndex(where: { $0.id == element.id }) {
            elements[index] = element
        }
    }
    
    func deleteElement(_ element: DrawingElement) {
        elements.removeAll { $0.id == element.id }
        selectedElement = nil
        commitChange()
    }
    
    func deleteSelectedElement() {
        guard let selected = selectedElement else { return }
        deleteElement(selected)
    }
    
    // MARK: - History Management
    func commitChange() {
        commitChange(description: generateActionDescription())
    }

    func commitChange(description: String) {
        // canUndo/canRedo read the unpublished history. A change that only
        // edits an element in place (move, resize) would otherwise leave the
        // Undo button showing its old state.
        objectWillChange.send()
        // Remove any redo history
        if historyIndex < history.count - 1 {
            history = Array(history.prefix(historyIndex + 1))
            historyDescriptions = Array(historyDescriptions.prefix(historyIndex + 1))
        }

        // Add current state with description
        history.append(elements)
        historyDescriptions.append(description)
        historyIndex = history.count - 1

        // Limit history size
        if history.count > 50 {
            history.removeFirst()
            historyDescriptions.removeFirst()
            historyIndex -= 1
        }

        saveElements()
    }

    /// Generates a human-readable description for the current action based on recent changes
    private func generateActionDescription() -> String {
        guard historyIndex > 0 else { return "Initial state" }

        // Compare current elements with previous state to determine action type
        let previousElements = history[historyIndex]
        let currentCount = elements.count
        let previousCount = previousElements.count

        if currentCount > previousCount {
            return "Drawing added"
        } else if currentCount < previousCount {
            return "Element deleted"
        } else {
            return "Element modified"
        }
    }
    
    func undo() {
        guard canUndo else { return }
        historyIndex -= 1
        elements = history[historyIndex]
        selectedElement = nil
        saveElements()
        // HIG: Haptic feedback for undo action
        selectionFeedback.selectionChanged()
    }
    
    func redo() {
        guard canRedo else { return }
        historyIndex += 1
        elements = history[historyIndex]
        selectedElement = nil
        saveElements()
        // HIG: Haptic feedback for redo action
        selectionFeedback.selectionChanged()
    }
    
    func clearBoard() {
        elements = []
        selectedElement = nil
        commitChange()
        // HIG: Haptic feedback for destructive clear action
        notificationFeedback.notificationOccurred(.warning)
    }
    
    /// Triggers haptic feedback for UI interactions
    func triggerHaptic(_ style: FeedbackStyle) {
        switch style {
        case .impact:
            impactFeedback.impactOccurred()
        case .selection:
            selectionFeedback.selectionChanged()
        case .success:
            notificationFeedback.notificationOccurred(.success)
        case .warning:
            notificationFeedback.notificationOccurred(.warning)
        case .error:
            notificationFeedback.notificationOccurred(.error)
        }
    }
    
    enum FeedbackStyle {
        case impact, selection, success, warning, error
    }
    
    // MARK: - Persistence
    func saveElements() {
        StorageService.shared.saveElements(elements)
    }
    
    func loadElements() {
        // 1. Try migration first
        if let migrated = StorageService.shared.migrateFromUserDefaults() {
            self.elements = migrated
            self.history = [migrated]
            return
        }
        
        // 2. Load from file system
        let loadedElements = StorageService.shared.loadElements().filter { !$0.isDeleted }
        self.elements = loadedElements
        self.history = [loadedElements]
    }

    /// Loads a saved lesson page and starts a fresh undo history for that page.
    /// Zoom and pan are kept unless `resetView` is set, so flipping between
    /// the pages of a lesson does not throw the view back to the centre.
    func loadLessonPage(_ page: LessonPage, resetView: Bool = false) {
        // Erased elements are only kept (flagged) so the eraser can be undone.
        // The undo history starts again here, so they can be dropped for good.
        let liveElements = page.elements.filter { !$0.isDeleted }
        elements = liveElements
        gridStyle = page.gridStyle
        selectedElement = nil
        history = [liveElements]
        historyDescriptions = ["Opened \(page.title)"]
        historyIndex = 0
        if resetView {
            zoom = 1
            pan = .zero
        }
        saveElements()
    }

    /// Media ids used by the open page, including states still reachable with undo/redo.
    var referencedMediaIds: Set<String> {
        var ids = Set(elements.compactMap(\.mediaId))
        for state in history {
            for element in state {
                if let id = element.mediaId { ids.insert(id) }
            }
        }
        return ids
    }
    
    // MARK: - Export
    
    /// Bounding box of everything currently shown on the canvas, or nil when
    /// there is nothing to show. Erased elements and elements on a hidden
    /// hint/solution layer are left out.
    func calculateContentBounds() -> CGRect? {
        boundsForExport(elements: elements.filter { !$0.isDeleted && isVisible($0) })
    }
    
    // MARK: - Export
    
    /// Exports the canvas to an image asynchronously (OPTIMIZED)
    /// - Parameters:
    ///   - customRect: Optional specific area to export. If nil, exports all content.
    ///   - completion: Called on main thread with the exported image
    func exportImageAsync(from customRect: CGRect? = nil, completion: @escaping (UIImage?) -> Void) {
        // Capture all needed data on main thread
        let exportBounds: CGRect
        if let rect = customRect {
            exportBounds = rect
        } else if let contentBounds = calculateContentBounds() {
            exportBounds = contentBounds
        } else {
            // Empty board: nil lets the caller say so instead of sharing a
            // blank white square.
            completion(nil)
            return
        }
        
        guard exportBounds.width > 0, exportBounds.height > 0 else {
            completion(nil)
            return
        }
        
        // Capture state before going to background thread
        let elementsSnapshot = elements.filter { !$0.isDeleted && isVisible($0) }
        let exportGridStyle = gridStyle
        
        // Preload all image data on main thread
        var preloadedImages: [UUID: UIImage] = [:]
        for element in elementsSnapshot where element.type == .image {
            if let data = element.imageData, let image = UIImage(data: data) {
                preloadedImages[element.id] = image
            }
        }
        
        // Move heavy rendering to background thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = self?.renderExportImage(
                bounds: exportBounds,
                elements: elementsSnapshot,
                gridStyle: exportGridStyle,
                preloadedImages: preloadedImages
            )
            
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }
    
    /// Synchronous export (for legacy compatibility) - OPTIMIZED
    func exportImage(from customRect: CGRect? = nil) -> UIImage? {
        let exportBounds: CGRect
        if let rect = customRect {
            exportBounds = rect
        } else if let contentBounds = calculateContentBounds() {
            exportBounds = contentBounds
        } else {
            return nil
        }
        
        guard exportBounds.width > 0, exportBounds.height > 0 else { return nil }
        
        let elementsSnapshot = elements.filter { !$0.isDeleted && isVisible($0) }
        
        // Preload images
        var preloadedImages: [UUID: UIImage] = [:]
        for element in elementsSnapshot where element.type == .image {
            if let data = element.imageData, let image = UIImage(data: data) {
                preloadedImages[element.id] = image
            }
        }
        
        return renderExportImage(
            bounds: exportBounds,
            elements: elementsSnapshot,
            gridStyle: gridStyle,
            preloadedImages: preloadedImages
        )
    }

    /// Renders a saved page without changing the currently displayed page.
    /// Returns nil for a page with nothing visible on it.
    func exportImage(elements pageElements: [DrawingElement], gridStyle pageGridStyle: GridStyle) -> UIImage? {
        let liveElements = pageElements.filter { !$0.isDeleted && visibleLayers.contains($0.layer ?? .base) }
        guard let bounds = boundsForExport(elements: liveElements) else { return nil }
        var images: [UUID: UIImage] = [:]
        for element in liveElements where element.type == .image {
            if let data = element.imageData, let image = UIImage(data: data) { images[element.id] = image }
        }
        return renderExportImage(bounds: bounds, elements: liveElements, gridStyle: pageGridStyle, preloadedImages: images)
    }

    private func boundsForExport(elements: [DrawingElement]) -> CGRect? {
        var result = CGRect.null
        for element in elements {
            // contentBounds measures text and centres stickers, the same way
            // they are drawn, so neither is cropped.
            var rect = element.contentBounds
            if element.rotation != 0 {
                let center = CGPoint(x: element.x + element.width / 2, y: element.y + element.height / 2)
                rect = rect.applying(CGAffineTransform(translationX: center.x, y: center.y)
                    .rotated(by: element.rotation)
                    .translatedBy(x: -center.x, y: -center.y))
            }
            guard !rect.isNull, !rect.isInfinite, rect.width.isFinite, rect.height.isFinite else { continue }
            result = result.union(rect)
        }
        guard !result.isNull else { return nil }
        // Padding, which also keeps a single dot from becoming a 0-pt image.
        return result.insetBy(dx: -50, dy: -50)
    }
    
    /// Core rendering logic - thread-safe
    private func renderExportImage(
        bounds: CGRect,
        elements: [DrawingElement],
        gridStyle: GridStyle,
        preloadedImages: [UUID: UIImage]
    ) -> UIImage? {
        // Calculate the best scale to keep the image high quality but under sharing limits
        // iOS share extensions often crash if the image is > 50MB (approx 4000x4000 pixels)
        let screenScale = UIScreen.main.scale
        let maxPixelSize: CGFloat = 4096 // Max 4k resolution for reliability
        
        let logicalWidth = bounds.width
        let logicalHeight = bounds.height
        let maxLogicalDim = max(logicalWidth, logicalHeight)
        
        // Target physical pixels = logicalDim * scale
        var targetScale = screenScale
        if maxLogicalDim * targetScale > maxPixelSize {
            targetScale = maxPixelSize / maxLogicalDim
        }
        
        let renderSize = CGSize(
            width: logicalWidth,
            height: logicalHeight
        )
        
        let rendererFormat = UIGraphicsImageRendererFormat.default()
        rendererFormat.opaque = true
        rendererFormat.scale = targetScale // Explicitly control output resolution
        
        let renderer = UIGraphicsImageRenderer(size: renderSize, format: rendererFormat)
        
        return renderer.image { context in
            // Apply translation to account for content bounds
            context.cgContext.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
            
            // Draw white background
            UIColor.white.setFill()
            UIRectFill(bounds)
            
            // Draw grid using optimized tiled pattern (instead of individual dots)
            if gridStyle.isVisible {
                drawOptimizedGrid(in: context.cgContext, bounds: bounds, style: gridStyle)
            }
            
            // Draw elements
            for element in elements {
                drawElementForExport(element, in: context.cgContext, preloadedImages: preloadedImages)
            }
        }
    }
    
    /// Optimized grid drawing using CGPattern
    private func drawOptimizedGrid(in context: CGContext, bounds: CGRect, style: GridStyle) {
        let gridSize: CGFloat = 40
        let dotSize: CGFloat = 2
        
        // Create a small tile image and use it as a pattern
        let tileRenderer = UIGraphicsImageRenderer(size: CGSize(width: gridSize, height: gridSize))
        let tileImage = tileRenderer.image { tileContext in
            let cgContext = tileContext.cgContext
            let gridColor = UIColor.systemGray3.withAlphaComponent(0.28)

            switch style {
            case .none:
                break

            case .dots:
                gridColor.setFill()
                let rect = CGRect(
                    x: (gridSize - dotSize) / 2,
                    y: (gridSize - dotSize) / 2,
                    width: dotSize,
                    height: dotSize
                )
                UIBezierPath(ovalIn: rect).fill()

            case .lines:
                gridColor.setStroke()
                cgContext.setLineWidth(0.6)
                cgContext.move(to: CGPoint(x: 0, y: 0))
                cgContext.addLine(to: CGPoint(x: gridSize, y: 0))
                cgContext.move(to: CGPoint(x: 0, y: 0))
                cgContext.addLine(to: CGPoint(x: 0, y: gridSize))
                cgContext.strokePath()

            case .graph:
                gridColor.setStroke()
                cgContext.setLineWidth(0.55)
                cgContext.move(to: CGPoint(x: 0, y: 0))
                cgContext.addLine(to: CGPoint(x: gridSize, y: 0))
                cgContext.move(to: CGPoint(x: 0, y: 0))
                cgContext.addLine(to: CGPoint(x: 0, y: gridSize))
                cgContext.strokePath()

                UIColor.systemGray3.withAlphaComponent(0.42).setStroke()
                cgContext.setLineWidth(1.0)
                cgContext.stroke(CGRect(x: 0, y: 0, width: gridSize, height: gridSize))

            case .isometric:
                gridColor.setStroke()
                cgContext.setLineWidth(0.55)
                cgContext.move(to: CGPoint(x: 0, y: gridSize * 0.5))
                cgContext.addLine(to: CGPoint(x: gridSize, y: 0))
                cgContext.move(to: CGPoint(x: 0, y: 0))
                cgContext.addLine(to: CGPoint(x: gridSize, y: gridSize * 0.5))
                cgContext.move(to: CGPoint(x: 0, y: gridSize))
                cgContext.addLine(to: CGPoint(x: gridSize, y: gridSize * 0.5))
                cgContext.strokePath()
            }
        }
        
        // Draw the pattern
        if let cgImage = tileImage.cgImage {
            context.saveGState()
            context.clip(to: bounds)
            
            // Calculate aligned start position
            let startX = floor(bounds.minX / gridSize) * gridSize
            let startY = floor(bounds.minY / gridSize) * gridSize
            
            // Draw tiled pattern
            for x in stride(from: startX, to: bounds.maxX, by: gridSize) {
                for y in stride(from: startY, to: bounds.maxY, by: gridSize) {
                    let tileRect = CGRect(x: x, y: y, width: gridSize, height: gridSize)
                    if bounds.intersects(tileRect) {
                        // Flip context for UIImage->CGImage coordinate system
                        context.saveGState()
                        context.translateBy(x: x, y: y + gridSize)
                        context.scaleBy(x: 1, y: -1)
                        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: gridSize, height: gridSize))
                        context.restoreGState()
                    }
                }
            }
            
            context.restoreGState()
        }
    }
    
    /// Draw element for export - uses preloaded images for thread safety
    private func drawElementForExport(_ element: DrawingElement, in context: CGContext, preloadedImages: [UUID: UIImage]) {
        context.saveGState()
        
        // Apply rotation if any
        if element.rotation != 0 {
            let center = CGPoint(x: element.x + element.width / 2, y: element.y + element.height / 2)
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: element.rotation)
            context.translateBy(x: -center.x, y: -center.y)
        }
        
        let color = UIColor(element.color.color)
        
        switch element.type {
        case .pen, .marker:
            // Match DrawingCanvas, which renders strokes at the element's own
            // opacity (that is what makes the highlighter translucent).
            context.setAlpha(element.opacity)
            if element.points.count == 1 {
                let point = element.points[0]
                let r = element.strokeWidth / 2
                let rect = CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
                
                color.setFill()
                let path = UIBezierPath(ovalIn: rect)
                path.fill()
                break
            }
            guard element.points.count > 1 else { break }
            let path = UIBezierPath()
            path.move(to: element.points[0])
            
            // Use quadratic curves for smoother lines
            if element.points.count > 2 {
                for i in 1..<element.points.count {
                    let mid = CGPoint(
                        x: (element.points[i-1].x + element.points[i].x) / 2,
                        y: (element.points[i-1].y + element.points[i].y) / 2
                    )
                    path.addQuadCurve(to: mid, controlPoint: element.points[i-1])
                }
                path.addLine(to: element.points.last!)
            } else {
                path.addLine(to: element.points[1])
            }
            
            // Without this the stroke used the context's default black.
            color.setStroke()
            path.lineWidth = element.strokeWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
            
        case .line:
            guard element.points.count >= 2 else { break }
            color.setStroke()
            let path = UIBezierPath()
            path.move(to: element.points[0])
            path.addLine(to: element.points[1])
            path.lineWidth = element.strokeWidth
            path.lineCapStyle = .round
            path.stroke()
            
        case .rectangle:
            let rect = CGRect(x: element.x, y: element.y, width: element.width, height: element.height)
            color.setStroke()
            let path = UIBezierPath(rect: rect)
            path.lineWidth = element.strokeWidth
            path.stroke()
            
        case .circle:
            let rect = CGRect(x: element.x, y: element.y, width: element.width, height: element.height)
            color.setStroke()
            let path = UIBezierPath(ovalIn: rect)
            path.lineWidth = element.strokeWidth
            path.stroke()
            
        case .text:
            if element.text != nil {
                let font = UIFont.systemFont(ofSize: element.textFontSize, weight: .medium)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: color
                ]
                // Line by line, each placed against the alignment anchor (x),
                // exactly as DrawingCanvas draws it.
                for (index, line) in element.textLines.enumerated() {
                    let nsLine = line as NSString
                    let lineWidth = nsLine.size(withAttributes: attributes).width
                    let lineX: CGFloat
                    switch element.textAlign {
                    case .left: lineX = element.x
                    case .center: lineX = element.x - lineWidth / 2
                    case .right: lineX = element.x - lineWidth
                    }
                    nsLine.draw(at: CGPoint(x: lineX, y: element.y + CGFloat(index) * font.lineHeight), withAttributes: attributes)
                }
            }
            
        case .sticker:
            if let sticker = element.text {
                let font = UIFont.systemFont(ofSize: element.stickerFontSize)
                let attributes: [NSAttributedString.Key: Any] = [.font: font]
                let nsString = sticker as NSString
                // The canvas draws stickers centred on x/y; do the same here.
                let size = nsString.size(withAttributes: attributes)
                nsString.draw(at: CGPoint(x: element.x - size.width / 2, y: element.y - size.height / 2), withAttributes: attributes)
            }
            
        case .image:
            // Use preloaded image for thread safety
            if let image = preloadedImages[element.id] {
                let rect = CGRect(x: element.x, y: element.y, width: element.width, height: element.height)
                image.draw(in: rect)
            }
            
        default:
            break
        }
        
        context.restoreGState()
    }
    
    /// Calculates the canvas coordinates for the current center of the screen
    func currentCanvasCenter(for screenSize: CGSize) -> CGPoint {
        // The canvas is 4000x4000 and initialized centered in the view
        // 1. Calculate how far we've panned relative to zoom
        let adjustedPanX = pan.x / zoom
        let adjustedPanY = pan.y / zoom
        
        // 2. The center of the 4000x4000 space is 2000, 2000
        // 3. Subtract the pan and adjust for screen size
        let centerX = 2000 - adjustedPanX
        let centerY = 2000 - adjustedPanY
        
        return CGPoint(x: centerX, y: centerY)
    }
}

// MARK: - Extension for Storage Loading
extension DrawingElement {
    /// Helper to load image data from storage on demand
    var imageData: Data? {
        guard let id = mediaId else { return nil }
        return StorageService.shared.loadMedia(id: id)
    }
}

// MARK: - Storage Service Implementation
/// Handles file-based persistence for whiteboard elements. 
/// Defined here to ensure visibility within the app target.
class StorageService {
    static let shared = StorageService()
    
    private let fileManager = FileManager.default
    private let fileName = "whiteboard_elements.json"
    private let mediaDirectoryName = "WhiteboardMedia"
    /// Serial, so an older snapshot can never be written after a newer one.
    private let saveQueue = DispatchQueue(label: "com.clapsboard.storage.elements", qos: .utility)
    
    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
    
    private var fileURL: URL {
        documentsDirectory.appendingPathComponent(fileName)
    }
    
    private var mediaDirectory: URL {
        documentsDirectory.appendingPathComponent(mediaDirectoryName)
    }
    
    private init() {
        createMediaDirectoryIfNeeded()
    }
    
    private func createMediaDirectoryIfNeeded() {
        if !fileManager.fileExists(atPath: mediaDirectory.path) {
            do {
                try fileManager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
            } catch {
                print("❌ Failed to create media directory: \(error)")
            }
        }
    }
    
    private var imageCache: [String: Data] = [:]
    
    func saveMedia(_ data: Data) -> String? {
        let id = UUID().uuidString
        let url = mediaDirectory.appendingPathComponent(id)
        do {
            try data.write(to: url, options: .atomic)
            imageCache[id] = data
            return id
        } catch {
            print("❌ Failed to save media: \(error.localizedDescription)")
            return nil
        }
    }
    
    func loadMedia(id: String) -> Data? {
        if let cached = imageCache[id] { return cached }
        let url = mediaDirectory.appendingPathComponent(id)
        
        // Check if file exists before attempting to read
        guard fileManager.fileExists(atPath: url.path) else {
            // Silently return nil - file may have been deleted or never saved
            return nil
        }
        
        do {
            let data = try Data(contentsOf: url)
            imageCache[id] = data
            return data
        } catch {
            print("❌ Failed to load media \(id): \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Deletes media files that nothing refers to any more. Conservative: it
    /// only looks inside this app's own media folder and only removes files
    /// named the way `saveMedia` names them (a bare UUID). Runs synchronously
    /// so a file saved a moment later can never be caught by a stale list.
    @discardableResult
    func purgeMedia(keeping referencedIds: Set<String>) -> Int {
        guard let names = try? fileManager.contentsOfDirectory(atPath: mediaDirectory.path) else { return 0 }
        var removed = 0
        for name in names where !referencedIds.contains(name) && UUID(uuidString: name) != nil {
            let url = mediaDirectory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            if (try? fileManager.removeItem(at: url)) != nil {
                imageCache[name] = nil
                removed += 1
            }
        }
        return removed
    }
    
    func saveElements(_ elements: [DrawingElement]) {
        saveQueue.async {
            do {
                let data = try JSONEncoder().encode(elements)
                try data.write(to: self.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                print("❌ Failed to save elements: \(error.localizedDescription)")
            }
        }
    }
    
    func loadElements() -> [DrawingElement] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([DrawingElement].self, from: data)
        } catch {
            print("❌ Failed to load elements: \(error.localizedDescription)")
            return []
        }
    }
    
    func migrateFromUserDefaults() -> [DrawingElement]? {
        let saveKey = "canvasElements"
        guard let data = UserDefaults.standard.data(forKey: saveKey) else { return nil }
        
        struct LegacyDrawingElement: Codable {
            let id: UUID
            var type: ToolType
            var points: [CGPoint]
            var x, y, width, height: CGFloat
            var text: String?
            var imageData: Data?
            var color: CodableColor
            var strokeWidth, opacity, rotation: CGFloat
            var isDeleted: Bool
            var textAlign: TextAlignment
        }
        
        do {
            let legacyElements = try JSONDecoder().decode([LegacyDrawingElement].self, from: data)
            let migratedElements = legacyElements.map { legacy in
                var mediaId: String? = nil
                if let imageData = legacy.imageData {
                    mediaId = self.saveMedia(imageData)
                }
                return DrawingElement(
                    id: legacy.id, type: legacy.type, points: legacy.points,
                    x: legacy.x, y: legacy.y, width: legacy.width, height: legacy.height,
                    text: legacy.text, mediaId: mediaId, color: legacy.color.color,
                    strokeWidth: legacy.strokeWidth, opacity: legacy.opacity,
                    rotation: legacy.rotation, isDeleted: legacy.isDeleted, textAlign: legacy.textAlign
                )
            }
            saveElements(migratedElements)
            UserDefaults.standard.removeObject(forKey: saveKey)
            return migratedElements
        } catch {
            print("❌ Migration failed: \(error.localizedDescription)")
            return nil
        }
    }
}
