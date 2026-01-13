//
//  BoardView.swift
//  ClapsBoard
//
//  Main whiteboard view with drawing canvas and tools
//

import SwiftUI
import PencilKit

struct BoardView: View {
    @ObservedObject var viewModel: CanvasViewModel
    @ObservedObject var cameraManager: CameraManager
    @EnvironmentObject var appState: AppState
    
    @State private var showClearConfirm = false
    @State private var showExportSheet = false
    @State private var showMenu = false
    @State private var exportedImage: UIImage?
    @GestureState private var magnificationState: CGFloat = 1.0
    @State private var lastPanValue: DragGesture.Value?
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 1. Full-screen Drawing Layer (Ignores Safe Area)
                ZStack {
                    // Background with Grid
                    CanvasBackground(showGrid: viewModel.showGrid)
                        .frame(width: 5000, height: 5000)
                    
                    // Drawing Canvas
                    DrawingCanvas(viewModel: viewModel)
                        .frame(width: 5000, height: 5000)
                }
                .scaleEffect(viewModel.zoom * magnificationState)
                .offset(x: viewModel.pan.x, y: viewModel.pan.y)
                .gesture(
                    MagnificationGesture()
                        .updating($magnificationState) { value, state, _ in
                            state = value
                        }
                        .onEnded { value in
                            let newZoom = viewModel.zoom * value
                            viewModel.zoom = max(0.1, min(10.0, newZoom))
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
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .ignoresSafeArea()
                
                // 2. UI Controls Layer
                VStack {
                    HeaderControls(
                        viewModel: viewModel,
                        cameraManager: cameraManager,
                        showMenu: $showMenu,
                        showClearConfirm: $showClearConfirm,
                        onExport: handleExport
                    )
                    .padding(.top, geometry.safeAreaInsets.top + 4) // Tighter top space
                    
                    Spacer()
                        .allowsHitTesting(false)
                    
                    // Bottom Stack
                    VStack(spacing: 0) {
                        // Properties Panel
                        if viewModel.showProperties && viewModel.tool != .select {
                            PropertiesPanel(viewModel: viewModel)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                                .padding(.bottom, 16)
                        }
                        
                        // Main Toolbar
                        ToolbarView(viewModel: viewModel)
                    }
                    .padding(.bottom, 100) // Keep toolbar above the bottom navigation tabs
                }
                .padding(.horizontal, geometry.safeAreaInsets.leading) // Support for landscape
            }
        }
        .ignoresSafeArea(.keyboard)
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
        .sheet(isPresented: $showExportSheet) {
            if let image = exportedImage {
                ShareSheet(items: [image])
            }
        }
    }
    
    private func handleExport() {
        // Export dynamic content bounds
        exportedImage = viewModel.exportImage() // No custom rect = auto-detect bounds
        showExportSheet = true
    }
}

// MARK: - Canvas Background
/// Adaptive background that supports Light and Dark Mode (HIG: Color Usage)
struct CanvasBackground: View {
    let showGrid: Bool
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        ZStack {
            // Use system background for Dark Mode support (HIG requirement)
            Color(.systemBackground)
            
            if showGrid {
                // HIG: Efficient grid rendering using tiled ImagePaint
                // This is MUCH faster than drawing 60,000+ circles in a Canvas loop
                Rectangle()
                    .fill(ImagePaint(
                        image: Image(uiImage: gridPatternImage),
                        sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                        scale: 1
                    ))
            }
        }
    }
    
    private var gridPatternImage: UIImage {
        let size: CGFloat = 40
        let dotSize: CGFloat = 2
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        
        return renderer.image { context in
            let gridColor = colorScheme == .dark ? 
                UIColor.white.withAlphaComponent(0.15) : UIColor.systemGray3.withAlphaComponent(0.3)
            
            gridColor.setFill()
            // Draw a single dot in the center of the 40x40 tile
            let rect = CGRect(x: (size - dotSize)/2, y: (size - dotSize)/2, width: dotSize, height: dotSize)
            UIBezierPath(ovalIn: rect).fill()
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
    
    var body: some View {
        HStack {
            Spacer()
            
            // Control Group
            HStack(spacing: 8) {
                // Settings Button
                Button(action: { appState.showSettings = true }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Settings")
                .accessibilityHint("Opens app settings")
                
                // Help Button
                Button(action: { appState.showOnboarding = true }) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.orange)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Help")
                .accessibilityHint("Shows the tutorial")
                
                // Toggle Buttons Container
                HStack(spacing: 4) {
                    // Grid Toggle
                    Button(action: { viewModel.showGrid.toggle() }) {
                        Image(systemName: "grid")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(viewModel.showGrid ? .white : .secondary)
                            .frame(width: 36, height: 36)
                            .background(viewModel.showGrid ? .blue : .clear, in: Circle())
                    }
                    .accessibilityLabel("Grid")
                    .accessibilityValue(viewModel.showGrid ? "On" : "Off")
                    .accessibilityHint("Toggles grid visibility")
                    
                    // PiP Toggle (System Picture-in-Picture like Zoom/Meet)
                    Button(action: { cameraManager.togglePiP() }) {
                        Image(systemName: cameraManager.isPiPActive ? "pip.fill" : "pip")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(cameraManager.isPiPActive ? .white : .secondary)
                            .frame(width: 36, height: 36)
                            .background(cameraManager.isPiPActive ? .blue : .clear, in: Circle())
                    }
                    .accessibilityLabel("Picture in Picture")
                    .accessibilityValue(cameraManager.isPiPActive ? "On" : "Off")
                    .accessibilityHint(cameraManager.isPiPActive ? "Tap to stop floating camera window" : "Tap to enable floating camera window that works outside the app")
                    
                    // Camera Toggle
                    Button(action: { cameraManager.toggleCamera() }) {
                        Image(systemName: cameraManager.isActive ? "video.fill" : "video.slash")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(cameraManager.isActive ? .white : .secondary)
                            .frame(width: 36, height: 36)
                            .background(cameraManager.isActive ? .blue : .clear, in: Circle())
                    }
                    .accessibilityLabel("Camera")
                    .accessibilityValue(cameraManager.isActive ? "On" : "Off")
                    .accessibilityHint(cameraManager.isActive ? "Tap to turn off camera" : "Tap to turn on camera")
                }
                .padding(4)
                .background(.ultraThinMaterial, in: Capsule())
                
                // Menu Button
                Menu {
                    Button(action: onExport) {
                        Label("Export Image", systemImage: "square.and.arrow.down")
                    }
                    
                    Divider()
                    
                    Button(role: .destructive, action: { showClearConfirm = true }) {
                        Label("Clear Board", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("More options")
                .accessibilityHint("Opens menu with export and clear options")
            }
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Share Sheet
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Preview
#Preview {
    BoardView(viewModel: CanvasViewModel(), cameraManager: CameraManager())
        .environmentObject(AppState())
}
