//
//  ContentView.swift
//  ClapsBoard
//
//  Main content view with tab navigation
//

import SwiftUI

/// Main content view with tab navigation (HIG: Navigation Architecture)
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var notificationManager: NotificationManager
    @StateObject private var canvasViewModel = CanvasViewModel()
    @StateObject private var cameraManager = CameraManager()
    
    // HIG: Reduce Motion support
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    var body: some View {
        ZStack {
            // Main Content
            ZStack(alignment: .bottom) {
                // Content based on selected tab
                Group {
                    switch appState.selectedTab {
                    case .board:
                        BoardView(viewModel: canvasViewModel, cameraManager: cameraManager)
                    case .docs:
                        DocumentsView()
                    case .calendar:
                        CalendarView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // Bottom Navigation
                BottomNavigationBar()
            }
            .ignoresSafeArea(.keyboard)
            
            // Camera Overlay (if active)
            if cameraManager.isActive {
                CameraOverlay(cameraManager: cameraManager)
            }
            
            // Onboarding Modal
            if appState.showOnboarding {
                OnboardingView()
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale))
            }
            
            // Settings Modal
            if appState.showSettings {
                SettingsView()
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing))
            }
        }
        // HIG: Respect Reduce Motion - use no animations when enabled
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: appState.showOnboarding)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: appState.showSettings)
    }
}

// MARK: - Bottom Navigation Bar
/// Tab bar following HIG guidelines (HIG: Navigation Architecture, Accessibility)
struct BottomNavigationBar: View {
    @EnvironmentObject var appState: AppState
    
    // HIG: Reduce Motion support
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppState.Tab.allCases, id: \.self) { tab in
                Button(action: {
                    // HIG: Respect Reduce Motion setting
                    if reduceMotion {
                        appState.selectedTab = tab
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            appState.selectedTab = tab
                        }
                    }
                }) {
                    VStack(spacing: 4) {
                        Image(systemName: iconName(for: tab))
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(appState.selectedTab == tab ? .blue : .primary.opacity(0.6))
                        
                        Text(tab.rawValue)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(appState.selectedTab == tab ? .blue : .primary.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        appState.selectedTab == tab ?
                        Color.blue.opacity(0.1) : Color.gray.opacity(0.01)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                // HIG: Accessibility labels for VoiceOver
                .accessibilityLabel("\(tab.rawValue) tab")
                .accessibilityHint("Double tap to switch to \(tab.rawValue)")
                .accessibilityAddTraits(appState.selectedTab == tab ? .isSelected : [])
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 24)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .shadow(color: .black.opacity(0.1), radius: 20, y: -5)
    }
    
    private func iconName(for tab: AppState.Tab) -> String {
        switch tab {
        case .board: return "scribble.variable"
        case .docs: return "doc.text"
        case .calendar: return "calendar"
        }
    }
}

// MARK: - Preview
#Preview {
    ContentView()
        .environmentObject(AppState())
        .environmentObject(NotificationManager())
}
