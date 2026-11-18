//
//  DrawingCanvas.swift
//  ClapsBoard
//
//  Native drawing canvas using PencilKit integration with custom rendering
//

import SwiftUI
import PencilKit

struct DrawingCanvas: View {
    @ObservedObject var viewModel: CanvasViewModel
    let isCanvasTransformGestureActive: Bool

    @State private var currentPath: [CGPoint] = []
    @State private var dragOffset: CGSize = .zero
    @State private var textInputPosition: CGPoint?
    @State private var textInput: String = ""
    @State private var showTextInput: Bool = false
    @State private var eraserCursorPosition: CGPoint?
    @State private var selectionDragOriginal: DrawingElement?
    @State private var selectionDidMove = false
    /// True once the current eraser drag has actually removed something.
    @State private var eraseDidChange = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Drawing canvas - renders elements at touch location
                Canvas { context, size in
                    // Draw existing elements
                    for element in viewModel.elements where !element.isDeleted && viewModel.isVisible(element) {
                        drawElement(element, in: &context)
                    }

                    // Draw current path (live drawing preview)
                    if !currentPath.isEmpty {
                        drawLivePreview(currentPath, in: &context)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)

                // Selection overlay for selected element
                // Only with the Select tool, and only while the element still
                // exists (it may have been erased or undone away).
                if viewModel.tool == .select,
                   let selected = viewModel.selectedElement, viewModel.isVisible(selected),
                   viewModel.elements.contains(where: { $0.id == selected.id && !$0.isDeleted }) {
                    SelectionOverlay(element: selected, viewModel: viewModel)
                }

                // Eraser cursor indicator
                if viewModel.tool == .eraser {
                    if let cursorPos = eraserCursorPosition {
                        ZStack {
                            Circle()
                                .fill(Color.red.opacity(0.1))
                            Circle()
                                .stroke(Color.red.opacity(0.5), lineWidth: 2)
                        }
                        .frame(width: viewModel.eraserSize, height: viewModel.eraserSize)
                        .position(cursorPos)
                        .allowsHitTesting(false)
                    }
                }

                // Text input overlay
                if showTextInput, let position = textInputPosition {
                    TextInputOverlay(
                        text: $textInput,
                        position: position,
                        color: viewModel.color,
                        fontSize: viewModel.textSize * 8,
                        onCommit: { commitText(at: position) },
                        onCancel: { cancelTextInput() }
                    )
                }
            }
            .contentShape(Rectangle())
            .gesture(drawingGesture)
            .clipped()
            .onChange(of: isCanvasTransformGestureActive) { _, isActive in
                if isActive {
                    cancelActiveCanvasInteraction()
                }
            }
        }
    }

    // MARK: - Gestures
    private var drawingGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // Touch location IS the drawing point - canvas fills the view
                handleDragChanged(value)
            }
            .onEnded { value in
                handleDragEnded(value)
            }
    }

    // MARK: - Gesture Handlers
    private func handleDragChanged(_ value: DragGesture.Value) {
        guard !isCanvasTransformGestureActive else {
            cancelActiveCanvasInteraction()
            return
        }

        let location = value.location

        // The Pan tool only moves the board (BoardView handles the drag). It
        // must not collect points for a stroke or fade the toolbars.
        if viewModel.tool == .pan { return }

        if viewModel.tool != .select {
            viewModel.isDrawing = true
        }

        switch viewModel.tool {
        case .select:
            if selectionDragOriginal == nil {
                guard let found = topmostElement(at: location) else {
                    viewModel.selectedElement = nil
                    return
                }

                if viewModel.selectedElement?.id != found.id {
                    viewModel.selectedElement = found
                    viewModel.triggerHaptic(.selection)
                }
                selectionDragOriginal = found
                selectionDidMove = false
                viewModel.isManipulatingSelection = true
            }

            guard let original = selectionDragOriginal else { return }
            if abs(value.translation.width) > 1 || abs(value.translation.height) > 1 {
                selectionDidMove = true
                let moved = movedElement(original, by: value.translation)
                viewModel.updateElement(moved)
                viewModel.selectedElement = moved
            }

        case .eraser:
            eraserCursorPosition = location
            eraseAt(location)

        case .text:
            // Text tool just records tap position
            break

        case .sticker:
            // Sticker placement on tap
            break

        default:
            // Drawing tools - only add new points, not every drag changed
            // This prevents duplicate points from being added too frequently
            if currentPath.isEmpty || distance(from: currentPath.last!, to: location) > 2 {
                currentPath.append(location)
            }
        }
    }

    private func distance(from: CGPoint, to: CGPoint) -> CGFloat {
        sqrt(pow(to.x - from.x, 2) + pow(to.y - from.y, 2))
    }

    private func handleDragEnded(_ value: DragGesture.Value) {
        guard !isCanvasTransformGestureActive else {
            cancelActiveCanvasInteraction()
            return
        }

        let location = value.location

        defer {
            viewModel.isDrawing = false
        }

        switch viewModel.tool {
        case .select:
            if selectionDidMove {
                viewModel.commitChange(description: "Element moved")
            }
            selectionDragOriginal = nil
            selectionDidMove = false
            viewModel.isManipulatingSelection = false

        case .eraser:
            eraserCursorPosition = nil
            commitEraseIfNeeded()

        case .text:
            textInputPosition = location
            showTextInput = true

        case .sticker:
            let element = DrawingElement(
                type: .sticker,
                x: location.x,
                y: location.y,
                width: 60, // Larger default size
                height: 60,
                text: viewModel.currentSticker,
                strokeWidth: 4
            )
            viewModel.addElement(element)

        case .rectangle:
            if currentPath.count >= 2 {
                let start = currentPath.first!
                let end = currentPath.last!
                let element = DrawingElement(
                    type: .rectangle,
                    x: min(start.x, end.x),
                    y: min(start.y, end.y),
                    width: abs(end.x - start.x),
                    height: abs(end.y - start.y),
                    color: viewModel.color,
                    strokeWidth: viewModel.strokeWidth
                )
                viewModel.addElement(element)
            }

        case .circle:
            if currentPath.count >= 2 {
                let start = currentPath.first!
                let end = currentPath.last!
                let element = DrawingElement(
                    type: .circle,
                    x: min(start.x, end.x),
                    y: min(start.y, end.y),
                    width: abs(end.x - start.x),
                    height: abs(end.y - start.y),
                    color: viewModel.color,
                    strokeWidth: viewModel.strokeWidth
                )
                viewModel.addElement(element)
            }

        case .line:
            if currentPath.count >= 2 {
                let element = DrawingElement(
                    type: .line,
                    points: [currentPath.first!, currentPath.last!],
                    color: viewModel.color,
                    strokeWidth: viewModel.strokeWidth
                )
                viewModel.addElement(element)
            }

        case .pen, .marker:
            if !currentPath.isEmpty {
                let element = DrawingElement(
                    type: viewModel.tool,
                    points: currentPath,
                    color: viewModel.color,
                    strokeWidth: viewModel.strokeWidth,
                    opacity: viewModel.tool == .marker ? 0.4 : 1.0
                )
                viewModel.addElement(element)
            }

        default:
            break
        }

        currentPath = []
    }

    /// Adds one undo step for an eraser drag, and only if it removed something.
    private func commitEraseIfNeeded() {
        guard eraseDidChange else { return }
        eraseDidChange = false
        viewModel.commitChange(description: "Erased")
    }

    private func cancelActiveCanvasInteraction() {
        currentPath = []
        eraserCursorPosition = nil
        // A pinch that interrupts an erase keeps what was already erased, as
        // one undoable step, instead of leaving it outside the undo history.
        commitEraseIfNeeded()

        if let original = selectionDragOriginal, selectionDidMove {
            viewModel.updateElement(original)
            viewModel.selectedElement = original
        }

        selectionDragOriginal = nil
        selectionDidMove = false
        viewModel.isManipulatingSelection = false
        viewModel.isDrawing = false
    }
    
    // MARK: - Drawing Functions
    private func drawElement(_ element: DrawingElement, in context: inout GraphicsContext) {
        let color = element.color.color
        
        switch element.type {
        case .pen, .marker:
            if element.points.count == 1 {
                let point = element.points[0]
                let r = element.strokeWidth / 2
                context.fill(
                    Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)),
                    with: .color(color.opacity(element.opacity))
                )
                return
            }
            guard element.points.count > 1 else { return }
            
            var path = Path()
            path.move(to: element.points[0])
            
            for point in element.points.dropFirst() {
                path.addLine(to: point)
            }
            
            context.stroke(
                path,
                with: .color(color.opacity(element.opacity)),
                style: StrokeStyle(
                    lineWidth: element.strokeWidth,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            
        case .line:
            guard element.points.count >= 2 else { return }
            
            var path = Path()
            path.move(to: element.points[0])
            path.addLine(to: element.points[1])
            
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: element.strokeWidth, lineCap: .round)
            )
            
        case .rectangle:
            let rect = CGRect(x: element.x, y: element.y, width: element.width, height: element.height)
            context.stroke(
                Path(rect),
                with: .color(color),
                style: StrokeStyle(lineWidth: element.strokeWidth)
            )
            
        case .circle:
            let rect = CGRect(x: element.x, y: element.y, width: element.width, height: element.height)
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(color),
                style: StrokeStyle(lineWidth: element.strokeWidth)
            )
            
        case .text:
            if element.text != nil {
                // x is the alignment anchor: left edge, centre or right edge.
                // Drawn line by line so multi-line text lines up the same way
                // (and the same way as the export).
                let fontSize = element.textFontSize
                let lineHeight = UIFont.systemFont(ofSize: fontSize, weight: .medium).lineHeight
                let anchor: UnitPoint
                switch element.textAlign {
                case .left: anchor = .topLeading
                case .center: anchor = .top
                case .right: anchor = .topTrailing
                }
                for (index, line) in element.textLines.enumerated() where !line.isEmpty {
                    context.draw(
                        Text(line)
                            .font(.system(size: fontSize, weight: .medium))
                            .foregroundColor(color),
                        at: CGPoint(x: element.x, y: element.y + CGFloat(index) * lineHeight),
                        anchor: anchor
                    )
                }
            }
            
        case .sticker:
            if let sticker = element.text {
                context.draw(
                    Text(sticker)
                        .font(.system(size: element.stickerFontSize)),
                    at: CGPoint(x: element.x, y: element.y),
                    anchor: .center
                )
            }
            
        case .image:
            if let data = element.imageData, let uiImage = UIImage(data: data) {
                let rect = CGRect(x: element.x, y: element.y, width: element.width, height: element.height)
                context.draw(Image(uiImage: uiImage), in: rect)
            }
            
        default:
            break
        }
    }
    
    private func drawLivePreview(_ points: [CGPoint], in context: inout GraphicsContext) {
        guard points.count > 1 else { return }
        
        let color = viewModel.color
        
        switch viewModel.tool {
        case .pen, .marker:
            if points.count == 1 {
                let point = points[0]
                let r = viewModel.strokeWidth / 2
                context.fill(
                    Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)),
                    with: .color(color.opacity(viewModel.tool == .marker ? 0.4 : 1.0))
                )
                return
            }
            
            var path = Path()
            path.move(to: points[0])
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            
            let opacity = viewModel.tool == .marker ? 0.4 : 1.0
            context.stroke(
                path,
                with: .color(color.opacity(opacity)),
                style: StrokeStyle(
                    lineWidth: viewModel.strokeWidth,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            
        case .line:
            var path = Path()
            path.move(to: points.first!)
            path.addLine(to: points.last!)
            
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: viewModel.strokeWidth, lineCap: .round)
            )
            
        case .rectangle:
            let start = points.first!
            let end = points.last!
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            context.stroke(
                Path(rect),
                with: .color(color),
                style: StrokeStyle(lineWidth: viewModel.strokeWidth)
            )
            
        case .circle:
            let start = points.first!
            let end = points.last!
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(color),
                style: StrokeStyle(lineWidth: viewModel.strokeWidth)
            )
            
        default:
            break
        }
    }
    
    // MARK: - Helper Functions
    private func topmostElement(at point: CGPoint) -> DrawingElement? {
        viewModel.elements.reversed().first { element in
            !element.isDeleted && viewModel.isVisible(element) && hitTest(point, for: element)
        }
    }

    private func hitTest(_ point: CGPoint, for element: DrawingElement) -> Bool {
        let threshold: CGFloat = 20
        
        // Fast-path: Bounding box check first
        let rect = element.selectionBounds.insetBy(dx: -threshold, dy: -threshold)
        guard rect.contains(point) else { return false }
        
        // Precise-path: Point/Path check
        switch element.type {
        case .pen, .marker, .line:
            // Check if point is near any segment of the path
            if element.points.count > 1 {
                for i in 0..<element.points.count - 1 {
                    let start = element.points[i]
                    let end = element.points[i + 1]
                    if distanceToLineSegment(point: point, start: start, end: end) < threshold + (element.strokeWidth / 2) {
                        return true
                    }
                }
            } else if let firstPoint = element.points.first {
                // Check if near single point (dot)
                let distance = hypot(firstPoint.x - point.x, firstPoint.y - point.y)
                return distance < threshold + (element.strokeWidth / 2)
            }
            return false

        case .rectangle, .circle:
            // Shapes are outlines: hit only near the line, so things drawn
            // inside a later rectangle or circle can still be picked.
            return element.distanceToShapeOutline(from: point) < threshold + (element.strokeWidth / 2)
            
        default:
            // For text, stickers and images, bounding box is sufficient
            return true
        }
    }
    
    private func distanceToLineSegment(point: CGPoint, start: CGPoint, end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        
        if dx == 0 && dy == 0 {
            return hypot(point.x - start.x, point.y - start.y)
        }
        
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / (dx * dx + dy * dy)))
        let projection = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
        
        return hypot(point.x - projection.x, point.y - projection.y)
    }

    private func movedElement(_ element: DrawingElement, by offset: CGSize) -> DrawingElement {
        var modified = element
        modified.x += offset.width
        modified.y += offset.height
        modified.points = modified.points.map { CGPoint(x: $0.x + offset.width, y: $0.y + offset.height) }
        return modified
    }
    
    private func eraseAt(_ point: CGPoint) {
        let eraserRadius = viewModel.eraserSize / 2
        
        var elementsChanged = false
        var updatedElements = viewModel.elements
        
        for i in 0..<updatedElements.count {
            if updatedElements[i].isDeleted || !viewModel.isVisible(updatedElements[i]) { continue }
            
            let element = updatedElements[i]
            let strokeBuffer = element.strokeWidth / 2
            
            let shouldDelete: Bool
            switch element.type {
            case .pen, .marker, .line:
                // Fast filter on the stored bounding box before walking the points
                let reach = eraserRadius + strokeBuffer
                let rect = CGRect(x: element.x, y: element.y, width: element.width, height: element.height)
                    .standardized.insetBy(dx: -reach, dy: -reach)
                guard rect.contains(point) else { continue }

                // Check if eraser is near any segment of the path
                var foundMatch = false
                if element.points.count > 1 {
                    for j in 0..<element.points.count - 1 {
                        let distance = distanceToLineSegment(point: point, start: element.points[j], end: element.points[j+1])
                        if distance < reach {
                            foundMatch = true
                            break
                        }
                    }
                } else if let firstPoint = element.points.first {
                    // Single point fallback
                    foundMatch = hypot(firstPoint.x - point.x, firstPoint.y - point.y) < reach
                }
                shouldDelete = foundMatch

            case .rectangle, .circle:
                // Only when the eraser touches the drawn outline, not anywhere
                // inside the shape's bounding box.
                shouldDelete = element.distanceToShapeOutline(from: point) < eraserRadius + strokeBuffer

            case .text, .sticker:
                // Real drawn bounds (text is measured, stickers are centred on
                // x/y), touched by the eraser circle.
                let bounds = element.contentBounds
                let nearestX = min(max(point.x, bounds.minX), bounds.maxX)
                let nearestY = min(max(point.y, bounds.minY), bounds.maxY)
                shouldDelete = hypot(point.x - nearestX, point.y - nearestY) < eraserRadius

            default:
                // Images (diagrams, photos) are never erased by rubbing; they
                // are removed with Select and the trash button.
                shouldDelete = false
            }
            
            if shouldDelete {
                updatedElements[i].isDeleted = true
                elementsChanged = true
                if viewModel.selectedElement?.id == element.id {
                    viewModel.selectedElement = nil
                }
                // HIG: Provide subtle haptic feedback when an element is successfully erased
                viewModel.triggerHaptic(.impact)
            }
        }
        
        if elementsChanged {
            viewModel.elements = updatedElements
            eraseDidChange = true
        }
    }
    
    private func commitText(at position: CGPoint) {
        guard !textInput.isEmpty else {
            cancelTextInput()
            return
        }
        
        let element = DrawingElement(
            type: .text,
            x: position.x,
            y: position.y,
            text: textInput,
            color: viewModel.color,
            strokeWidth: viewModel.textSize,
            textAlign: viewModel.textAlign
        )
        viewModel.addElement(element)
        cancelTextInput()
    }
    
    private func cancelTextInput() {
        showTextInput = false
        textInput = ""
        textInputPosition = nil
    }
}

fileprivate extension DrawingElement {
    var selectionBounds: CGRect {
        let minimumSize: CGFloat = 40

        switch type {
        case .pen, .marker, .line:
            guard !points.isEmpty else {
                return CGRect(x: x, y: y, width: minimumSize, height: minimumSize)
            }

            let minX = points.map(\.x).min() ?? x
            let minY = points.map(\.y).min() ?? y
            let maxX = points.map(\.x).max() ?? x
            let maxY = points.map(\.y).max() ?? y
            let strokePadding = max(strokeWidth, 8)
            return CGRect(
                x: minX,
                y: minY,
                width: max(maxX - minX, minimumSize),
                height: max(maxY - minY, minimumSize)
            )
            .insetBy(dx: -strokePadding, dy: -strokePadding)

        case .sticker:
            let drawn = measuredStickerBounds
            let side = max(drawn.width, drawn.height, 44)
            return CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side)

        case .text:
            return measuredTextBounds

        default:
            return CGRect(x: x, y: y, width: max(width, minimumSize), height: max(height, minimumSize))
        }
    }

    func resized(from oldBounds: CGRect, to newBounds: CGRect) -> DrawingElement {
        var modified = self
        let oldWidth = max(oldBounds.width, 1)
        let oldHeight = max(oldBounds.height, 1)

        switch type {
        case .pen, .marker, .line:
            modified.points = points.map { point in
                let xProgress = (point.x - oldBounds.minX) / oldWidth
                let yProgress = (point.y - oldBounds.minY) / oldHeight
                return CGPoint(
                    x: newBounds.minX + xProgress * newBounds.width,
                    y: newBounds.minY + yProgress * newBounds.height
                )
            }
            // Keep the stored box (used by the eraser's quick filter) in
            // step with the points rather than with the padded outline.
            let xs = modified.points.map(\.x), ys = modified.points.map(\.y)
            modified.x = xs.min() ?? newBounds.minX
            modified.y = ys.min() ?? newBounds.minY
            modified.width = (xs.max() ?? modified.x) - modified.x
            modified.height = (ys.max() ?? modified.y) - modified.y

        case .sticker:
            // Scale from the current size (strokeWidth sets the emoji size)
            // instead of deriving a size from the outline, which made the
            // sticker jump 50% bigger on the first touch.
            let scale = newBounds.width / oldWidth
            modified.x = newBounds.midX
            modified.y = newBounds.midY
            modified.width = width * scale
            modified.height = height * scale
            modified.strokeWidth = max(1.5, strokeWidth * scale)

        case .text:
            // Same idea: scale the current font size. x stays the alignment
            // anchor, so it follows the matching edge of the new outline.
            let scale = newBounds.height / oldHeight
            modified.strokeWidth = max(1, strokeWidth * scale)
            modified.y = newBounds.minY
            switch textAlign {
            case .left: modified.x = newBounds.minX
            case .center: modified.x = newBounds.midX
            case .right: modified.x = newBounds.maxX
            }

        default:
            modified.x = newBounds.minX
            modified.y = newBounds.minY
            modified.width = newBounds.width
            modified.height = newBounds.height
        }

        return modified
    }
}

// MARK: - Selection Overlay
struct SelectionOverlay: View {
    let element: DrawingElement
    @ObservedObject var viewModel: CanvasViewModel
    
    @State private var resizeOriginal: DrawingElement?
    @State private var resizeDidMove = false
    
    var body: some View {
        GeometryReader { _ in
            let bounds = elementBounds

            ZStack {
                // Selection rectangle
                RoundedRectangle(cornerRadius: 6)
                    .stroke(AppTheme.accent.opacity(0.9), style: StrokeStyle(lineWidth: 1.6, dash: [6, 4]))
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(AppTheme.accent.opacity(0.035))
                    )
                    .frame(width: bounds.width + 20, height: bounds.height + 20)
                    .position(x: bounds.midX, y: bounds.midY)
                    .allowsHitTesting(false)

                // Resize handles
                ForEach(HandlePosition.allCases, id: \.self) { position in
                    ResizeHandle(position: position)
                        .position(handlePosition(for: position, in: bounds))
                        .gesture(resizeGesture(for: position))
                }

                // Delete button
                Button(action: viewModel.deleteSelectedElement) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.red.opacity(0.92), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Delete selected element")
                .accessibilityHint("Removes the selected drawing element from the canvas")
                .position(x: bounds.maxX + 24, y: bounds.minY - 24)
            }
            .accessibilityLabel("Selected element")
            .accessibilityHint("Drag the element to move it, drag corner handles to resize it, or tap delete to remove it")
        }
    }
    
    private var elementBounds: CGRect {
        element.selectionBounds
    }
    
    private func handlePosition(for position: HandlePosition, in bounds: CGRect) -> CGPoint {
        switch position {
        case .topLeft: return CGPoint(x: bounds.minX - 10, y: bounds.minY - 10)
        case .topRight: return CGPoint(x: bounds.maxX + 10, y: bounds.minY - 10)
        case .bottomLeft: return CGPoint(x: bounds.minX - 10, y: bounds.maxY + 10)
        case .bottomRight: return CGPoint(x: bounds.maxX + 10, y: bounds.maxY + 10)
        }
    }

    private func resizeGesture(for position: HandlePosition) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if resizeOriginal == nil {
                    resizeOriginal = element
                }
                viewModel.isManipulatingSelection = true
                // Resting a finger on a handle is not a resize: change nothing
                // (and add no undo step) until it has really moved.
                if !resizeDidMove {
                    guard hypot(value.translation.width, value.translation.height) > 3 else { return }
                    resizeDidMove = true
                }
                guard let original = resizeOriginal else { return }
                let resized = resizedElement(original, from: position, by: value.translation)
                viewModel.updateElement(resized)
                viewModel.selectedElement = resized
            }
            .onEnded { _ in
                if resizeDidMove {
                    viewModel.commitChange(description: "Element resized")
                }
                resizeOriginal = nil
                resizeDidMove = false
                viewModel.isManipulatingSelection = false
            }
    }

    private func resizedElement(_ element: DrawingElement, from handle: HandlePosition, by translation: CGSize) -> DrawingElement {
        let originalBounds = element.selectionBounds
        let minSize: CGFloat = 28
        var newBounds = originalBounds

        switch handle {
        case .topLeft:
            newBounds.origin.x += translation.width
            newBounds.origin.y += translation.height
            newBounds.size.width -= translation.width
            newBounds.size.height -= translation.height
            if newBounds.width < minSize {
                newBounds.origin.x = originalBounds.maxX - minSize
                newBounds.size.width = minSize
            }
            if newBounds.height < minSize {
                newBounds.origin.y = originalBounds.maxY - minSize
                newBounds.size.height = minSize
            }

        case .topRight:
            newBounds.origin.y += translation.height
            newBounds.size.width += translation.width
            newBounds.size.height -= translation.height
            newBounds.size.width = max(minSize, newBounds.width)
            if newBounds.height < minSize {
                newBounds.origin.y = originalBounds.maxY - minSize
                newBounds.size.height = minSize
            }

        case .bottomLeft:
            newBounds.origin.x += translation.width
            newBounds.size.width -= translation.width
            newBounds.size.height += translation.height
            if newBounds.width < minSize {
                newBounds.origin.x = originalBounds.maxX - minSize
                newBounds.size.width = minSize
            }
            newBounds.size.height = max(minSize, newBounds.height)

        case .bottomRight:
            newBounds.size.width += translation.width
            newBounds.size.height += translation.height
            newBounds.size.width = max(minSize, newBounds.width)
            newBounds.size.height = max(minSize, newBounds.height)
        }

        // Images must not be squashed, and text and stickers only have one
        // size, so these scale uniformly from the opposite corner.
        if element.type == .image || element.type == .text || element.type == .sticker,
           originalBounds.width > 0, originalBounds.height > 0 {
            let smallestScale = min(1, minSize / min(originalBounds.width, originalBounds.height))
            let scale = max(newBounds.width / originalBounds.width,
                            newBounds.height / originalBounds.height,
                            smallestScale)
            let size = CGSize(width: originalBounds.width * scale, height: originalBounds.height * scale)
            switch handle {
            case .topLeft:
                newBounds = CGRect(origin: CGPoint(x: originalBounds.maxX - size.width, y: originalBounds.maxY - size.height), size: size)
            case .topRight:
                newBounds = CGRect(origin: CGPoint(x: originalBounds.minX, y: originalBounds.maxY - size.height), size: size)
            case .bottomLeft:
                newBounds = CGRect(origin: CGPoint(x: originalBounds.maxX - size.width, y: originalBounds.minY), size: size)
            case .bottomRight:
                newBounds = CGRect(origin: originalBounds.origin, size: size)
            }
        }

        return element.resized(from: originalBounds, to: newBounds)
    }
}

enum HandlePosition: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
}

struct ResizeHandle: View {
    let position: HandlePosition

    private var accessibilityLabel: String {
        switch position {
        case .topLeft: return "Resize handle, top left corner"
        case .topRight: return "Resize handle, top right corner"
        case .bottomLeft: return "Resize handle, bottom left corner"
        case .bottomRight: return "Resize handle, bottom right corner"
        }
    }

    private var accessibilityHint: String {
        switch position {
        case .topLeft: return "Drag to resize from top left"
        case .topRight: return "Drag to resize from top right"
        case .bottomLeft: return "Drag to resize from bottom left"
        case .bottomRight: return "Drag to resize from bottom right"
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 28, height: 28)
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)

            Circle()
                .fill(Color.white.opacity(0.96))
                .frame(width: 18, height: 18)
                .overlay(Circle().stroke(AppTheme.accent, lineWidth: 2))
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(.allowsDirectInteraction)
    }
}

// MARK: - Text Input Overlay
struct TextInputOverlay: View {
    @Binding var text: String
    let position: CGPoint
    let color: Color
    let fontSize: CGFloat
    let onCommit: () -> Void
    let onCancel: () -> Void
    
    @FocusState private var isFocused: Bool
    @State private var localPosition: CGPoint
    
    init(text: Binding<String>, position: CGPoint, color: Color, fontSize: CGFloat, onCommit: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self._text = text
        self.position = position
        self.color = color
        self.fontSize = fontSize
        self.onCommit = onCommit
        self.onCancel = onCancel
        self._localPosition = State(initialValue: position)
    }
    
    /// The ink colour, unless it is too pale to read on the white field.
    private var fieldTextColor: Color {
        let ink = CodableColor(color)
        let luminance = 0.299 * ink.red + 0.587 * ink.green + 0.114 * ink.blue
        return luminance > 0.8 ? Color(hex: "1e293b") : color
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Semi-transparent overlay to indicate text mode is active
            Color.black.opacity(0.1)
                .ignoresSafeArea()
                .accessibilityLabel("Text input background")
                .accessibilityHint("Tap outside the text field to commit or cancel")
                .onTapGesture {
                    if !text.isEmpty {
                        onCommit()
                    } else {
                        onCancel()
                    }
                }

            // Inline text input at tap location
            VStack(alignment: .leading, spacing: 0) {
                // Text input field
                TextField("Type here...", text: $text, axis: .vertical)
                    .font(.system(size: max(20, fontSize), weight: .medium))
                    .foregroundColor(fieldTextColor)
                    .tint(AppTheme.accent)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .padding(12)
                    .frame(minWidth: 200, maxWidth: 400)
                    // The board is always light, so the field is too: in Dark
                    // Mode systemBackground put dark ink on a black field.
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(AppTheme.accent, lineWidth: 2)
                    )
                    .accessibilityLabel("Text input field")
                    .accessibilityHint("Enter your text here, then tap the checkmark to add it to the canvas")

                // Action buttons
                HStack(spacing: 8) {
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.red, .white)
                    }
                    .accessibilityLabel("Cancel text input")
                    .accessibilityHint("Tap to discard the text and close the input")

                    Spacer()

                    Text("Tap outside to add")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(action: onCommit) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.green, .white)
                    }
                    .disabled(text.isEmpty)
                    .opacity(text.isEmpty ? 0.5 : 1.0)
                    .accessibilityLabel("Add text to canvas")
                    .accessibilityHint("Tap to add the entered text to the canvas")
                }
                .padding(.top, 8)
                .padding(.horizontal, 4)
            }
            .padding(8)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            // Light placeholder, caption and material regardless of appearance.
            .environment(\.colorScheme, .light)
            .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            // Just above the tap, kept off the canvas's top-left edge. There is
            // deliberately no upper limit: the old one assumed a 4000-pt canvas
            // and pushed the box about 1000 pt away from every tap, off-screen.
            .position(
                x: max(localPosition.x, 150),
                y: max(localPosition.y - 60, 100)
            )
        }
        .accessibilityLabel("Text input overlay")
        .ignoresSafeArea()
        .onAppear { 
            isFocused = true
            // Adjust position if too close to the top-left edge
            localPosition = CGPoint(
                x: max(position.x, 150),
                y: max(position.y, 150)
            )
        }
    }
}

#Preview {
    DrawingCanvas(
        viewModel: CanvasViewModel(),
        isCanvasTransformGestureActive: false
    )
}
