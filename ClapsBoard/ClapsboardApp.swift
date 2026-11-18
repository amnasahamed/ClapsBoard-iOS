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
    // Owned here (not by the Plan tab) so Settings and the reminder scheduler
    // see the same classes.
    @StateObject private var sessionManager = ClassSessionManager()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Without a delegate iOS shows no banner while the app is on screen,
        // which is exactly when a teacher is using it.
        UNUserNotificationCenter.current().delegate = ForegroundNotificationPresenter.shared
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(notificationManager)
                .environmentObject(sessionManager)
                .onAppear {
                    notificationManager.refreshAuthorizationStatus()
                }
                // Fires once at launch and after every add / edit / delete /
                // complete, so pending reminders always match the schedule.
                .onReceive(sessionManager.$sessions) { sessions in
                    notificationManager.rescheduleAll(sessions: sessions)
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    // Permission may have been changed in iOS Settings, and
                    // repeating classes need their reminder window rolled forward.
                    notificationManager.refreshAuthorizationStatus()
                    notificationManager.rescheduleAll(sessions: sessionManager.sessions)
                }
                // The app declares PDF and PowerPoint support, so "Open in
                // ClapsBoard" from Files, Mail or the share sheet must work.
                .onOpenURL { url in
                    if DocumentInbox.importFile(at: url) { appState.selectedTab = .docs }
                }
        }
    }
}

/// Shows class reminders as a banner even while ClapsBoard is in the foreground.
final class ForegroundNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ForegroundNotificationPresenter()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
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
    /// Raw status, so Settings can tell "never asked" from "denied".
    @Published var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// Settings → Reminders (stored with @AppStorage in SettingsView).
    static let remindersEnabledKey = "classRemindersEnabled"
    static let reminderMinutesKey = "classReminderMinutesBefore"
    private var remindersEnabled: Bool { UserDefaults.standard.object(forKey: Self.remindersEnabledKey) as? Bool ?? true }
    private var minutesBefore: Int { (UserDefaults.standard.object(forKey: Self.reminderMinutesKey) as? Int) ?? 5 }

    // iOS keeps at most 64 pending requests per app; stay well below it.
    static let maxPendingReminders = 40
    /// Per class, so one daily class cannot use the whole budget.
    static let maxRemindersPerClass = 8

    private var rescheduleGeneration = 0
    /// A save asked for the permission prompt; remembered because the automatic
    /// reschedule that follows the same change would otherwise supersede it.
    private var promptRequested = false

    init() {
        refreshAuthorizationStatus()
    }
    
    func refreshAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.authorizationStatus = settings.authorizationStatus
                self.isAuthorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            }
        }
    }

    func requestAuthorization(completion: ((Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            DispatchQueue.main.async {
                self.isAuthorized = granted
                self.refreshAuthorizationStatus()
                completion?(granted)
            }
        }
    }

    /// Replaces every pending class reminder with the ones the current
    /// schedule and Settings call for. Removing first is what keeps reminders
    /// from going stale after an edit, a completion or a Settings change.
    /// - Parameter promptIfNeeded: ask for notification permission if it has
    ///   never been asked (used when the teacher saves a class or turns
    ///   reminders on; never at launch).
    func rescheduleAll(sessions: [ClassSession], promptIfNeeded: Bool = false) {
        let center = UNUserNotificationCenter.current()
        // Class reminders are the only notifications this app schedules.
        center.removeAllPendingNotificationRequests()
        rescheduleGeneration += 1 // invalidates any add still in flight
        if promptIfNeeded { promptRequested = true }
        guard remindersEnabled else { return }

        let requests = Self.reminderRequests(for: sessions, minutesBefore: minutesBefore, now: Date())
        guard !requests.isEmpty else { return }

        // Two reschedules can overlap (their adds run asynchronously); only
        // the latest one may add, or an older list could re-add stale reminders.
        rescheduleGeneration += 1
        let generation = rescheduleGeneration

        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self, generation == self.rescheduleGeneration else { return }
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    requests.forEach { center.add($0) }
                case .notDetermined where self.promptRequested:
                    self.promptRequested = false
                    self.requestAuthorization { granted in
                        guard granted, generation == self.rescheduleGeneration else { return }
                        requests.forEach { center.add($0) }
                    }
                default:
                    self.promptRequested = false
                }
            }
        }
    }

    /// Builds the reminder requests: the soonest not-completed occurrences in
    /// the next few months, identified as "<uuid>-<yyyyMMdd>".
    static func reminderRequests(for sessions: [ClassSession], minutesBefore: Int, now: Date) -> [UNNotificationRequest] {
        let end = ClassSessionManager.horizonEnd(from: now)
        let calendar = Calendar.current

        let upcoming: [ClassOccurrence] = sessions.flatMap { session in
            session.occurrenceDates(from: now, to: end)
                .map { ClassOccurrence(session: session, date: $0) }
                // A class starting this very second cannot be reminded about.
                .filter { !$0.isCompleted && $0.date.timeIntervalSince(now) > 2 }
                .prefix(maxRemindersPerClass)
        }
        .sorted { $0.date < $1.date }

        return upcoming.prefix(maxPendingReminders).map { occurrence in
            let title = occurrence.session.title
            let content = UNMutableNotificationContent()
            content.sound = .default

            var fireDate = occurrence.date.addingTimeInterval(-Double(minutesBefore) * 60)
            if fireDate.timeIntervalSince(now) > 2 {
                content.title = "Class Starting Soon"
                content.body = "\(title) starts in \(minutesBefore) minutes"
            } else {
                // The class is sooner than the lead time. Remind at the start
                // instead of silently dropping it. (Using the start time, not
                // "now + a few seconds", keeps repeated reschedules from
                // sending the same alert again and again.)
                fireDate = occurrence.date
                content.title = "Class Starting Now"
                content.body = "\(title) is starting now"
            }

            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            return UNNotificationRequest(identifier: occurrence.id, content: content, trigger: trigger)
        }
    }
    
    /// Class reminders are the only notifications this app schedules.
    func cancelAllClassReminders() {
        rescheduleGeneration += 1
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    /// Removes every pending reminder of one class (all its occurrences).
    func cancelNotification(for classId: UUID) {
        let center = UNUserNotificationCenter.current()
        let prefix = classId.uuidString
        center.getPendingNotificationRequests { requests in
            center.removePendingNotificationRequests(withIdentifiers: requests.map(\.identifier).filter { $0.hasPrefix(prefix) })
        }
    }
}
