//
//  OnboardingView.swift
//  ClapsBoard
//
//  In-app help guide
//

import SwiftUI

/// Help modal following HIG guidelines for clarity, deference, and accessibility.
struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var currentPage = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            icon: "scribble.variable",
            title: "Canvas",
            description: "Draw on a calm, open board. Keep the grid off for freeform work, then turn on dots, lines, graph, or isometric guides when alignment matters.",
            color: AppTheme.accent,
            points: ["Pinch to zoom", "Use hand mode to move around", "Double tap to reset the view"]
        ),
        OnboardingPage(
            icon: "pencil.tip",
            title: "Tools",
            description: "Choose the tool first, then use the adjustment button for the settings that belong to that tool.",
            color: Color(hex: "F59E0B"),
            points: ["Pen and marker use color and size", "Eraser uses size", "Selection works with direct move and resize handles"]
        ),
        OnboardingPage(
            icon: "pip",
            title: "PiP Camera",
            description: "Start the floating camera from the top toolbar when you want your face visible while teaching or presenting.",
            color: Color(hex: "34A853"),
            points: ["Tap PiP in the top toolbar", "Drag the camera preview", "Use camera controls from the preview"]
        ),
        OnboardingPage(
            icon: "doc.text",
            title: "Docs",
            description: "Keep reference material close without leaving the teaching flow.",
            color: Color(hex: "06B6D4"),
            points: ["Switch from the mode menu", "Review lesson files", "Return to the board instantly"]
        ),
        OnboardingPage(
            icon: "calendar",
            title: "Plan",
            description: "Use the planner for class timing and reminders so the board stays focused during sessions.",
            color: Color(hex: "8B5CF6"),
            points: ["Create class sessions", "Enable reminders", "Check upcoming lessons"]
        )
    ]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.22)
                    .ignoresSafeArea()
                    .onTapGesture {
                        closeOnboarding()
                    }

                RadialGradient(
                    colors: [
                        pages[currentPage].color.opacity(0.18),
                        AppTheme.canvasWarmth.opacity(0.16),
                        Color.clear
                    ],
                    center: .top,
                    startRadius: 80,
                    endRadius: 620
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

                VStack(spacing: 0) {
                    HelpHeader(onClose: closeOnboarding)

                    TabView(selection: $currentPage) {
                        ForEach(pages.indices, id: \.self) { index in
                            HelpPageView(page: pages[index])
                                .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: currentPage)

                    HelpPager(
                        count: pages.count,
                        currentPage: currentPage,
                        color: pages[currentPage].color
                    )
                    .padding(.top, 6)

                    HStack(spacing: 12) {
                        Button(action: previousPage) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .foregroundStyle(currentPage == 0 ? .tertiary : .secondary)
                                .background(Color.primary.opacity(0.045), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(currentPage == 0)
                        .accessibilityLabel("Previous help page")

                        Spacer()

                        Button(action: nextOrClose) {
                            HStack(spacing: 8) {
                                Text(currentPage == pages.count - 1 ? "Done" : "Next")
                                    .font(.subheadline.weight(.semibold))

                                if currentPage < pages.count - 1 {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .frame(height: 44)
                            .background(pages[currentPage].color, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(currentPage == pages.count - 1 ? "Close help" : "Go to next help page")
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 20)
                }
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(.white.opacity(0.24), lineWidth: 1)
                        }
                )
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 26, y: 12)
                .frame(
                    width: min(max(geometry.size.width - 24, 300), 430),
                    height: min(max(geometry.size.height - 28, 560), 640)
                )
            }
        }
    }

    private func previousPage() {
        guard currentPage > 0 else { return }
        if reduceMotion {
            currentPage -= 1
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                currentPage -= 1
            }
        }
    }

    private func nextOrClose() {
        guard currentPage < pages.count - 1 else {
            closeOnboarding()
            return
        }

        if reduceMotion {
            currentPage += 1
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                currentPage += 1
            }
        }
    }

    private func closeOnboarding() {
        withAnimation {
            appState.completeOnboarding()
        }
    }
}

struct OnboardingPage {
    let icon: String
    let title: String
    let description: String
    let color: Color
    let points: [String]
}

private struct HelpHeader: View {
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Help")
                    .font(.system(.title2, design: .rounded, weight: .semibold))

                Text("A quick guide to the workspace")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(Color.primary.opacity(0.055), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close help")
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }
}

private struct HelpPageView: View {
    let page: OnboardingPage

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: page.icon)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(page.color)
                    .frame(width: 58, height: 58)
                    .background(page.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 10) {
                    Text(page.title)
                        .font(.system(.title, design: .rounded, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(page.description)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 10) {
                    ForEach(page.points, id: \.self) { point in
                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .fill(page.color)
                                .frame(width: 6, height: 6)
                                .padding(.top, 7)
                                .accessibilityHidden(true)

                            Text(point)
                                .font(.subheadline)
                                .foregroundStyle(.primary.opacity(0.86))

                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .background(Color(.secondarySystemBackground).opacity(0.62), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 8)
        }
    }
}

private struct HelpPager: View {
    let count: Int
    let currentPage: Int
    let color: Color

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == currentPage ? color : Color.primary.opacity(0.13))
                    .frame(width: index == currentPage ? 22 : 7, height: 7)
                    .animation(.easeInOut(duration: 0.2), value: currentPage)
            }
        }
        .accessibilityLabel("Help page \(currentPage + 1) of \(count)")
    }
}

// MARK: - Preview
#Preview {
    OnboardingView()
        .environmentObject(AppState())
}
