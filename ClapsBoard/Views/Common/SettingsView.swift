//
//  SettingsView.swift
//  ClapsBoard
//
//  App settings and preferences
//
//  App Store Checklist Items Addressed:
//  - ☐ Privacy policy link added (App Store + in-app) [Line 16]
//  - ☐ Support URL works and shows contact info [Line 17]
//  - ☐ Developer contact info published [Line 35]
//  - ☐ Privacy policy clear & accessible [Line 145]
//  - ☐ Data collection disclosed honestly [Line 146]
//  - ☐ No forced ratings or downloads [Line 109] - Rating is optional
//

import SwiftUI
import StoreKit

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var notificationManager: NotificationManager
    
    @State private var enableNotifications = true
    @State private var notifyMinutesBefore = 5
    @State private var autoSaveEnabled = true
    @State private var showPrivacyPolicy = false
    @State private var showSupportSheet = false
    @State private var showTermsOfService = false
    @State private var showDataInfo = false
    
    @AppStorage("gridSize") private var gridSize: Double = 40
    @AppStorage("defaultStrokeWidth") private var defaultStrokeWidth: Double = 3
    
    var body: some View {
        ZStack {
            // Backdrop
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture {
                    closeSettings()
                }
            
            // Settings Panel
            NavigationView {
                List {
                    // Whiteboard Settings
                    Section("Whiteboard") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Grid Size")
                                Spacer()
                                Text("\(Int(gridSize))px")
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $gridSize, in: 20...80, step: 10)
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Default Stroke")
                                Spacer()
                                Text("\(Int(defaultStrokeWidth))px")
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $defaultStrokeWidth, in: 1...10, step: 1)
                        }
                        
                        Toggle("Auto-save Board", isOn: $autoSaveEnabled)
                    }
                    
                    // Notification Settings
                    Section("Notifications") {
                        Toggle("Class Reminders", isOn: $enableNotifications)
                        
                        if enableNotifications {
                            Picker("Remind Before", selection: $notifyMinutesBefore) {
                                Text("5 minutes").tag(5)
                                Text("10 minutes").tag(10)
                                Text("15 minutes").tag(15)
                                Text("30 minutes").tag(30)
                            }
                        }
                        
                        if !notificationManager.isAuthorized {
                            Button(action: openNotificationSettings) {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                    Text("Enable in Settings")
                                        .foregroundStyle(.primary)
                                }
                            }
                        }
                    }
                    
                    // Privacy & Data Section (REQUIRED for App Store - Checklist items 145-155)
                    Section("Privacy & Data") {
                        Button(action: { showDataInfo = true }) {
                            HStack {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(.blue)
                                Text("Your Data")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                        
                        Button(action: { showPrivacyPolicy = true }) {
                            HStack {
                                Image(systemName: "hand.raised")
                                    .foregroundStyle(.blue)
                                Text("Privacy Policy")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                        
                        Button(action: { showTermsOfService = true }) {
                            HStack {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(.blue)
                                Text("Terms of Service")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    
                    // About & Support (REQUIRED for App Store - Checklist item 17)
                    Section("About") {
                        HStack {
                            Text("Version")
                            Spacer()
                            Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                                .foregroundStyle(.secondary)
                        }
                        
                        HStack {
                            Text("Build")
                            Spacer()
                            Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                                .foregroundStyle(.secondary)
                        }
                        
                        Button(action: { showSupportSheet = true }) {
                            HStack {
                                Image(systemName: "envelope")
                                    .foregroundStyle(.blue)
                                Text("Contact Support")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                        
                        // Rating button - NOT forced, just an option (Checklist item 109)
                        Button(action: requestReview) {
                            HStack {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                                Text("Rate ClapsBoard")
                                Spacer()
                                Text("Optional")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    
                    // Help
                    Section {
                        Button(action: { 
                            closeSettings()
                            appState.showOnboarding = true
                        }) {
                            Label("Show Tutorial", systemImage: "questionmark.circle")
                        }
                    }
                    
                    // Legal Footer
                    Section {
                        VStack(alignment: .center, spacing: 8) {
                            Text("© 2025 ClapsBoard")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Made with ❤️ for educators")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                    }
                }
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            closeSettings()
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
            .frame(maxWidth: 500, maxHeight: 700)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(24)
        }
        .sheet(isPresented: $showPrivacyPolicy) {
            PrivacyPolicyView()
        }
        .sheet(isPresented: $showTermsOfService) {
            TermsOfServiceView()
        }
        .sheet(isPresented: $showSupportSheet) {
            SupportView()
        }
        .sheet(isPresented: $showDataInfo) {
            DataInfoView()
        }
    }
    
    private func closeSettings() {
        withAnimation {
            appState.showSettings = false
        }
    }
    
    private func openNotificationSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
    
    private func requestReview() {
        // Note: This is called voluntarily by user, not forced (Checklist item 109)
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            SKStoreReviewController.requestReview(in: scene)
        }
    }
}

// MARK: - Privacy Policy View (Checklist item 145, 146)
struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Privacy Policy")
                        .font(.title.weight(.bold))
                    
                    Text("Last updated: January 2026")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    Group {
                        Text("Overview")
                            .font(.headline)
                        
                        Text("ClapsBoard is designed with your privacy as a top priority. This policy explains what data we collect, how we use it, and your rights regarding your information.")
                        
                        Text("Data Collection")
                            .font(.headline)
                            .padding(.top)
                        
                        Text("ClapsBoard collects minimal data necessary to provide you with a great teaching experience:")
                        
                        VStack(alignment: .leading, spacing: 8) {
                            DataRowView(icon: "pencil", title: "Whiteboard Data", description: "Stored locally on your device only")
                            DataRowView(icon: "calendar", title: "Class Schedules", description: "Stored locally on your device only")
                            DataRowView(icon: "doc", title: "Documents", description: "Stored in app's private document folder")
                            DataRowView(icon: "camera", title: "Camera", description: "Used only for live mirror feature, never recorded or stored")
                            DataRowView(icon: "photo", title: "Photos", description: "Accessed only when you import images")
                        }
                        .padding(.vertical, 8)
                    }
                    
                    Group {
                        Text("Data Storage")
                            .font(.headline)
                            .padding(.top)
                        
                        Text("All your data is stored locally on your device. We do not have access to your content.")
                        
                        Text("Third-Party Services")
                            .font(.headline)
                            .padding(.top)
                        
                        Text("ClapsBoard does not use any third-party analytics, advertising, or tracking services. Your data stays on your device.")
                        
                        Text("Data Tracking")
                            .font(.headline)
                            .padding(.top)
                        
                        Text("We do not track you. ClapsBoard does not collect identifiers, usage data, or any information that could be used to track you across apps.")
                    }
                    
                    Group {
                        Text("Your Rights")
                            .font(.headline)
                            .padding(.top)
                        
                        Text("You have the right to:")
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("• Access your data (it's all on your device)")
                            Text("• Delete your data (delete the app)")
                            Text("• Export your data (use the export feature)")
                            Text("• Control permissions (via iOS Settings)")
                        }
                        
                        Text("Contact")
                            .font(.headline)
                            .padding(.top)
                        
                        Text("If you have questions about this policy, please contact us at:")
                        
                        Link("support@clapsboard.app", destination: URL(string: "mailto:support@clapsboard.app")!)
                            .foregroundStyle(.blue)
                    }
                }
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Data Row View
struct DataRowView: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Terms of Service View
struct TermsOfServiceView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Terms of Service")
                        .font(.title.weight(.bold))
                    
                    Text("Last updated: January 2026")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    Group {
                        Text("Acceptance of Terms")
                            .font(.headline)
                        
                        Text("By using ClapsBoard, you agree to these terms. If you do not agree, please do not use the app.")
                        
                        Text("License")
                            .font(.headline)
                            .padding(.top)
                        
                        Text("ClapsBoard grants you a limited, non-exclusive, non-transferable license to use the app for personal or educational purposes.")
                        
                        Text("Acceptable Use")
                            .font(.headline)
                            .padding(.top)
                        
                        Text("You agree to use ClapsBoard only for lawful purposes and in accordance with these terms. You may not:")
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("• Use the app for any illegal purpose")
                            Text("• Attempt to reverse engineer the app")
                            Text("• Redistribute or resell the app")
                            Text("• Use the app to create harmful content")
                        }
                    }
                    
                    Group {
                        Text("Intellectual Property")
                            .font(.headline)
                            .padding(.top)
                        
                        Text("ClapsBoard and its content are protected by copyright and other intellectual property laws. The app name, logo, and design are trademarks of ClapsBoard.")
                        
                        Text("Disclaimer")
                            .font(.headline)
                            .padding(.top)
                        
                        Text("ClapsBoard is provided \"as is\" without warranty of any kind. We do not guarantee that the app will be error-free or uninterrupted.")
                        
                        Text("Contact")
                            .font(.headline)
                            .padding(.top)
                        
                        Text("For questions about these terms, contact us at:")
                        
                        Link("support@clapsboard.app", destination: URL(string: "mailto:support@clapsboard.app")!)
                            .foregroundStyle(.blue)
                    }
                }
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Data Info View (Checklist items 146, 149)
struct DataInfoView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Your Data")
                        .font(.title.weight(.bold))
                    
                    Text("Here's what ClapsBoard stores and how")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    // Data Storage Cards
                    VStack(spacing: 16) {
                        DataStorageCard(
                            icon: "iphone",
                            title: "Local Storage Only",
                            description: "All your data stays on your device. We cannot see or access your content.",
                            color: .green
                        )
                        
                        DataStorageCard(
                            icon: "icloud.slash",
                            title: "No Cloud Sync",
                            description: "Your data is not uploaded to any cloud service.",
                            color: .blue
                        )
                        
                        DataStorageCard(
                            icon: "chart.bar.xaxis",
                            title: "No Analytics",
                            description: "We don't track how you use the app or collect usage statistics.",
                            color: .purple
                        )
                        
                        DataStorageCard(
                            icon: "megaphone.fill",
                            title: "No Advertising",
                            description: "ClapsBoard has no ads and doesn't share data with advertisers.",
                            color: .orange
                        )
                    }
                    
                    Text("Data You Can Delete")
                        .font(.headline)
                        .padding(.top)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("• Whiteboard drawings: Clear from the Board menu")
                        Text("• Documents: Swipe to delete in Docs tab")
                        Text("• Class schedules: Swipe to delete in Plan tab")
                        Text("• All data: Delete the app from your device")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Data Storage Card
struct DataStorageCard: View {
    let icon: String
    let title: String
    let description: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

// MARK: - Support View (Checklist item 17, 35)
struct SupportView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 60))
                        .foregroundStyle(.blue)
                    
                    Text("Need Help?")
                        .font(.title2.weight(.bold))
                    
                    Text("We're here to help you get the most out of ClapsBoard.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    
                    // Contact Options
                    VStack(spacing: 12) {
                        Button(action: sendEmail) {
                            Label("Email Support", systemImage: "envelope.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        
                        if let url = URL(string: "https://clapsboard.app/help") {
                            Link(destination: url) {
                                Label("Online Help Center", systemImage: "globe")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        
                        if let url = URL(string: "https://clapsboard.app/faq") {
                            Link(destination: url) {
                                Label("FAQ", systemImage: "questionmark.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.top)
                    
                    // Developer Info (Checklist item 35, 165)
                    VStack(spacing: 8) {
                        Text("Developer Contact")
                            .font(.headline)
                            .padding(.top, 24)
                        
                        VStack(spacing: 4) {
                            Text("ClapsBoard")
                                .font(.subheadline.weight(.medium))
                            Text("support@clapsboard.app")
                                .font(.caption)
                                .foregroundStyle(.blue)
                            Text("https://clapsboard.app")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Spacer()
                }
                .padding(24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
    
    private func sendEmail() {
        if let url = URL(string: "mailto:support@clapsboard.app?subject=ClapsBoard%20Support%20Request") {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Preview
#Preview {
    SettingsView()
        .environmentObject(AppState())
        .environmentObject(NotificationManager())
}
