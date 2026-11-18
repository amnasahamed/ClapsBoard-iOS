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
    /// Length of the class. Added after the first release, so it is decoded
    /// with a default (see `init(from:)`).
    var durationMinutes: Int
    /// Day keys ("yyyyMMdd") of the occurrences of a repeating class that are
    /// marked complete. A class that does not repeat uses `isCompleted`.
    var completedOccurrences: Set<String>
    
    enum RecurringType: String, CaseIterable, Codable {
        case none = "None"
        case daily = "Daily"
        case weekly = "Weekly"
        case monthly = "Monthly"
    }

    static let defaultDurationMinutes = 60
    
    init(
        id: UUID = UUID(),
        title: String = "",
        date: Date = Date(),
        link: String = "",
        color: String = "#3b82f6",
        notes: String = "",
        isCompleted: Bool = false,
        recurring: RecurringType = .none,
        snoozedUntil: Date? = nil,
        durationMinutes: Int = ClassSession.defaultDurationMinutes,
        completedOccurrences: Set<String> = []
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
        self.durationMinutes = durationMinutes
        self.completedOccurrences = completedOccurrences
    }

    // Tolerant decoding: data saved by an older (or newer) build must still
    // load, otherwise the whole schedule is lost. Only id and date are required.
    // (CodingKeys and encode(to:) are still synthesized.)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        link = (try? c.decodeIfPresent(String.self, forKey: .link)) ?? ""
        color = (try? c.decodeIfPresent(String.self, forKey: .color)) ?? "#3b82f6"
        notes = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? ""
        isCompleted = (try? c.decodeIfPresent(Bool.self, forKey: .isCompleted)) ?? false
        recurring = (try? c.decodeIfPresent(RecurringType.self, forKey: .recurring)) ?? .none
        snoozedUntil = (try? c.decodeIfPresent(Date.self, forKey: .snoozedUntil)) ?? nil
        let minutes = (try? c.decodeIfPresent(Int.self, forKey: .durationMinutes)) ?? ClassSession.defaultDurationMinutes
        durationMinutes = minutes > 0 ? minutes : ClassSession.defaultDurationMinutes
        completedOccurrences = (try? c.decodeIfPresent(Set<String>.self, forKey: .completedOccurrences)) ?? []
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
        ClassSession.countdownText(from: Date(), to: date)
    }

    /// "2h 5m"-style text for the time left until `start`; nil once it has started.
    static func countdownText(from now: Date, to start: Date) -> String? {
        guard start > now else { return nil }
        
        let interval = start.timeIntervalSince(now)
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

    // MARK: Repeat

    /// Stable key for one calendar day, used for per-occurrence completion and
    /// reminder identifiers.
    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The n-th start time of this class (n = 0 is the original date).
    /// Always computed from the ORIGINAL date + n units, so a monthly class on
    /// the 31st lands on the 28th/30th in short months and returns to the 31st
    /// afterwards instead of drifting.
    func occurrenceDate(_ n: Int, calendar: Calendar = .current) -> Date? {
        switch recurring {
        case .none: return n == 0 ? date : nil
        case .daily: return calendar.date(byAdding: .day, value: n, to: date)
        case .weekly: return calendar.date(byAdding: .day, value: 7 * n, to: date)
        case .monthly: return calendar.date(byAdding: .month, value: n, to: date)
        }
    }

    /// Start times of this class inside `start...end` (both inclusive), in order.
    func occurrenceDates(from start: Date, to end: Date, limit: Int = 400, calendar: Calendar = .current) -> [Date] {
        guard start <= end else { return [] }
        if recurring == .none {
            return (date >= start && date <= end) ? [date] : []
        }
        guard date <= end else { return [] }

        // Jump close to `start` instead of walking from the original date.
        var n = 0
        if start > date {
            switch recurring {
            case .daily:
                n = max(0, (calendar.dateComponents([.day], from: date, to: start).day ?? 0) - 1)
            case .weekly:
                n = max(0, (calendar.dateComponents([.day], from: date, to: start).day ?? 0) / 7 - 1)
            case .monthly:
                n = max(0, (calendar.dateComponents([.month], from: date, to: start).month ?? 0) - 1)
            case .none:
                break
            }
        }

        var result: [Date] = []
        while result.count < limit, let occurrence = occurrenceDate(n, calendar: calendar), occurrence <= end {
            if occurrence >= start { result.append(occurrence) }
            n += 1
        }
        return result
    }

    /// Completion is per occurrence for repeating classes.
    func isCompleted(on occurrenceDate: Date) -> Bool {
        recurring == .none ? isCompleted : completedOccurrences.contains(ClassSession.dayKey(for: occurrenceDate))
    }

    // MARK: Meeting link

    /// Turns what the teacher typed ("zoom.us/j/123") into something that can
    /// be opened. Returns nil when it cannot be a usable link.
    static func normalizedLink(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }

        let lower = text.lowercased()
        let hasScheme = text.contains("://") || lower.hasPrefix("mailto:") || lower.hasPrefix("tel:")
        if !hasScheme { text = "https://" + text }

        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "http" || scheme == "https" {
            // A web link needs a real host ("https://meet" is not one).
            guard let host = url.host, host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return nil }
        }
        return url
    }
}

// MARK: - Class Occurrence
/// One concrete start time of a class. A class that repeats has many.
struct ClassOccurrence: Identifiable {
    let session: ClassSession
    let date: Date

    /// "<uuid>-<yyyyMMdd>" — also the reminder identifier for this occurrence.
    var id: String { "\(session.id.uuidString)-\(ClassSession.dayKey(for: date))" }
    var endDate: Date { date.addingTimeInterval(Double(session.durationMinutes) * 60) }
    var isCompleted: Bool { session.isCompleted(on: date) }
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
    /// Raw copy of stored data that could not be read (see `loadSessions`).
    static let unreadableBackupKey = "classSessionsUnreadableBackup"
    /// True while the stored data could not be read at all. Saving an empty
    /// list in that state would wipe data that a later build might still read.
    private var storedDataIsUnreadable = false

    /// How far ahead repeating classes are listed and reminded.
    static let horizonMonths = 3
    /// Cap per repeating class in the List, so a daily class does not fill it.
    static let listOccurrencesPerClass = 10
    
    init() {
        loadSessions()
    }

    /// Decodes one element without failing the whole array.
    private struct Lossy: Decodable {
        let value: ClassSession?
        init(from decoder: Decoder) throws {
            value = try? ClassSession(from: decoder)
        }
    }
    
    func loadSessions() {
        guard let data = UserDefaults.standard.data(forKey: saveKey) else { return }
        
        do {
            let decoded = try JSONDecoder().decode([ClassSession].self, from: data)
            sessions = decoded
            storedDataIsUnreadable = false
            print("✅ Loaded \(decoded.count) class sessions")
        } catch {
            print("❌ Failed to load class sessions: \(error.localizedDescription)")
            // Keep the raw bytes: the next save replaces the original key.
            UserDefaults.standard.set(data, forKey: Self.unreadableBackupKey)
            // Salvage every class that can still be read.
            let salvaged = ((try? JSONDecoder().decode([Lossy].self, from: data)) ?? []).compactMap(\.value)
            sessions = salvaged
            storedDataIsUnreadable = salvaged.isEmpty
        }
    }
    
    func saveSessions() {
        // Nothing was readable and nothing has been added: leave the original alone.
        if storedDataIsUnreadable && sessions.isEmpty { return }
        do {
            let encoded = try JSONEncoder().encode(sessions)
            UserDefaults.standard.set(encoded, forKey: saveKey)
            storedDataIsUnreadable = false
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
    
    /// Toggles completion. For a repeating class pass the occurrence's date so
    /// only that day is marked; without it the whole class is toggled.
    func toggleComplete(id: UUID, occurrenceDate: Date? = nil) {
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            if sessions[index].recurring != .none, let occurrenceDate {
                let key = ClassSession.dayKey(for: occurrenceDate)
                if sessions[index].completedOccurrences.contains(key) {
                    sessions[index].completedOccurrences.remove(key)
                } else {
                    sessions[index].completedOccurrences.insert(key)
                }
            } else {
                sessions[index].isCompleted.toggle()
            }
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

    // MARK: Occurrences (repeat-aware)

    static func horizonEnd(from now: Date) -> Date {
        Calendar.current.date(byAdding: .month, value: horizonMonths, to: now) ?? now.addingTimeInterval(90 * 86_400)
    }

    /// Every class starting on the given calendar day, repeats included, by time.
    func occurrences(on day: Date) -> [ClassOccurrence] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-1) else { return [] }
        return sessions
            .flatMap { session in session.occurrenceDates(from: start, to: end).map { ClassOccurrence(session: session, date: $0) } }
            .sorted { $0.date < $1.date }
    }

    /// Not-completed classes that start after `now`. One-off classes are listed
    /// however far away they are; repeating ones up to the horizon.
    func upcomingOccurrences(now: Date = Date(), perClassLimit: Int = ClassSessionManager.listOccurrencesPerClass) -> [ClassOccurrence] {
        let end = Self.horizonEnd(from: now)
        return sessions.flatMap { session -> [ClassOccurrence] in
            let dates: [Date]
            if session.recurring == .none {
                dates = session.date > now ? [session.date] : []
            } else {
                dates = session.occurrenceDates(from: now, to: end).filter { $0 > now }
            }
            return dates
                .map { ClassOccurrence(session: session, date: $0) }
                .filter { !$0.isCompleted }
                .prefix(perClassLimit)
                .map { $0 }
        }
        .sorted { $0.date < $1.date }
    }

    /// Today's not-completed classes that have already started. They stay in
    /// the List until the day ends so Join remains reachable.
    func startedTodayOccurrences(now: Date = Date()) -> [ClassOccurrence] {
        occurrences(on: now).filter { $0.date <= now && !$0.isCompleted }
    }

    /// Sessions as the Live Activity countdown expects them: each repeating
    /// class is represented by its next occurrence (same id).
    func sessionsForCountdown(now: Date = Date()) -> [ClassSession] {
        let end = Self.horizonEnd(from: now)
        return sessions.map { session in
            guard session.recurring != .none,
                  let next = session.occurrenceDates(from: now, to: end, limit: 1).first else { return session }
            var copy = session
            copy.date = next
            copy.isCompleted = session.isCompleted(on: next)
            return copy
        }
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
