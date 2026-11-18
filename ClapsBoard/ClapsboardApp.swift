//
//  ClapsboardApp.swift
//  ClapsBoard
//
//  Native iOS whiteboard app for teachers
//  Created with SwiftUI for maximum native iOS integration
//

import SwiftUI
import UserNotifications

@main
struct ClapsboardApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var notificationManager = NotificationManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(notificationManager)
                .onAppear {
                    notificationManager.refreshAuthorizationStatus()
                }
                // The app declares PDF and PowerPoint support, so "Open in
                // ClapsBoard" from Files, Mail or the share sheet must work.
                .onOpenURL { url in
                    if DocumentInbox.importFile(at: url) { appState.selectedTab = .docs }
                }
        }
    }
}

// MARK: - Document Inbox
/// Copies documents opened from other apps into the Docs folder.
enum DocumentInbox {
    static let didImport = Notification.Name("ClapsBoardDocumentImported")

    @discardableResult
    static func importFile(at url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let fileManager = FileManager.default
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return false }
        let folder = documents.appendingPathComponent("ClapsBoard Documents", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let baseName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var destination = folder.appendingPathComponent(url.lastPathComponent)
        var counter = 1
        while fileManager.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(baseName)_\(counter).\(ext)")
            counter += 1
        }
        do {
            try fileManager.copyItem(at: url, to: destination)
        } catch {
            print("❌ Could not import opened document: \(error.localizedDescription)")
            return false
        }
        NotificationCenter.default.post(name: didImport, object: nil)
        return true
    }
}

// MARK: - App State
/// Global app state management
class AppState: ObservableObject {
    @Published var selectedTab: Tab = .board
    @Published var showOnboarding: Bool = false
    @Published var showSettings: Bool = false
    
    enum Tab: String, CaseIterable, Hashable {
        case board = "Board"
        case docs = "Docs"
        case calendar = "Plan"
    }
    
    init() {
        // Check if first launch
        if !UserDefaults.standard.bool(forKey: "hasSeenOnboarding") {
            showOnboarding = true
        }
    }
    
    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasSeenOnboarding")
        showOnboarding = false
    }
}

// MARK: - Notification Manager
/// Handles local notifications for class reminders
class NotificationManager: ObservableObject {
    @Published var isAuthorized = false

    /// Settings → Reminders (stored with @AppStorage in SettingsView).
    static let remindersEnabledKey = "classRemindersEnabled"
    static let reminderMinutesKey = "classReminderMinutesBefore"
    private var remindersEnabled: Bool { UserDefaults.standard.object(forKey: Self.remindersEnabledKey) as? Bool ?? true }
    private var minutesBefore: Int { (UserDefaults.standard.object(forKey: Self.reminderMinutesKey) as? Int) ?? 5 }

    init() {
        refreshAuthorizationStatus()
    }
    
    func refreshAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.isAuthorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            }
        }
    }

    func requestAuthorization(completion: ((Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            DispatchQueue.main.async {
                self.isAuthorized = granted
                completion?(granted)
            }
        }
    }
    
    func scheduleClassNotification(for classSession: ClassSession) {
        guard remindersEnabled else { return }
        if isAuthorized {
            addNotificationRequest(for: classSession)
            return
        }

        requestAuthorization { [weak self] granted in
            guard granted else { return }
            self?.addNotificationRequest(for: classSession)
        }
    }

    private func addNotificationRequest(for classSession: ClassSession) {
        let minutes = minutesBefore
        let classDate = classSession.date.addingTimeInterval(-Double(minutes) * 60)
        guard classDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Class Starting Soon"
        content.body = "\(classSession.title) starts in \(minutes) minutes"
        content.sound = .default
        
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: classDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        
        let request = UNNotificationRequest(identifier: classSession.id.uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
    
    /// Class reminders are the only notifications this app schedules.
    func cancelAllClassReminders() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    func cancelNotification(for classId: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [classId.uuidString])
    }
}
