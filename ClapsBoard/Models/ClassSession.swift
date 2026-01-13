//
//  ClassSession.swift
//  ClapsBoard
//
//  Model for class/meeting sessions with scheduling support
//

import SwiftUI

// MARK: - Class Session Model
struct ClassSession: Identifiable, Codable {
    let id: UUID
    var title: String
    var date: Date
    var link: String
    var color: String
    var notes: String
    var isCompleted: Bool
    var recurring: RecurringType
    var snoozedUntil: Date?
    
    enum RecurringType: String, CaseIterable, Codable {
        case none = "None"
        case daily = "Daily"
        case weekly = "Weekly"
        case monthly = "Monthly"
    }
    
    init(
        id: UUID = UUID(),
        title: String = "",
        date: Date = Date(),
        link: String = "",
        color: String = "#3b82f6",
        notes: String = "",
        isCompleted: Bool = false,
        recurring: RecurringType = .none,
        snoozedUntil: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.link = link
        self.color = color
        self.notes = notes
        self.isCompleted = isCompleted
        self.recurring = recurring
        self.snoozedUntil = snoozedUntil
    }
    
    var swiftUIColor: Color {
        Color(hex: color)
    }
    
    var isUpcoming: Bool {
        date > Date()
    }
    
    var isPast: Bool {
        date < Date()
    }
    
    var timeUntil: String? {
        guard isUpcoming else { return nil }
        
        let interval = date.timeIntervalSince(Date())
        let minutes = Int(interval / 60)
        let hours = minutes / 60
        let days = hours / 24
        
        if days > 0 {
            return "\(days)d \(hours % 24)h"
        } else if hours > 0 {
            return "\(hours)h \(minutes % 60)m"
        } else if minutes > 0 {
            return "\(minutes)m"
        } else {
            return "Now"
        }
    }
}

// MARK: - Subject Colors
struct SubjectColor: Identifiable {
    let id = UUID()
    let hex: String
    let name: String
    
    var color: Color { Color(hex: hex) }
    
    static let all: [SubjectColor] = [
        SubjectColor(hex: "#3b82f6", name: "Blue"),
        SubjectColor(hex: "#ef4444", name: "Red"),
        SubjectColor(hex: "#22c55e", name: "Green"),
        SubjectColor(hex: "#eab308", name: "Yellow"),
        SubjectColor(hex: "#a855f7", name: "Purple"),
        SubjectColor(hex: "#f97316", name: "Orange")
    ]
}

// MARK: - Class Session Manager
class ClassSessionManager: ObservableObject {
    @Published var sessions: [ClassSession] = []
    
    private let saveKey = "classSessions"
    
    init() {
        loadSessions()
    }
    
    func loadSessions() {
        guard let data = UserDefaults.standard.data(forKey: saveKey) else { return }
        
        do {
            let decoded = try JSONDecoder().decode([ClassSession].self, from: data)
            sessions = decoded
            print("✅ Loaded \(decoded.count) class sessions")
        } catch {
            print("❌ Failed to load class sessions: \(error.localizedDescription)")
        }
    }
    
    func saveSessions() {
        do {
            let encoded = try JSONEncoder().encode(sessions)
            UserDefaults.standard.set(encoded, forKey: saveKey)
        } catch {
            print("❌ Failed to save class sessions: \(error.localizedDescription)")
        }
    }
    
    func addSession(_ session: ClassSession) {
        sessions.append(session)
        saveSessions()
    }
    
    func updateSession(_ session: ClassSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
            saveSessions()
        }
    }
    
    func deleteSession(id: UUID) {
        sessions.removeAll { $0.id == id }
        saveSessions()
    }
    
    func toggleComplete(id: UUID) {
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].isCompleted.toggle()
            saveSessions()
        }
    }
    
    func snooze(id: UUID, for duration: TimeInterval = 3600) {
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].snoozedUntil = Date().addingTimeInterval(duration)
            saveSessions()
        }
    }
    
    // Get sessions for a specific date
    func sessions(for date: Date) -> [ClassSession] {
        sessions.filter { Calendar.current.isDate($0.date, inSameDayAs: date) }
    }
    
    // Get upcoming sessions
    var upcomingSessions: [ClassSession] {
        sessions.filter { $0.isUpcoming && !$0.isCompleted }
            .sorted { $0.date < $1.date }
    }
    
    // Group sessions by day
    var groupedByDay: [(date: Date, sessions: [ClassSession])] {
        let grouped = Dictionary(grouping: sessions) { session in
            Calendar.current.startOfDay(for: session.date)
        }
        return grouped.sorted { $0.key < $1.key }
            .map { (date: $0.key, sessions: $0.value.sorted { $0.date < $1.date }) }
    }
}
