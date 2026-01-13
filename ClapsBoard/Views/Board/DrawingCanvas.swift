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
    
    @State private var currentPath: [CGPoint] = []
    @State private var dragOffset: CGSize = .zero
    @State private var textInputPosition: CGPoint?
    @State private var textInput: String = ""
    @State private var showTextInput: Bool = false
    @State private var eraserCursorPosition: CGPoint?
    
    @GestureState private var dragState: CGSize = .zero
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Infinite Canvas (10000x10000) - Unlimited drawing space with pan & zoom
                Canvas { context, size in
                    // Draw existing elements
                    for element in viewModel.elements where !element.isDeleted {
                        drawElement(element, in: &context)
                    }
                    
                    // Draw current path (live drawing preview)
                    if !currentPath.isEmpty {
                        drawLivePreview(currentPath, in: &context)
                    }
                }
                .frame(width: 10000, height: 10000)
                .gesture(drawingGesture)
                
                // Selection overlay for selected element
                if let selected = viewModel.selectedElement {
                    SelectionOverlay(element: selected, viewModel: viewModel)
                }
                
                // Eraser cursor indicator
                if viewModel.tool == .eraser, let cursorPos = eraserCursorPosition {
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
                
                // Text input overlay
                if showTextInput, let position = textInputPosition {
                    TextInputOverlay(
                        text: $textInput,
                        position: position,
                        color: viewModel.color,
                        fontSize: viewModel.strokeWidth * 8,
                        onCommit: { commitText(at: position) },
                        onCancel: { cancelTextInput() }
                    )
                }
            }
            .clipped()
            .contentShape(Rectangle())
        }
    }
    
    // MARK: - Gestures
    private var drawingGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                handleDragChanged(value)
            }
            .onEnded { value in
                handleDragEnded(value)
            }
    }
    
    // MARK: - Gesture Handlers
    private func handleDragChanged(_ value: DragGesture.Value) {
        let location = value.location
        
        switch viewModel.tool {
        case .select:
            // Improved selection logic: always try to find the topmost element at location
            var foundElement: DrawingElement?
            for element in viewModel.elements.reversed() {
                if !element.isDeleted && hitTest(location, for: element) {
                    foundElement = element
                    break
                }
            }
            
            // If we found a new element, select it
            if let found = foundElement {
                if viewModel.selectedElement?.id != found.id {
                    viewModel.selectedElement = found
                }
            } else {
                // If we tapped on empty space, deselect
                viewModel.selectedElement = nil
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
            // Drawing tools
            currentPath.append(location)
        }
    }
    
    private func handleDragEnded(_ value: DragGesture.Value) {
        let location = value.location
        
        switch viewModel.tool {
        case .select:
            // Handle movement if dragging happened (already handled by SelectionOverlay in part)
            // But we ensure we have the right selection
            break
            
        case .eraser:
            eraserCursorPosition = nil
            viewModel.commitChange()
            
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
    
    // MARK: - Drawing Functions
    private func drawElement(_ element: DrawingElement, in context: inout GraphicsContext) {
        let color = element.color.color
        
        switch element.type {
        case .pen, .marker:
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
            if let text = element.text {
                context.draw(
                    Text(text)
                        .font(.system(size: element.strokeWidth * 8, weight: .medium))
                        .foregroundColor(color),
                    at: CGPoint(x: element.x, y: element.y),
                    anchor: .topLeading
                )
            }
            
        case .sticker:
            if let sticker = element.text {
                context.draw(
                    Text(sticker)
                        .font(.system(size: element.strokeWidth * 10)),
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
    private func hitTest(_ point: CGPoint, for element: DrawingElement) -> Bool {
        let threshold: CGFloat = 20
        
        // Fast-path: Bounding box check first
        let rect = CGRect(x: element.x - threshold/2, y: element.y - threshold/2,
                          width: element.width + threshold, height: element.height + threshold)
        guard rect.contains(point) else { return false }
        
        // Precise-path: Point/Path check
        switch element.type {
        case .pen, .marker, .line:
            // Check if point is near any segment of the path
            for i in 0..<element.points.count - 1 {
                let start = element.points[i]
                let end = element.points[i + 1]
                if distanceToLineSegment(point: point, start: start, end: end) < threshold {
                    return true
                }
            }
            return false
            
        default:
            // For text, stickers, images, and shapes, bounding box is sufficient
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
    
    private func eraseAt(_ point: CGPoint) {
        let eraserRadius = viewModel.eraserSize / 2
        let eraserRect = CGRect(x: point.x - eraserRadius, y: point.y - eraserRadius,
                                width: eraserRadius * 2, height: eraserRadius * 2)
        
        var elementsChanged = false
        var updatedElements = viewModel.elements
        
        // HIG: Spatial optimization - only check elements that intersect the eraser's current region
        for i in 0..<updatedElements.count {
            if updatedElements[i].isDeleted { continue }
            
            let element = updatedElements[i]
            let rect = CGRect(x: element.x, y: element.y, width: element.width, height: element.height)
            
            // Fast filter: Bounding box check
            guard rect.intersects(eraserRect) else { continue }
            
            // Precise check
            let shouldDelete: Bool
            switch element.type {
            case .pen, .marker, .line:
                shouldDelete = element.points.contains { p in
                    hypot(p.x - point.x, p.y - point.y) < eraserRadius
                }
            default:
                shouldDelete = true // Bounds intersection is enough for text/stickers/shapes
            }
            
            if shouldDelete {
                updatedElements[i].isDeleted = true
                elementsChanged = true
            }
        }
        
        if elementsChanged {
            viewModel.elements = updatedElements
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
            strokeWidth: viewModel.strokeWidth,
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

// MARK: - Selection Overlay
struct SelectionOverlay: View {
    let element: DrawingElement
    @ObservedObject var viewModel: CanvasViewModel
    
    @State private var isDragging = false
    @GestureState private var dragOffset: CGSize = .zero
    
    var body: some View {
        GeometryReader { _ in
            let bounds = elementBounds
            
            ZStack {
                // Selection rectangle
                Rectangle()
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    .frame(width: bounds.width + 20, height: bounds.height + 20)
                    .position(x: bounds.midX + dragOffset.width, y: bounds.midY + dragOffset.height)
                
                // Resize handles
                ForEach(HandlePosition.allCases, id: \.self) { position in
                    ResizeHandle(position: position)
                        .position(handlePosition(for: position, in: bounds))
                }
                
                // Delete button
                Button(action: viewModel.deleteSelectedElement) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.red, in: Circle())
                }
                .position(x: bounds.maxX + 20, y: bounds.minY - 20)
            }
            .gesture(
                DragGesture()
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        moveElement(by: value.translation)
                    }
            )
        }
    }
    
    private var elementBounds: CGRect {
        CGRect(x: element.x, y: element.y, width: max(element.width, 40), height: max(element.height, 40))
    }
    
    private func handlePosition(for position: HandlePosition, in bounds: CGRect) -> CGPoint {
        switch position {
        case .topLeft: return CGPoint(x: bounds.minX - 10, y: bounds.minY - 10)
        case .topRight: return CGPoint(x: bounds.maxX + 10, y: bounds.minY - 10)
        case .bottomLeft: return CGPoint(x: bounds.minX - 10, y: bounds.maxY + 10)
        case .bottomRight: return CGPoint(x: bounds.maxX + 10, y: bounds.maxY + 10)
        }
    }
    
    private func moveElement(by offset: CGSize) {
        guard var modified = viewModel.elements.first(where: { $0.id == element.id }) else { return }
        modified.x += offset.width
        modified.y += offset.height
        modified.points = modified.points.map { CGPoint(x: $0.x + offset.width, y: $0.y + offset.height) }
        viewModel.updateElement(modified)
        viewModel.commitChange()
        viewModel.selectedElement = modified
    }
}

enum HandlePosition: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
}

struct ResizeHandle: View {
    let position: HandlePosition
    
    var body: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(Color.blue, lineWidth: 2))
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
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            // Semi-transparent overlay to indicate text mode is active
            Color.black.opacity(0.1)
                .ignoresSafeArea()
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
                    .foregroundColor(color)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .padding(12)
                    .frame(minWidth: 200, maxWidth: 400)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.blue, lineWidth: 2)
                    )
                
                // Action buttons
                HStack(spacing: 8) {
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.red, .white)
                    }
                    .accessibilityLabel("Cancel")
                    
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
                    .accessibilityLabel("Add text")
                }
                .padding(.top, 8)
                .padding(.horizontal, 4)
            }
            .padding(8)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            // Smart positioning to keep on screen (now using 10,000x10,000 bounds)
            .position(
                x: min(max(localPosition.x, 150), 9850),
                y: min(max(localPosition.y - 60, 100), 9900)
            )
        }
        .ignoresSafeArea()
        .onAppear { 
            isFocused = true
            // Adjust position if too close to edges
            localPosition = CGPoint(
                x: min(max(position.x, 150), 9850),
                y: min(max(position.y, 150), 9850)
            )
        }
    }
}

#Preview {
    DrawingCanvas(viewModel: CanvasViewModel())
}
