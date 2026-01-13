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
        }
    }
    @Published var color: Color = DrawingConstants.defaultColor
    @Published var strokeWidth: CGFloat = DrawingConstants.defaultStrokeWidth
    @Published var eraserSize: CGFloat = DrawingConstants.eraserSize
    @Published var textAlign: TextAlignment = .left
    @Published var currentSticker: String = DrawingConstants.stickers[0]
    @Published var showGrid: Bool = true
    @Published var showProperties: Bool = true
    
    // MARK: - Elements
    @Published var elements: [DrawingElement] = []
    @Published var selectedElement: DrawingElement?
    
    // MARK: - Canvas Transform
    @Published var zoom: CGFloat = 1.0
    @Published var pan: CGPoint = .zero
    
    // MARK: - History for Undo/Redo
    private var history: [[DrawingElement]] = [[]]
    private var historyIndex: Int = 0
    
    var canUndo: Bool { historyIndex > 0 }
    var canRedo: Bool { historyIndex < history.count - 1 }
    
    // MARK: - Haptic Feedback (HIG: Feedback & States)
    private let impactFeedback = UIImpactFeedbackGenerator(style: .light)
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private let notificationFeedback = UINotificationFeedbackGenerator()
    
    // MARK: - Persistence
    private let saveKey = "canvasElements"
    
    init() {
        loadElements()
        // Prepare haptic engines
        impactFeedback.prepare()
        selectionFeedback.prepare()
    }
    
    // MARK: - Element Management
    func addElement(_ element: DrawingElement) {
        elements.append(element)
        commitChange()
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
        // Remove any redo history
        if historyIndex < history.count - 1 {
            history = Array(history.prefix(historyIndex + 1))
        }
        
        // Add current state
        history.append(elements)
        historyIndex = history.count - 1
        
        // Limit history size
        if history.count > 50 {
            history.removeFirst()
            historyIndex -= 1
        }
        
        saveElements()
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
        let loadedElements = StorageService.shared.loadElements()
        self.elements = loadedElements
        self.history = [loadedElements]
    }
    
    // MARK: - Export
    
    /// Calculates the bounding box of all elements on the canvas
    func calculateContentBounds() -> CGRect? {
        guard !elements.isEmpty else { return nil }
        
        let validElements = elements.filter { !$0.isDeleted }
        guard !validElements.isEmpty else { return nil }
        
        var minX: CGFloat = .infinity
        var minY: CGFloat = .infinity
        var maxX: CGFloat = -.infinity
        var maxY: CGFloat = -.infinity
        
        for element in validElements {
            var elementMinX, elementMinY, elementMaxX, elementMaxY: CGFloat
            
            // Check points for path-based elements
            if !element.points.isEmpty {
                elementMinX = element.points.map { $0.x }.min() ?? element.x
                elementMinY = element.points.map { $0.y }.min() ?? element.y
                elementMaxX = element.points.map { $0.x }.max() ?? (element.x + element.width)
                elementMaxY = element.points.map { $0.y }.max() ?? (element.y + element.height)
                
                // Add stroke width buffer for paths
                elementMinX -= element.strokeWidth / 2
                elementMinY -= element.strokeWidth / 2
                elementMaxX += element.strokeWidth / 2
                elementMaxY += element.strokeWidth / 2
            } else {
                // Check frame for object-based elements (rect, circle, text, image)
                var frame = CGRect(x: element.x, y: element.y, width: element.width, height: element.height)
                
                // Add stroke width buffer for shapes
                if element.type == .rectangle || element.type == .circle || element.type == .line {
                    frame = frame.insetBy(dx: -element.strokeWidth / 2, dy: -element.strokeWidth / 2)
                }
                
                // Account for rotation
                if element.rotation != 0 {
                   let center = CGPoint(x: frame.midX, y: frame.midY)
                   let transform = CGAffineTransform(translationX: center.x, y: center.y)
                       .rotated(by: element.rotation)
                       .translatedBy(x: -center.x, y: -center.y)
                   frame = frame.applying(transform)
                }
                
                elementMinX = frame.minX
                elementMinY = frame.minY
                elementMaxX = frame.maxX
                elementMaxY = frame.maxY
            }
            
            minX = min(minX, elementMinX)
            minY = min(minY, elementMinY)
            maxX = max(maxX, elementMaxX)
            maxY = max(maxY, elementMaxY)
        }
        
        // Add padding
        let padding: CGFloat = 50
        return CGRect(
            x: minX - padding,
            y: minY - padding,
            width: maxX - minX + (padding * 2),
            height: maxY - minY + (padding * 2)
        )
    }
    
    /// Exports the canvas to an image
    /// - Parameter customRect: Optional specific area to export. If nil, exports all content.
    func exportImage(from customRect: CGRect? = nil) -> UIImage? {
        // Determine export bounds
        let exportBounds: CGRect
        if let rect = customRect {
            exportBounds = rect
        } else {
            // Default to content bounds or a standard size if empty
            exportBounds = calculateContentBounds() ?? CGRect(x: 4000, y: 4000, width: 2000, height: 2000)
        }
        
        // Ensure bounds are valid
        guard exportBounds.width > 0, exportBounds.height > 0 else { return nil }
        
        let renderer = UIGraphicsImageRenderer(size: exportBounds.size)
        
        return renderer.image { context in
            // Translate context so the exportBounds origin becomes (0,0)
            context.cgContext.translateBy(x: -exportBounds.origin.x, y: -exportBounds.origin.y)
            
            // Draw white background
            UIColor.white.setFill()
            context.fill(exportBounds)
            
            // Draw grid if enabled (only if exporting visible area, otherwise usually clean export preferred)
            // For clean export, we usually hide grid. But if user wants it:
            if showGrid {
                let gridSize: CGFloat = 40
                let dotSize: CGFloat = 2
                let gridColor = UIColor.systemGray3.withAlphaComponent(0.3)
                gridColor.setFill()
                
                // Draw grid dots covering the export bounds
                let startX = floor(exportBounds.minX / gridSize) * gridSize
                let startY = floor(exportBounds.minY / gridSize) * gridSize
                
                for x in stride(from: startX, to: exportBounds.maxX, by: gridSize) {
                    for y in stride(from: startY, to: exportBounds.maxY, by: gridSize) {
                        // Draw a single dot in the center of the 40x40 tile
                        let dotRect = CGRect(x: x + (gridSize - dotSize)/2, 
                                           y: y + (gridSize - dotSize)/2, 
                                           width: dotSize, 
                                           height: dotSize)
                        
                        // Only draw if within export bounds
                        if exportBounds.contains(dotRect.origin) {
                            UIBezierPath(ovalIn: dotRect).fill()
                        }
                    }
                }
            }
            
            // Draw elements
            for element in elements where !element.isDeleted {
                drawElement(element, in: context.cgContext)
            }
        }
    }
    
    private func drawElement(_ element: DrawingElement, in context: CGContext) {
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
            guard element.points.count > 1 else { break }
            
            if element.type == .marker {
                context.setAlpha(0.4)
            }
            
            color.setStroke()
            let path = UIBezierPath()
            path.move(to: element.points[0])
            
            for point in element.points.dropFirst() {
                path.addLine(to: point)
            }
            
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
            if let text = element.text {
                let font = UIFont.systemFont(ofSize: element.strokeWidth * 8, weight: .medium)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: color
                ]
                let nsString = text as NSString
                nsString.draw(at: CGPoint(x: element.x, y: element.y), withAttributes: attributes)
            }
            
        case .sticker:
            if let sticker = element.text {
                let font = UIFont.systemFont(ofSize: element.strokeWidth * 10)
                let attributes: [NSAttributedString.Key: Any] = [.font: font]
                let nsString = sticker as NSString
                nsString.draw(at: CGPoint(x: element.x, y: element.y), withAttributes: attributes)
            }
            
        case .image:
            if let data = element.imageData, let image = UIImage(data: data) {
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
        // The canvas is 10000x10000 and initialized centered in the view
        // 1. Calculate how far we've panned relative to zoom
        let adjustedPanX = pan.x / zoom
        let adjustedPanY = pan.y / zoom
        
        // 2. The center of the 10000x10000 space is 5000, 5000
        // 3. Subtract the pan and adjust for screen size
        let centerX = 5000 - adjustedPanX
        let centerY = 5000 - adjustedPanY
        
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
        do {
            let data = try Data(contentsOf: url)
            imageCache[id] = data
            return data
        } catch {
            print("❌ Failed to load media \(id): \(error.localizedDescription)")
            return nil
        }
    }
    
    func saveElements(_ elements: [DrawingElement]) {
        DispatchQueue.global(qos: .background).async {
            do {
                let data = try JSONEncoder().encode(elements)
                try data.write(to: self.fileURL, options: [.atomic, .completeFileProtection])
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
