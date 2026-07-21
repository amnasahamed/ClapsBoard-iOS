//
//  BoardView.swift
//  ClapsBoard
//
//  Main whiteboard view with drawing canvas and tools
//

import SwiftUI
import PencilKit
import UIKit

struct BoardView: View {
    @ObservedObject var viewModel: CanvasViewModel
    @ObservedObject var cameraManager: CameraManager
    @EnvironmentObject var appState: AppState

    // iPad optimization: adaptive canvas size for larger screens
    @Environment(\.horizontalSizeClass) var horizontalSizeClass

    @State private var showClearConfirm = false
    @State private var showExportSheet = false
    @State private var showMenu = false
    @State private var exportedImage: UIImage?
    @State private var isExporting = false
    @GestureState private var magnificationState: CGFloat = 1.0
    @GestureState private var isMagnificationGestureActive = false
    @State private var lastPanValue: DragGesture.Value?
    @State private var isSuppressingDrawingForCanvasTransform = false

    // Haptic feedback for shake gesture
    private let notificationFeedback = UINotificationFeedbackGenerator()

    // iPad split-view state persistence
    @SceneStorage("canvasZoom") private var storedZoom: Double = 1.0
    @SceneStorage("canvasPanX") private var storedPanX: Double = 0
    @SceneStorage("canvasPanY") private var storedPanY: Double = 0

    // Adaptive canvas size: 15000 for iPad (regular), 10000 for iPhone (compact)
    private var canvasSize: CGFloat {
        horizontalSizeClass == .regular ? 15000 : 10000
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ZStack {
                    CanvasBackground(gridStyle: viewModel.gridStyle)
                        .frame(width: canvasSize, height: canvasSize)

                    // Drawing Canvas
                    DrawingCanvas(
                        viewModel: viewModel,
                        isCanvasTransformGestureActive: isMagnificationGestureActive || isSuppressingDrawingForCanvasTransform
                    )
                        .frame(width: canvasSize, height: canvasSize)
                }
                .scaleEffect(viewModel.zoom * magnificationState)
                .offset(x: viewModel.pan.x, y: viewModel.pan.y)
                .gesture(
                    MagnificationGesture()
                        .updating($magnificationState) { value, state, _ in
                            state = value
                        }
                        .updating($isMagnificationGestureActive) { _, state, _ in
                            state = true
                        }
                        .onEnded { value in
                            isSuppressingDrawingForCanvasTransform = true
                            let newZoom = viewModel.zoom * value
                            let clampedZoom = max(0.1, min(10.0, newZoom))

                            // Haptic feedback at zoom limits
                            if newZoom != clampedZoom {
                                let generator = UIImpactFeedbackGenerator(style: .rigid)
                                generator.impactOccurred()
                            }

                            viewModel.zoom = clampedZoom
                            releaseDrawingSuppressionAfterCanvasTransform()
                        }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if viewModel.tool == .pan || viewModel.tool == .select {
                                if let last = lastPanValue {
                                    let deltaX = value.translation.width - last.translation.width
                                    let deltaY = value.translation.height - last.translation.height
                                    viewModel.pan.x += deltaX
                                    viewModel.pan.y += deltaY
                                }
                                lastPanValue = value
                            }
                        }
                        .onEnded { _ in
                            lastPanValue = nil
                        }
                )
                .simultaneousGesture(
                    TapGesture(count: 2)
                        .onEnded {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                viewModel.zoom = 1.0
                                viewModel.pan = .zero
                            }
                            let generator = UIImpactFeedbackGenerator(style: .medium)
                            generator.impactOccurred()
                        }
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .ignoresSafeArea()

                // Empty canvas state
                if viewModel.elements.isEmpty && !viewModel.isDrawing {
                    Text("Tap anywhere to begin")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.46))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Tap anywhere to begin")
                }

                controlsLayer(in: geometry)

                // Export loading overlay
                if isExporting {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()

                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)
                        Text("Exporting...")
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                    .padding(30)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }

                // Zoom level indicator
                if viewModel.zoom != 1.0 {
                    VStack {
                        HStack {
                            Spacer()
                            Text("\(Int(viewModel.zoom * 100))%")
                                .font(.caption.weight(.medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(8)
                        }
                        Spacer()
                    }
                    .accessibilityLabel("Canvas zoom level \(Int(viewModel.zoom * 100)) percent")
                    .accessibilityHint("Double tap to reset zoom to 100 percent")
                    .transition(.opacity.combined(with: .scale))
                }
            }
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.2), value: viewModel.zoom)
        // Keyboard shortcuts for undo/redo (Cmd+Z for undo, Cmd+Shift+Z for redo)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Button("Undo") {
                    if viewModel.canUndo {
                        viewModel.undo()
                    }
                }
                .keyboardShortcut("z", modifiers: .command)
                .hidden()

                Button("Redo") {
                    if viewModel.canRedo {
                        viewModel.redo()
                    }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .hidden()
            }
        }
        // Clear Confirmation
        .alert("Clear Whiteboard?", isPresented: $showClearConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Clear All", role: .destructive) {
                viewModel.clearBoard()
            }
        } message: {
            Text("This will remove all drawings and notes permanently.")
        }
        // Export Sheet
        .sheet(isPresented: $showExportSheet, onDismiss: {
            // Clean up exported image to free memory and reset state
            exportedImage = nil
        }) {
            if let image = exportedImage {
                ShareSheet(items: [image])
            }
        }
    }

    private func releaseDrawingSuppressionAfterCanvasTransform() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            isSuppressingDrawingForCanvasTransform = false
        }
    }

    private func handleExport() {
        // Prevent multiple simultaneous export operations
        // Fixes: "Trying to perform UISocialActivity but there is already an activity performing"
        guard !isExporting && !showExportSheet else {
            print("⚠️ Export already in progress, ignoring duplicate request")
            return
        }

        // Show loading state
        isExporting = true

        // Use async export to prevent UI blocking
        viewModel.exportImageAsync { image in
            // Update state on main thread
            isExporting = false
            if let image = image {
                exportedImage = image
                showExportSheet = true
            }
        }
    }

    @ViewBuilder
    private func controlsLayer(in geometry: GeometryProxy) -> some View {
        if geometry.size.width > geometry.size.height {
            landscapeControlRails(in: geometry)
        } else {
            portraitControlStack(in: geometry)
        }
    }

    @ViewBuilder
    private func portraitControlStack(in geometry: GeometryProxy) -> some View {
        let safeAreaInsets = resolvedSafeAreaInsets(for: geometry)
        let headerY = safeAreaInsets.top + 43
        let bottomControlPadding = safeAreaInsets.bottom + 8
        let propertiesPanelMaxWidth = min(geometry.size.width - 32, 420)

        Group {
            headerControls(orientation: .horizontal)
                .position(x: geometry.size.width / 2, y: headerY)

            VStack(spacing: 16) {
                if viewModel.showProperties && viewModel.tool.supportsProperties {
                    PropertiesPanel(viewModel: viewModel)
                        .frame(maxWidth: propertiesPanelMaxWidth)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.showProperties)
                }

                ToolbarView(viewModel: viewModel)
                    .zIndex(1)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, bottomControlPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private func landscapeControlRails(in geometry: GeometryProxy) -> some View {
        let metrics = BoardFloatingRailMetrics(
            containerSize: geometry.size,
            safeAreaInsets: resolvedSafeAreaInsets(for: geometry),
            interfaceOrientation: activeInterfaceOrientation
        )

        return BoardFloatingSideRails(metrics: metrics) {
            headerControls(orientation: .vertical)
        } trailing: {
            HStack(spacing: metrics.controlClusterSpacing) {
                if viewModel.showProperties && viewModel.tool.supportsProperties {
                    PropertiesPanel(viewModel: viewModel)
                        .frame(width: metrics.propertiesPanelWidth)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.showProperties)
                }

                ToolbarView(viewModel: viewModel, orientation: .vertical)
            }
        }
    }

    private func resolvedSafeAreaInsets(for geometry: GeometryProxy) -> EdgeInsets {
        let windowInsets = activeWindowSafeAreaInsets

        return EdgeInsets(
            top: max(geometry.safeAreaInsets.top, windowInsets.top),
            leading: max(geometry.safeAreaInsets.leading, windowInsets.left),
            bottom: max(geometry.safeAreaInsets.bottom, windowInsets.bottom),
            trailing: max(geometry.safeAreaInsets.trailing, windowInsets.right)
        )
    }

    private var activeWindowSafeAreaInsets: UIEdgeInsets {
        guard let windowScene = activeWindowScene,
              let window = windowScene.windows.first(where: { $0.isKeyWindow }) else {
            return .zero
        }

        return window.safeAreaInsets
    }

    private var activeInterfaceOrientation: UIInterfaceOrientation {
        activeWindowScene?.interfaceOrientation ?? .unknown
    }

    private var activeWindowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }

    private func headerControls(orientation: BoardControlOrientation) -> some View {
        HeaderControls(
            viewModel: viewModel,
            cameraManager: cameraManager,
            showMenu: $showMenu,
            showClearConfirm: $showClearConfirm,
            onExport: handleExport,
            orientation: orientation
        )
        .opacity(viewModel.isDrawing ? 0.28 : 1)
        .blur(radius: viewModel.isDrawing ? 0.7 : 0)
        .animation(.easeInOut(duration: 0.18), value: viewModel.isDrawing)
    }
}

// MARK: - Floating Board Rails
private struct BoardFloatingRailMetrics {
    let containerSize: CGSize
    let safeAreaInsets: EdgeInsets
    let interfaceOrientation: UIInterfaceOrientation

    private enum Value {
        static let borderClearance: CGFloat = 8
        static let safeAreaTieTolerance: CGFloat = 4
        static let verticalClearance: CGFloat = 10
        static let controlClusterSpacing: CGFloat = 12
        static let propertiesWidthRatio: CGFloat = 0.34
        static let minimumPropertiesWidth: CGFloat = 260
        static let maximumPropertiesWidth: CGFloat = 340
    }

    var verticalInset: CGFloat {
        max(safeAreaInsets.top, safeAreaInsets.bottom) + Value.verticalClearance
    }

    var controlClusterSpacing: CGFloat {
        Value.controlClusterSpacing
    }

    var propertiesPanelWidth: CGFloat {
        min(
            max(containerSize.width * Value.propertiesWidthRatio, Value.minimumPropertiesWidth),
            Value.maximumPropertiesWidth
        )
    }

    func edgeInset(for side: BoardFloatingRailSide) -> CGFloat {
        guard side == dynamicIslandSide else {
            return Value.borderClearance
        }

        return side.safeAreaInset(from: safeAreaInsets) + Value.borderClearance
    }

    private var dynamicIslandSide: BoardFloatingRailSide? {
        switch interfaceOrientation {
        case .landscapeLeft:
            return .trailing
        case .landscapeRight:
            return .leading
        default:
            return sideWithLargerSafeArea
        }
    }

    private var sideWithLargerSafeArea: BoardFloatingRailSide? {
        let leading = safeAreaInsets.leading
        let trailing = safeAreaInsets.trailing

        guard abs(leading - trailing) > Value.safeAreaTieTolerance else {
            return nil
        }

        return leading > trailing ? .leading : .trailing
    }
}

private enum BoardFloatingRailSide {
    case leading
    case trailing

    var paddingEdge: Edge.Set {
        switch self {
        case .leading:
            return .leading
        case .trailing:
            return .trailing
        }
    }

    func safeAreaInset(from insets: EdgeInsets) -> CGFloat {
        switch self {
        case .leading:
            return insets.leading
        case .trailing:
            return insets.trailing
        }
    }
}

private struct BoardFloatingSideRails<LeadingRail: View, TrailingRail: View>: View {
    let metrics: BoardFloatingRailMetrics
    private let leadingRail: LeadingRail
    private let trailingRail: TrailingRail

    init(
        metrics: BoardFloatingRailMetrics,
        @ViewBuilder leading: () -> LeadingRail,
        @ViewBuilder trailing: () -> TrailingRail
    ) {
        self.metrics = metrics
        self.leadingRail = leading()
        self.trailingRail = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: metrics.controlClusterSpacing) {
            BoardFloatingRail(side: .leading, metrics: metrics) {
                leadingRail
            }

            Spacer(minLength: 0)
                .allowsHitTesting(false)

            BoardFloatingRail(side: .trailing, metrics: metrics) {
                trailingRail
            }
        }
        .padding(.vertical, metrics.verticalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BoardFloatingRail<Content: View>: View {
    let side: BoardFloatingRailSide
    let metrics: BoardFloatingRailMetrics
    private let content: Content

    init(
        side: BoardFloatingRailSide,
        metrics: BoardFloatingRailMetrics,
        @ViewBuilder content: () -> Content
    ) {
        self.side = side
        self.metrics = metrics
        self.content = content()
    }

    var body: some View {
        content
            .padding(side.paddingEdge, metrics.edgeInset(for: side))
    }
}

// MARK: - Canvas Background
/// Adaptive background that supports Light and Dark Mode (HIG: Color Usage)
struct CanvasBackground: View {
    let gridStyle: GridStyle
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            AppTheme.canvasBase

            RadialGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.04 : 0.68),
                    AppTheme.canvasWarmth.opacity(colorScheme == .dark ? 0.04 : 0.28),
                    Color.clear
                ],
                center: .center,
                startRadius: 40,
                endRadius: 620
            )
            .blendMode(.softLight)

            CanvasTextureView(colorScheme: colorScheme)
                .opacity(colorScheme == .dark ? 0.16 : 0.11)

            if gridStyle.isVisible {
                GridPatternView(style: gridStyle, colorScheme: colorScheme)
                    .id(gridStyle)
            }

            RadialGradient(
                colors: [
                    Color.clear,
                    Color.black.opacity(colorScheme == .dark ? 0.08 : 0.035)
                ],
                center: .center,
                startRadius: 280,
                endRadius: 980
            )
            .blendMode(.multiply)
        }
    }
}

struct CanvasTextureView: View {
    let colorScheme: ColorScheme

    var body: some View {
        Canvas { context, size in
            let lineColor = colorScheme == .dark ? Color.white.opacity(0.045) : Color.black.opacity(0.035)
            var y: CGFloat = 0
            while y < size.height {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y + 6))
                context.stroke(path, with: .color(lineColor), lineWidth: 0.35)
                y += 56
            }
        }
    }
}

/// Grid pattern rendered as a separate view for proper redraw
struct GridPatternView: View {
    let style: GridStyle
    let colorScheme: ColorScheme

    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 40
            let dotRadius: CGFloat = 1.05
            let gridColor = colorScheme == .dark ?
                Color.white.opacity(0.13) : Color.gray.opacity(0.13)
            let majorGridColor = colorScheme == .dark ?
                Color.white.opacity(0.19) : Color.gray.opacity(0.2)

            switch style {
            case .none:
                break

            case .dots:
                var x: CGFloat = spacing / 2
                while x < size.width {
                    var y: CGFloat = spacing / 2
                    while y < size.height {
                        let rect = CGRect(x: x - dotRadius, y: y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
                        context.fill(Path(ellipseIn: rect), with: .color(gridColor))
                        y += spacing
                    }
                    x += spacing
                }

            case .lines:
                drawLineGrid(in: &context, size: size, spacing: spacing, color: gridColor)

            case .graph:
                drawLineGrid(in: &context, size: size, spacing: spacing, color: gridColor)
                drawLineGrid(in: &context, size: size, spacing: spacing * 5, color: majorGridColor, lineWidth: 0.8)

            case .isometric:
                drawIsometricGrid(in: &context, size: size, spacing: spacing, color: gridColor)
            }
        }
    }

    private func drawLineGrid(
        in context: inout GraphicsContext,
        size: CGSize,
        spacing: CGFloat,
        color: Color,
        lineWidth: CGFloat = 0.45
    ) {
        var x: CGFloat = 0
        while x <= size.width {
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(color), lineWidth: lineWidth)
            x += spacing
        }

        var y: CGFloat = 0
        while y <= size.height {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(color), lineWidth: lineWidth)
            y += spacing
        }
    }

    private func drawIsometricGrid(
        in context: inout GraphicsContext,
        size: CGSize,
        spacing: CGFloat,
        color: Color
    ) {
        let slope: CGFloat = 0.58
        var offset: CGFloat = -size.height
        while offset < size.width {
            var path = Path()
            path.move(to: CGPoint(x: offset, y: 0))
            path.addLine(to: CGPoint(x: offset + size.height / slope, y: size.height))
            context.stroke(path, with: .color(color), lineWidth: 0.45)
            offset += spacing
        }

        offset = -size.height / slope
        while offset < size.width {
            var path = Path()
            path.move(to: CGPoint(x: offset, y: size.height))
            path.addLine(to: CGPoint(x: offset + size.height / slope, y: 0))
            context.stroke(path, with: .color(color), lineWidth: 0.45)
            offset += spacing
        }

        var y: CGFloat = 0
        while y <= size.height {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(color.opacity(0.72)), lineWidth: 0.35)
            y += spacing
        }
    }
}

// MARK: - Header Controls
/// Top header controls with accessibility support (HIG: Accessibility)
struct HeaderControls: View {
    @ObservedObject var viewModel: CanvasViewModel
    @ObservedObject var cameraManager: CameraManager
    @EnvironmentObject var appState: AppState
    
    @Binding var showMenu: Bool
    @Binding var showClearConfirm: Bool
    let onExport: () -> Void
    var orientation: BoardControlOrientation = .horizontal
    
    var body: some View {
        Group {
            if orientation == .vertical {
                VStack(spacing: 4) {
                    headerItems
                }
            } else {
                HStack(spacing: 4) {
                    headerItems
                }
            }
        }
        .padding(.vertical, orientation == .vertical ? 6 : 2)
        .padding(.horizontal, 5)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .opacity(0.7)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.04), radius: 16, y: 6)
    }

    @ViewBuilder
    private var headerItems: some View {
        AppModeMenu(
            selectedTab: $appState.selectedTab,
            presentation: orientation == .vertical ? .vertical : .horizontal
        )

        GridStyleMenu(gridStyle: $viewModel.gridStyle)

        PiPCameraButton(cameraManager: cameraManager)

        if cameraManager.isActive {
            HeaderChromeButton(
                icon: "video.fill",
                accessibilityLabel: "Camera",
                accessibilityValue: "On",
                accessibilityHint: "Tap to turn off camera",
                isActive: true,
                action: { cameraManager.toggleCamera() }
            )
        }

        Menu {
            Button {
                appState.showSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }

            Button {
                appState.showOnboarding = true
            } label: {
                Label("Help", systemImage: "questionmark.circle")
            }

            Divider()

            Button {
                cameraManager.toggleCamera()
            } label: {
                Label(cameraManager.isActive ? "Turn Camera Off" : "Turn Camera On", systemImage: cameraManager.isActive ? "video.slash" : "video")
            }

            Button(action: onExport) {
                Label("Export Image", systemImage: "square.and.arrow.down")
            }

            Divider()

            Button(role: .destructive, action: { showClearConfirm = true }) {
                Label("Clear Board", systemImage: "trash")
            }
        } label: {
            HeaderChromeGlyph(icon: "ellipsis", isActive: false)
        }
        .accessibilityLabel("More options")
        .accessibilityHint("Opens menu with settings, camera, export, and clear options")
    }
}

private struct PiPCameraButton: View {
    @ObservedObject var cameraManager: CameraManager

    var body: some View {
        HeaderChromeButton(
            icon: cameraManager.isPiPActive ? "pip.fill" : "pip",
            accessibilityLabel: "Picture in Picture camera",
            accessibilityValue: cameraManager.isPiPActive ? "On" : "Off",
            accessibilityHint: cameraManager.isPiPActive ? "Stops the floating camera window" : "Starts the camera in Picture in Picture",
            isActive: cameraManager.isPiPActive,
            action: { cameraManager.togglePiP() }
        )
    }
}

private struct GridStyleMenu: View {
    @Binding var gridStyle: GridStyle

    var body: some View {
        Menu {
            ForEach(GridStyle.allCases, id: \.self) { style in
                Button {
                    gridStyle = style
                } label: {
                    Label(style.title, systemImage: gridStyle == style ? "checkmark" : style.iconName)
                }
            }
        } label: {
            HeaderChromeGlyph(icon: gridStyle.isVisible ? gridStyle.iconName : "grid", isActive: gridStyle.isVisible)
        }
        .accessibilityLabel("Grid style")
        .accessibilityValue(gridStyle.title)
        .accessibilityHint("Opens grid style options")
    }
}

private struct HeaderChromeButton: View {
    let icon: String
    let accessibilityLabel: String
    let accessibilityValue: String?
    let accessibilityHint: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HeaderChromeGlyph(icon: icon, isActive: isActive)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue ?? "")
        .accessibilityHint(accessibilityHint)
    }
}

private struct HeaderChromeGlyph: View {
    let icon: String
    var isActive = false

    var body: some View {
        ZStack {
            Circle()
                .fill(isActive ? AppTheme.accentSoft : Color.primary.opacity(0.045))
                .frame(width: 38, height: 38)

            Image(systemName: icon)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(isActive ? AppTheme.accent : .secondary)
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
    }
}

// MARK: - Share Sheet
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)

        // Exclude activity types that can cause issues in simulator
        controller.excludedActivityTypes = [
            .addToReadingList,
            .openInIBooks
        ]

        // Handle completion to dismiss the sheet
        controller.completionWithItemsHandler = { _, completed, _, error in
            if let error = error {
                print("⚠️ Share activity error: \(error.localizedDescription)")
            }
            // Dismiss the sheet after activity completes or is cancelled
            DispatchQueue.main.async {
                context.coordinator.dismiss()
            }
        }

        return controller
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // No updates needed - sheet is modal
    }

    class Coordinator: NSObject {
        @MainActor func dismiss() {
            // Find and dismiss the presenting view controller
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let rootVC = windowScene.windows.first?.rootViewController else { return }
            rootVC.dismiss(animated: true)
        }
    }
}

// MARK: - Preview
#Preview {
    BoardView(viewModel: CanvasViewModel(), cameraManager: CameraManager())
        .environmentObject(AppState())
}
