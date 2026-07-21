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
            // Keep pages alive without allowing hidden horizontal page swipes.
            ZStack {
                BoardView(viewModel: canvasViewModel, cameraManager: cameraManager)
                    .opacity(appState.selectedTab == .board ? 1 : 0)
                    .allowsHitTesting(appState.selectedTab == .board)
                    .accessibilityHidden(appState.selectedTab != .board)

                DocumentsView()
                    .opacity(appState.selectedTab == .docs ? 1 : 0)
                    .allowsHitTesting(appState.selectedTab == .docs)
                    .accessibilityHidden(appState.selectedTab != .docs)

                CalendarView()
                    .opacity(appState.selectedTab == .calendar ? 1 : 0)
                    .allowsHitTesting(appState.selectedTab == .calendar)
                    .accessibilityHidden(appState.selectedTab != .calendar)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: appState.selectedTab)
        .overlay(alignment: .top) {
            // Camera Overlay (if active) - positioned above TabView
            if cameraManager.isActive {
                CameraOverlay(cameraManager: cameraManager)
            }
        }
        .overlay {
            // Onboarding Modal
            if appState.showOnboarding {
                OnboardingView()
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale))
            }
        }
        .overlay {
            // Settings Modal
            if appState.showSettings {
                SettingsView()
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: appState.showOnboarding)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: appState.showSettings)
    }
}

extension AppState.Tab {
    var title: String {
        switch self {
        case .board: return "Board"
        case .docs: return "Docs"
        case .calendar: return "Plan"
        }
    }

    var iconName: String {
        switch self {
        case .board: return "scribble.variable"
        case .docs: return "doc.text"
        case .calendar: return "calendar"
        }
    }
}

// MARK: - Mode Menu
enum AppModeMenuPresentation {
    case horizontal
    case vertical
}

struct AppModeMenu: View {
    @Binding var selectedTab: AppState.Tab
    var showsIcon: Bool = false
    var presentation: AppModeMenuPresentation = .horizontal

    private let feedback = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        Menu {
            ForEach(AppState.Tab.allCases, id: \.self) { tab in
                Button {
                    selectedTab = tab
                    feedback.impactOccurred()
                } label: {
                    Label(tab.title, systemImage: tab.iconName)
                }
            }
        } label: {
            menuLabel
        }
        .accessibilityLabel("Current mode, \(selectedTab.title)")
    }

    @ViewBuilder
    private var menuLabel: some View {
        switch presentation {
        case .horizontal:
            horizontalLabel
        case .vertical:
            verticalLabel
        }
    }

    private var horizontalLabel: some View {
        HStack(spacing: 5) {
            if showsIcon {
                Image(systemName: selectedTab.iconName)
                    .font(.system(size: 13, weight: .medium))
            }

            Text(selectedTab.title)
                .font(.system(size: 14, weight: .semibold))

            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(AppTheme.accent)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(AppTheme.accentSoft, in: Capsule())
        .frame(minHeight: 44)
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Capsule())
    }

    private var verticalLabel: some View {
        VStack(spacing: 4) {
            Text(selectedTab.title)
                .font(.system(size: 13, weight: .semibold))
                .rotationEffect(.degrees(-90))
                .fixedSize()
                .frame(width: 28, height: 50)

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(AppTheme.accent)
        .frame(width: 44, height: 78)
        .background(AppTheme.accentSoft, in: Capsule())
        .contentShape(Capsule())
    }
}

// MARK: - Preview
#Preview {
    ContentView()
        .environmentObject(AppState())
        .environmentObject(NotificationManager())
}
