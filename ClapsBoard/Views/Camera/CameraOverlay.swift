//
//  CameraOverlay.swift
//  ClapsBoard
//
//  Draggable camera overlay with Picture-in-Picture support
//
//  App Store Checklist Items Addressed:
//  - ☐ Recording requires consent & indicators [Line 85] - iOS shows green dot
//  - ☐ User consent obtained before camera [Line 147] - Permission alert shown
//

import SwiftUI
import AVKit

/// Draggable camera overlay with PiP support (HIG: Motion, Accessibility)
struct CameraOverlay: View {
    @ObservedObject var cameraManager: CameraManager
    
    @State private var isDragging = false
    @GestureState private var dragOffset: CGSize = .zero
    
    // HIG: Reduce Motion support
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                // Check authorization status
                if cameraManager.authorizationStatus == .denied {
                    // Show permission denied view
                    CameraPermissionDeniedView(onOpenSettings: cameraManager.openSettings)
                        .frame(width: cameraManager.widgetSize.width + 40, height: cameraManager.widgetSize.height + 60)
                        .position(
                            x: cameraManager.position.x + cameraManager.widgetSize.width / 2,
                            y: cameraManager.position.y + cameraManager.widgetSize.height / 2
                        )
                } else {
                    // Camera Preview
                    // Camera Widget Container
                    ZStack {
                        // Camera Preview
                        CameraPreviewView(cameraManager: cameraManager)
                            .background(Color.black)
                            .opacity(cameraManager.previewOpacity)
                            .clipShape(RoundedRectangle(cornerRadius: cameraManager.isCircular ? cameraManager.widgetSize.width / 2 : 16))
                            .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
                            .overlay(
                                RoundedRectangle(cornerRadius: cameraManager.isCircular ? cameraManager.widgetSize.width / 2 : 16)
                                    .stroke(Color.white, lineWidth: 4)
                            )
                            // Live/PiP indicator
                            .overlay(alignment: .topLeading) {
                                if cameraManager.isActive {
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(cameraManager.isPiPActive ? AppTheme.accent : Color.red)
                                            .frame(width: 6, height: 6)
                                        Text(cameraManager.isPiPActive ? "PiP" : "LIVE")
                                            .font(.caption2.weight(.bold)) // HIG: Dynamic Type support
                                            .foregroundStyle(.white)
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.black.opacity(0.6), in: Capsule())
                                    .padding(8)
                                    .accessibilityHidden(true)
                                }
                            }
                        
                        // Controls Overlay
                        CameraControlsOverlay(cameraManager: cameraManager)
                    }
                    .frame(width: cameraManager.widgetSize.width, height: cameraManager.widgetSize.height)
                    .position(
                        x: cameraManager.position.x + cameraManager.widgetSize.width / 2 + dragOffset.width,
                        y: cameraManager.position.y + cameraManager.widgetSize.height / 2 + dragOffset.height
                    )
                    .gesture(
                        DragGesture()
                            .updating($dragOffset) { value, state, _ in
                                guard !cameraManager.isPositionLocked else { return }
                                state = value.translation
                                isDragging = true
                            }
                            .onEnded { value in
                                guard !cameraManager.isPositionLocked else { return }
                                let newPosition = CGPoint(
                                    x: cameraManager.position.x + value.translation.width,
                                    y: cameraManager.position.y + value.translation.height
                                )
                                cameraManager.updatePosition(to: newPosition, in: geometry.frame(in: .local))
                                isDragging = false
                            }
                    )
                    // HIG: Only scale when not using Reduce Motion
                    .scaleEffect(reduceMotion ? 1.0 : (isDragging ? 1.05 : 1.0))
                    .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: isDragging)
                    // HIG: Accessibility
                    .accessibilityLabel("Camera preview. Drag to move.")
                    .accessibilityAddTraits(.allowsDirectInteraction)
                }
            }
        }
    }
}

// MARK: - Camera Controls Overlay
struct CameraControlsOverlay: View {
    @ObservedObject var cameraManager: CameraManager
    @State private var showControls = false
    
    var body: some View {
        ZStack {
            // Tap area
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showControls.toggle()
                    }
                }
            
            // Controls
            if showControls {
                VStack {
                    HStack {
                        Spacer()
                        
                        // PiP Button (System Picture-in-Picture)
                        Button(action: { cameraManager.togglePiP() }) {
                            Image(systemName: cameraManager.isPiPActive ? "pip.fill" : "pip")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44) // HIG: 44pt minimum touch target
                                .background(cameraManager.isPiPActive ? AppTheme.accent : .black.opacity(0.5), in: Circle())
                        }
                        .accessibilityLabel(cameraManager.isPiPActive ? "Stop Picture in Picture" : "Start Picture in Picture")
                        .accessibilityHint("Enables floating camera that works outside the app")

                        // Close Button
                        Button(action: { cameraManager.stopCamera() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44) // HIG: 44pt minimum touch target
                                .background(.black.opacity(0.5), in: Circle())
                        }
                    }
                    .padding(8)
                    
                    Spacer()
                    
                    HStack {
                        Spacer()
                        
                        // Flip Button
                        Button(action: { cameraManager.toggleFlip() }) {
                            Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44) // HIG: 44pt minimum touch target
                                .background(.black.opacity(0.5), in: Circle())
                        }

                        Menu {
                            Button {
                                cameraManager.isPositionLocked.toggle()
                            } label: {
                                Label(cameraManager.isPositionLocked ? "Unlock Position" : "Lock Position", systemImage: cameraManager.isPositionLocked ? "lock.open" : "lock")
                            }
                            Button {
                                cameraManager.isCircular.toggle()
                            } label: {
                                Label(cameraManager.isCircular ? "Rounded Rectangle" : "Circle", systemImage: cameraManager.isCircular ? "rectangle.roundedtop" : "circle")
                            }
                            Button(action: cameraManager.cycleWidgetSize) {
                                Label("Resize", systemImage: "arrow.up.left.and.arrow.down.right")
                            }
                            Button(action: cameraManager.cyclePreviewOpacity) {
                                Label("Opacity \(Int(cameraManager.previewOpacity * 100))%", systemImage: "circle.lefthalf.filled")
                            }
                        } label: {
                            Image(systemName: cameraManager.isPositionLocked ? "lock.fill" : "slider.horizontal.3")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(.black.opacity(0.5), in: Circle())
                        }
                        
                        Spacer()
                    }
                    .padding(.bottom, 8)
                }
                .background(
                    LinearGradient(
                        colors: [.black.opacity(0.4), .clear, .black.opacity(0.4)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: cameraManager.isCircular ? cameraManager.widgetSize.width / 2 : 16))
            }
        }
    }
}

// MARK: - Preview
#Preview {
    ZStack {
        Color.gray.opacity(0.3)
        CameraOverlay(cameraManager: CameraManager())
    }
}
