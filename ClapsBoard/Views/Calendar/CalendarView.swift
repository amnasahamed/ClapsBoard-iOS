//
//  CalendarView.swift
//  ClapsBoard
//
//  Calendar and class scheduling view
//

import SwiftUI

/// Calendar and class scheduling view (HIG: Navigation, Accessibility)
struct CalendarView: View {
    @StateObject private var sessionManager = ClassSessionManager()
    @StateObject private var liveActivityCoordinator = ClassCountdownLiveActivityCoordinator()
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var notificationManager: NotificationManager
    @Environment(\.scenePhase) private var scenePhase
    
    @State private var selectedDate = Date()
    @State private var currentMonth = Date()
    @State private var viewMode: CalendarViewMode = .list
    @State private var showAddSheet = false
    @State private var editingSession: ClassSession?
    
    enum CalendarViewMode: String, CaseIterable {
        case list = "List"
        case week = "Week"
        case month = "Month"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 10) {
                // Title Area with Safe Area Padding
                HStack {
                    AppModeMenu(selectedTab: $appState.selectedTab)

                    Spacer()

                    Button(action: { showAddSheet = true }) {
                        ZStack {
                            Circle()
                                .fill(AppTheme.accentSoft)
                                .frame(width: 38, height: 38)

                            Image(systemName: "plus")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(AppTheme.accent)
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                    }
                    .accessibilityLabel("Add class")
                    .accessibilityHint("Opens form to schedule a new class")
                }
                .shadow(color: .black.opacity(0.04), radius: 16, y: 6)
                .padding(.horizontal, 28)
                .padding(.top, 8)
                
                // View Mode Picker
                Picker("View", selection: $viewMode) {
                    ForEach(CalendarViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
            }
            .background(Color(.systemBackground))
            
            // Content
            ScrollView {
                VStack(spacing: 16) {
                    switch viewMode {
                    case .list:
                        ListView(sessions: sessionManager.upcomingSessions, sessionManager: sessionManager, editSession: { session in
                            editingSession = session
                        })
                        
                    case .week:
                        WeekView(
                            selectedDate: $selectedDate,
                            sessions: sessionManager.sessions,
                            getSessionsForDate: { sessionManager.sessions(for: $0) },
                            sessionManager: sessionManager,
                            editSession: { session in
                                editingSession = session
                            }
                        )
                        
                    case .month:
                        MonthView(
                            currentMonth: $currentMonth,
                            selectedDate: $selectedDate,
                            sessions: sessionManager.sessions,
                            getSessionsForDate: { sessionManager.sessions(for: $0) },
                            sessionManager: sessionManager,
                            editSession: { session in
                                editingSession = session
                            }
                        )
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            ClassFormSheet(
                session: nil,
                onSave: { session in
                    sessionManager.addSession(session)
                    notificationManager.scheduleClassNotification(for: session)
                    liveActivityCoordinator.updateSessions(sessionManager.sessions)
                },
                onDelete: nil
            )
        }
        .sheet(item: $editingSession) { session in
            ClassFormSheet(
                session: session,
                onSave: { updated in
                    sessionManager.updateSession(updated)
                    notificationManager.scheduleClassNotification(for: updated)
                    liveActivityCoordinator.updateSessions(sessionManager.sessions)
                },
                onDelete: { id in
                    sessionManager.deleteSession(id: id)
                    notificationManager.cancelNotification(for: id)
                    liveActivityCoordinator.endActivity(for: id)
                    liveActivityCoordinator.updateSessions(sessionManager.sessions)
                }
            )
        }
        .onAppear {
            liveActivityCoordinator.startMonitoring(sessions: sessionManager.sessions)
        }
        .onReceive(sessionManager.$sessions) { sessions in
            liveActivityCoordinator.updateSessions(sessions)
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            liveActivityCoordinator.updateSessions(sessionManager.sessions)
        }
    }
}

// MARK: - List View
struct ListView: View {
    let sessions: [ClassSession]
    let sessionManager: ClassSessionManager
    let editSession: (ClassSession) -> Void
    
    var body: some View {
        if sessions.isEmpty {
            EmptyStateView()
        } else {
            LazyVStack(spacing: 12) {
                ForEach(sessions) { session in
                    ClassCard(session: session, onEdit: editSession, sessionManager: sessionManager)
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

// MARK: - Empty State
struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(.regularMaterial)
                    .frame(width: 68, height: 68)

                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(AppTheme.accent.opacity(0.78))
            }

            VStack(spacing: 5) {
                Text("No classes yet")
                    .font(.callout.weight(.semibold))

                Text("Tap + to schedule one")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 76)
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Class Card
struct ClassCard: View {
    let session: ClassSession
    let onEdit: (ClassSession) -> Void
    let sessionManager: ClassSessionManager

    @State private var showActions = false
    @State private var isPressed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                // Color Indicator
                RoundedRectangle(cornerRadius: 4)
                    .fill(session.swiftUIColor)
                    .frame(width: 4, height: 50)

                VStack(alignment: .leading, spacing: 4) {
                    // Title
                    Text(session.title)
                        .font(.headline)
                        .strikethrough(session.isCompleted, color: .secondary)
                        .foregroundStyle(session.isCompleted ? .secondary : .primary)

                    // Time
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption)
                        Text(session.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)

                    // Countdown
                    if let countdown = session.timeUntil {
                        Text(countdown)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AppTheme.accent)
                    }
                }

                Spacer()

                // Quick Actions
                HStack(spacing: 8) {
                    // Join Button (if has link)
                    if !session.link.isEmpty {
                        Button(action: { openLink() }) {
                            Image(systemName: "video.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(session.swiftUIColor, in: Circle())
                        }
                    }

                    // Complete Toggle
                    Button(action: { sessionManager.toggleComplete(id: session.id) }) {
                        Image(systemName: session.isCompleted ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 24))
                            .foregroundStyle(session.isCompleted ? .green : .secondary)
                    }
                    .frame(width: 44, height: 44)

                    // Edit Button
                    Button(action: { onEdit(session) }) {
                        Image(systemName: "pencil")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                            .background(Color.gray.opacity(0.1), in: Circle())
                    }
                }
            }

            // Notes (if any)
            if !session.notes.isEmpty {
                Text(session.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(isPressed ? 0.12 : 0.05), radius: isPressed ? 14 : 10, y: isPressed ? 8 : 5)
        )
        .opacity(session.isCompleted ? 0.7 : 1)
        .scaleEffect(isPressed ? 0.98 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isPressed)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onChanged { _ in
                    isPressed = true
                }
                .onEnded { _ in
                    isPressed = false
                }
        )
    }

    private func openLink() {
        if let url = URL(string: session.link) {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Week View
struct WeekView: View {
    @Binding var selectedDate: Date
    let sessions: [ClassSession]
    let getSessionsForDate: (Date) -> [ClassSession]
    let sessionManager: ClassSessionManager
    let editSession: (ClassSession) -> Void
    
    private var weekDays: [Date] {
        let calendar = Calendar.current
        let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: selectedDate))!
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: startOfWeek) }
    }
    
    var body: some View {
        VStack(spacing: 16) {
            // Week Navigation
            HStack {
                Button(action: { moveWeek(-1) }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                }

                Spacer()

                Text(weekTitle)
                    .font(.headline)

                Spacer()

                Button(action: { moveWeek(1) }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
            }
            .padding(.horizontal, 20)
            
            // Days Row
            HStack(spacing: 8) {
                ForEach(weekDays, id: \.self) { day in
                    DayCell(
                        date: day,
                        isSelected: Calendar.current.isDate(day, inSameDayAs: selectedDate),
                        hasEvents: !getSessionsForDate(day).isEmpty,
                        onTap: { selectedDate = day }
                    )
                }
            }
            .padding(.horizontal, 8)
            
            // Sessions for selected day
            let daysSessions = getSessionsForDate(selectedDate)
            if daysSessions.isEmpty {
                Text("No classes on this day")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 20)
            } else {
                ForEach(daysSessions) { session in
                    ClassCard(session: session, onEdit: editSession, sessionManager: sessionManager)
                        .padding(.horizontal, 20)
                }
            }
        }
    }
    
    private var weekTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: selectedDate)
    }
    
    private func moveWeek(_ direction: Int) {
        if let newDate = Calendar.current.date(byAdding: .weekOfYear, value: direction, to: selectedDate) {
            selectedDate = newDate
        }
    }
}

// MARK: - Day Cell
struct DayCell: View {
    let date: Date
    let isSelected: Bool
    let hasEvents: Bool
    let onTap: () -> Void
    
    private var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Text(dayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                
                Text(dayNumber)
                    .font(.system(size: 18, weight: isToday ? .bold : .medium))
                    .foregroundStyle(isSelected ? .white : (isToday ? AppTheme.accent : .primary))
                
                // Event indicator
                Circle()
                    .fill(hasEvents ? (isSelected ? .white : AppTheme.accent) : .clear)
                    .frame(width: 6, height: 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                isSelected ? AppTheme.accent : Color.clear,
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
    }
    
    private var dayName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: date).uppercased()
    }
    
    private var dayNumber: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter.string(from: date)
    }
}

// MARK: - Month View
struct MonthView: View {
    @Binding var currentMonth: Date
    @Binding var selectedDate: Date
    let sessions: [ClassSession]
    let getSessionsForDate: (Date) -> [ClassSession]
    let sessionManager: ClassSessionManager
    let editSession: (ClassSession) -> Void
    
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    
    var body: some View {
        VStack(spacing: 16) {
            // Month Navigation
            HStack {
                Button(action: { moveMonth(-1) }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                }

                Spacer()

                Text(monthTitle)
                    .font(.headline)

                Spacer()

                Button(action: { moveMonth(1) }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
            }
            .padding(.horizontal, 20)
            
            // Day Headers
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(Array(["S", "M", "T", "W", "T", "F", "S"].enumerated()), id: \.offset) { _, day in
                    Text(day)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(height: 30)
                }
            }
            .padding(.horizontal, 8)
            
            // Calendar Grid
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(daysInMonth.enumerated()), id: \.offset) { _, date in
                    if let date = date {
                        MonthDayCell(
                            date: date,
                            isSelected: Calendar.current.isDate(date, inSameDayAs: selectedDate),
                            hasEvents: !getSessionsForDate(date).isEmpty,
                            isCurrentMonth: Calendar.current.isDate(date, equalTo: currentMonth, toGranularity: .month),
                            onTap: { selectedDate = date }
                        )
                    } else {
                        Color.clear
                            .frame(height: 44)
                    }
                }
            }
            .padding(.horizontal, 8)

            selectedDaySessions
        }
    }

    @ViewBuilder
    private var selectedDaySessions: some View {
        let daySessions = getSessionsForDate(selectedDate).sorted { $0.date < $1.date }

        if daySessions.isEmpty {
            Text("No classes on this day")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        } else {
            LazyVStack(spacing: 12) {
                ForEach(daySessions) { session in
                    ClassCard(session: session, onEdit: editSession, sessionManager: sessionManager)
                }
            }
            .padding(.horizontal, 20)
        }
    }
    
    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: currentMonth)
    }
    
    private var daysInMonth: [Date?] {
        let calendar = Calendar.current
        let interval = calendar.dateInterval(of: .month, for: currentMonth)!
        let firstDay = interval.start
        let firstWeekday = calendar.component(.weekday, from: firstDay)
        
        var days: [Date?] = Array(repeating: nil, count: firstWeekday - 1)
        
        var currentDate = firstDay
        while currentDate < interval.end {
            days.append(currentDate)
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate)!
        }
        
        return days
    }
    
    private func moveMonth(_ direction: Int) {
        if let newMonth = Calendar.current.date(byAdding: .month, value: direction, to: currentMonth) {
            currentMonth = newMonth
        }
    }
}

// MARK: - Month Day Cell
struct MonthDayCell: View {
    let date: Date
    let isSelected: Bool
    let hasEvents: Bool
    let isCurrentMonth: Bool
    let onTap: () -> Void
    
    private var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 2) {
                Text("\(Calendar.current.component(.day, from: date))")
                    .font(.system(size: 16, weight: isToday ? .bold : .regular))
                    .foregroundStyle(
                        isSelected ? .white : (isToday ? AppTheme.accent : (isCurrentMonth ? .primary : .secondary.opacity(0.5)))
                    )
                
                if hasEvents {
                    Circle()
                        .fill(isSelected ? .white : AppTheme.accent)
                        .frame(width: 4, height: 4)
                }
            }
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .background(
                isSelected ? AppTheme.accent : (isToday ? AppTheme.accent.opacity(0.1) : Color.clear),
                in: Circle()
            )
        }
    }
}

// MARK: - Preview
#Preview {
    CalendarView()
        .environmentObject(AppState())
        .environmentObject(NotificationManager())
}
