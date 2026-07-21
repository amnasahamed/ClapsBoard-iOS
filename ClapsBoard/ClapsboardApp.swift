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
        }
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
        let classDate = classSession.date.addingTimeInterval(-5 * 60)
        guard classDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Class Starting Soon"
        content.body = "\(classSession.title) starts in 5 minutes"
        content.sound = .default
        
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: classDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        
        let request = UNNotificationRequest(identifier: classSession.id.uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
    
    func cancelNotification(for classId: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [classId.uuidString])
    }
}
