//
//  OnboardingView.swift
//  ClapsBoard
//
//  Onboarding/help modal with feature guide
//

import SwiftUI

/// Onboarding/help modal following HIG guidelines (HIG: Onboarding, Accessibility)
struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @State private var currentPage = 0
    
    // HIG: Reduce Motion support
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    private let pages: [OnboardingPage] = [
        OnboardingPage(
            icon: "scribble.variable",
            title: "Welcome to ClapsBoard",
            description: "The perfect digital whiteboard for interactive teaching. Draw, annotate, and engage your students with ease.",
            color: .blue
        ),
        OnboardingPage(
            icon: "pencil.and.outline",
            title: "Drawing Tools",
            description: "Use pen, highlighter, shapes, text, and stickers. Customize colors and stroke width to match your style.",
            color: .purple
        ),
        OnboardingPage(
            icon: "video.fill",
            title: "Camera Mirror",
            description: "Enable the camera to show yourself while teaching. Drag it anywhere on screen. Use Picture-in-Picture for multitasking.",
            color: .orange
        ),
        OnboardingPage(
            icon: "doc.text",
            title: "Document Viewer",
            description: "Import and view PDFs, presentations, and documents. Perfect for lesson materials.",
            color: .cyan
        ),
        OnboardingPage(
            icon: "calendar",
            title: "Class Scheduler",
            description: "Plan your classes with the built-in calendar. Get reminders before each session starts.",
            color: .green
        )
    ]
    
    var body: some View {
        ZStack {
            // Backdrop
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture {
                    closeOnboarding()
                }
            
            // Modal
            VStack(spacing: 0) {
                // Close Button
                HStack {
                    Spacer()
                    Button(action: closeOnboarding) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .background(Color.gray.opacity(0.2), in: Circle())
                    }
                }
                .padding(16)
                
                // Page Content
                TabView(selection: $currentPage) {
                    ForEach(0..<pages.count, id: \.self) { index in
                        OnboardingPageView(page: pages[index])
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 300)
                
                // Page Indicators
                HStack(spacing: 8) {
                    ForEach(0..<pages.count, id: \.self) { index in
                        Circle()
                            .fill(currentPage == index ? pages[index].color : Color.gray.opacity(0.3))
                            .frame(width: 8, height: 8)
                            .animation(.easeInOut, value: currentPage)
                    }
                }
                .padding(.vertical, 16)
                
                // Buttons
                HStack(spacing: 12) {
                    if currentPage > 0 {
                        Button("Back") {
                            // HIG: Respect Reduce Motion
                            if reduceMotion {
                                currentPage -= 1
                            } else {
                                withAnimation {
                                    currentPage -= 1
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .accessibilityHint("Go to previous page")
                    }
                    
                    Spacer()
                    
                    if currentPage < pages.count - 1 {
                        Button("Next") {
                            // HIG: Respect Reduce Motion
                            if reduceMotion {
                                currentPage += 1
                            } else {
                                withAnimation {
                                    currentPage += 1
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint("Go to next page")
                    } else {
                        Button("Get Started") {
                            closeOnboarding()
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint("Close onboarding and start using the app")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(.ultraThickMaterial)
            )
            .frame(maxWidth: 400)
            .padding(24)
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
}

struct OnboardingPageView: View {
    let page: OnboardingPage
    
    var body: some View {
        VStack(spacing: 20) {
            // Icon
            Image(systemName: page.icon)
                .font(.system(size: 60))
                .foregroundStyle(page.color)
                .frame(height: 80)
            
            // Title
            Text(page.title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            
            // Description
            Text(page.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .padding()
    }
}

// MARK: - Preview
#Preview {
    OnboardingView()
        .environmentObject(AppState())
}
