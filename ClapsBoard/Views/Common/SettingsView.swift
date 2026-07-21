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
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.22)
                    .ignoresSafeArea()
                    .onTapGesture {
                        closeSettings()
                    }

                RadialGradient(
                    colors: [
                        AppTheme.accent.opacity(0.16),
                        AppTheme.canvasWarmth.opacity(0.16),
                        Color.clear
                    ],
                    center: .top,
                    startRadius: 80,
                    endRadius: 620
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

                NavigationStack {
                    VStack(spacing: 0) {
                        SettingsHeader(onClose: closeSettings)

                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 18) {
                                SettingsSection(title: "Board") {
                                    SettingsSliderRow(
                                        icon: "grid",
                                        iconColor: AppTheme.accent,
                                        title: "Grid size",
                                        value: $gridSize,
                                        range: 20...80,
                                        step: 10,
                                        valueFormatter: { "\(Int($0)) px" }
                                    )

                                    SettingsDivider()

                                    SettingsSliderRow(
                                        icon: "pencil.tip",
                                        iconColor: Color(hex: "F59E0B"),
                                        title: "Default stroke",
                                        value: $defaultStrokeWidth,
                                        range: 1...10,
                                        step: 1,
                                        valueFormatter: { "\(Int($0)) px" }
                                    )

                                    SettingsDivider()

                                    SettingsToggleRow(
                                        icon: "arrow.triangle.2.circlepath",
                                        iconColor: Color(hex: "34A853"),
                                        title: "Auto-save board",
                                        subtitle: "Keep work available between sessions",
                                        isOn: $autoSaveEnabled
                                    )
                                }

                                SettingsSection(title: "Reminders") {
                                    SettingsToggleRow(
                                        icon: "bell.fill",
                                        iconColor: Color(hex: "F97316"),
                                        title: "Class reminders",
                                        subtitle: "Notification alerts for planned sessions",
                                        isOn: $enableNotifications
                                    )

                                    if enableNotifications {
                                        SettingsDivider()

                                        SettingsPickerRow(
                                            icon: "clock",
                                            iconColor: AppTheme.accent,
                                            title: "Remind before",
                                            selection: $notifyMinutesBefore,
                                            options: [5, 10, 15, 30],
                                            label: { "\($0) min" }
                                        )
                                    }

                                    if !notificationManager.isAuthorized {
                                        SettingsDivider()

                                        Button(action: openNotificationSettings) {
                                            SettingsRow(
                                                icon: "exclamationmark.triangle.fill",
                                                iconColor: Color(hex: "F59E0B"),
                                                title: "Enable notifications",
                                                subtitle: "Open iOS Settings",
                                                showsChevron: true
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }

                                SettingsSection(title: "Teaching") {
                                    NavigationLink(destination: VoiceChannelView()) {
                                        SettingsRow(
                                            icon: "waveform.circle.fill",
                                            iconColor: Color(hex: "22C55E"),
                                            title: "Voice channel",
                                            subtitle: "Audio tools for live teaching",
                                            showsChevron: true
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }

                                SettingsSection(title: "Privacy") {
                                    Button(action: { showDataInfo = true }) {
                                        SettingsRow(
                                            icon: "info.circle.fill",
                                            iconColor: AppTheme.accent,
                                            title: "Your data",
                                            subtitle: "Local storage and permissions",
                                            showsChevron: true
                                        )
                                    }
                                    .buttonStyle(.plain)

                                    SettingsDivider()

                                    Button(action: { showPrivacyPolicy = true }) {
                                        SettingsRow(
                                            icon: "hand.raised.fill",
                                            iconColor: AppTheme.accent,
                                            title: "Privacy policy",
                                            subtitle: nil,
                                            showsChevron: true
                                        )
                                    }
                                    .buttonStyle(.plain)

                                    SettingsDivider()

                                    Button(action: { showTermsOfService = true }) {
                                        SettingsRow(
                                            icon: "doc.text.fill",
                                            iconColor: AppTheme.accent,
                                            title: "Terms of service",
                                            subtitle: nil,
                                            showsChevron: true
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }

                                SettingsSection(title: "About") {
                                    SettingsValueRow(
                                        title: "Version",
                                        value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                                    )

                                    SettingsDivider()

                                    Button(action: { showSupportSheet = true }) {
                                        SettingsRow(
                                            icon: "envelope.fill",
                                            iconColor: AppTheme.accent,
                                            title: "Contact support",
                                            subtitle: nil,
                                            showsChevron: true
                                        )
                                    }
                                    .buttonStyle(.plain)

                                    SettingsDivider()

                                    Button(action: requestReview) {
                                        SettingsRow(
                                            icon: "star.fill",
                                            iconColor: Color(hex: "EAB308"),
                                            title: "Rate ClapsBoard",
                                            subtitle: "Optional",
                                            showsChevron: true
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }

                                Button(action: {
                                    closeSettings()
                                    appState.showOnboarding = true
                                }) {
                                    HStack(spacing: 10) {
                                        Image(systemName: "questionmark.circle.fill")
                                            .font(.system(size: 15, weight: .medium))
                                        Text("Open Help")
                                            .font(.subheadline.weight(.semibold))
                                    }
                                    .foregroundStyle(AppTheme.accent)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Shows the help guide")

                                SettingsFooter()
                            }
                            .padding(.horizontal, 18)
                            .padding(.bottom, 20)
                        }
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
                        width: min(max(geometry.size.width - 24, 300), 460),
                        height: min(max(geometry.size.height - 28, 500), 760)
                    )
                    .toolbar(.hidden, for: .navigationBar)
                }
            }
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
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            SKStoreReviewController.requestReview(in: scene)
        }
    }
}

// MARK: - Settings Header
struct SettingsHeader: View {
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings")
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("Board, camera, reminders, privacy")
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
            .accessibilityLabel("Close settings")
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }
}

// MARK: - Settings Section
struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                content
            }
            .background(Color(.secondarySystemBackground).opacity(0.62), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            }
        }
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 56)
    }
}

// MARK: - Settings Row Component
struct SettingsRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String?
    var showsChevron = false

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(icon: icon, color: iconColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

struct SettingsIcon: View {
    let icon: String
    let color: Color

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 32, height: 32)
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct SettingsToggleRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 12) {
                SettingsIcon(icon: icon, color: iconColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))

                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .tint(AppTheme.accent)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct SettingsPickerRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    @Binding var selection: Int
    let options: [Int]
    let label: (Int) -> String

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(icon: icon, color: iconColor)

            Text(title)
                .font(.subheadline.weight(.medium))

            Spacer()

            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(label(option)).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(AppTheme.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct SettingsValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.medium))

            Spacer()

            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }
}

// MARK: - Settings Slider Row Component
struct SettingsSliderRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueFormatter: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                SettingsIcon(icon: icon, color: iconColor)

                Text(title)
                    .font(.subheadline.weight(.medium))

                Spacer()

                Text(valueFormatter(value))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(value: $value, in: range, step: step)
                .tint(AppTheme.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct SettingsFooter: View {
    var body: some View {
        let year = String(Calendar.current.component(.year, from: Date()))

        VStack(spacing: 6) {
            Text("© \(year) ClapsBoard")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Built for focused teaching")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }
}

// MARK: - Privacy Policy View (Checklist item 145, 146)
struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
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
                            DataRowView(icon: "mic", title: "Voice Channel", description: "Live audio is sent peer-to-peer to connected nearby participants only during an active channel")
                            DataRowView(icon: "photo", title: "Photos", description: "Accessed only when you import images")
                        }
                        .padding(.vertical, 8)
                    }

                    Group {
                        Text("Data Storage")
                            .font(.headline)
                            .padding(.top)

                        Text("Whiteboard, document, and schedule data is stored locally on your device. Voice Channel audio is transmitted only peer-to-peer to connected nearby participants while a channel is active. We do not have access to your content or voice audio.")

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

                        Link("amnasahmd@gmail.com", destination: URL(string: "mailto:amnasahmd@gmail.com")!)
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
        NavigationStack {
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

                        Link("amnasahmd@gmail.com", destination: URL(string: "mailto:amnasahmd@gmail.com")!)
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
        NavigationStack {
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
                            icon: "dot.radiowaves.left.and.right",
                            title: "Peer-to-Peer Voice",
                            description: "Voice Channel audio stays on the local connection between participants and is not recorded by ClapsBoard.",
                            color: .teal
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
        NavigationStack {
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

                        if let url = URL(string: "https://in.linkedin.com/in/amnasahamed") {
                            Link(destination: url) {
                                Label("LinkedIn", systemImage: "person.circle.fill")
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
                            Text("amnasahmd@gmail.com")
                                .font(.caption)
                                .foregroundStyle(.blue)
                            Text("https://clapsboard.com")
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
        if let url = URL(string: "mailto:amnasahmd@gmail.com?subject=ClapsBoard%20Support%20Request") {
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
