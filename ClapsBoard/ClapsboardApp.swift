//
//  ClapsboardApp.swift
//  ClapsBoard
//
//  Native iOS whiteboard app for teachers
//  Created with SwiftUI for maximum native iOS integration
//

import SwiftUI

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
                    notificationManager.requestAuthorization()
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
    
    enum Tab: String, CaseIterable {
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
    
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            DispatchQueue.main.async {
                self.isAuthorized = granted
            }
        }
    }
    
    func scheduleClassNotification(for classSession: ClassSession) {
        let content = UNMutableNotificationContent()
        content.title = "Class Starting Soon"
        content.body = "\(classSession.title) starts in 5 minutes"
        content.sound = .default
        
        // Schedule 5 minutes before class
        let classDate = classSession.date.addingTimeInterval(-5 * 60)
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: classDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        
        let request = UNNotificationRequest(identifier: classSession.id.uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
    
    func cancelNotification(for classId: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [classId.uuidString])
    }
}
