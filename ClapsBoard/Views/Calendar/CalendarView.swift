//
//  CalendarView.swift
//  ClapsBoard
//
//  Calendar and class scheduling view
//

import SwiftUI

/// Calendar and class scheduling view (HIG: Navigation, Accessibility)
struct CalendarView: View {
    // Shared with Settings and the reminder scheduler (owned by ClapsboardApp).
    @EnvironmentObject var sessionManager: ClassSessionManager
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

                    if viewMode != .list && !isShowingToday {
                        Button("Today", action: goToToday)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.accent)
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .background(AppTheme.accentSoft, in: Capsule())
                            .frame(minHeight: 44)
                            .accessibilityHint("Jumps back to today")
                    }

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
            // Re-rendered every 30 s so countdowns, "in progress" and "today"
            // stay correct while the Plan tab is left open.
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                let now = timeline.date
                ScrollView {
                    VStack(spacing: 16) {
                        switch viewMode {
                        case .list:
                            ListView(now: now, sessionManager: sessionManager, editSession: { session in
                                editingSession = session
                            })

                        case .week:
                            WeekView(
                                selectedDate: $selectedDate,
                                now: now,
                                sessionManager: sessionManager,
                                editSession: { session in
                                    editingSession = session
                                }
                            )

                        case .month:
                            MonthView(
                                currentMonth: $currentMonth,
                                selectedDate: $selectedDate,
                                now: now,
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
                // Midnight passed: a selection that was sitting on "today"
                // follows the new day instead of silently becoming yesterday.
                .onChange(of: Calendar.current.startOfDay(for: now)) { oldDay, newDay in
                    if Calendar.current.isDate(selectedDate, inSameDayAs: oldDay) { selectedDate = newDay }
                    if Calendar.current.isDate(currentMonth, equalTo: oldDay, toGranularity: .month) { currentMonth = newDay }
                    syncLiveActivity()
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            ClassFormSheet(
                session: nil,
                onSave: { session in
                    sessionManager.addSession(session)
                    // Saving a class is the moment to ask for notification permission.
                    notificationManager.rescheduleAll(sessions: sessionManager.sessions, promptIfNeeded: true)
                    syncLiveActivity()
                },
                onDelete: nil
            )
        }
        .sheet(item: $editingSession) { session in
            ClassFormSheet(
                session: session,
                onSave: { updated in
                    sessionManager.updateSession(updated)
                    // Removes the old reminder first, so moving a class never
                    // leaves a reminder at the old time.
                    notificationManager.rescheduleAll(sessions: sessionManager.sessions, promptIfNeeded: true)
                    syncLiveActivity()
                },
                onDelete: { id in
                    sessionManager.deleteSession(id: id)
                    notificationManager.cancelNotification(for: id)
                    liveActivityCoordinator.endActivity(for: id)
                    syncLiveActivity()
                }
            )
        }
        .onAppear {
            liveActivityCoordinator.startMonitoring(sessions: sessionManager.sessionsForCountdown())
        }
        .onReceive(sessionManager.$sessions) { _ in
            // $sessions fires before the new value is stored; read it afterwards.
            DispatchQueue.main.async { syncLiveActivity() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            syncLiveActivity()
        }
    }

    /// Repeating classes are handed to the countdown as their next occurrence.
    private func syncLiveActivity() {
        liveActivityCoordinator.updateSessions(sessionManager.sessionsForCountdown())
    }

    private var isShowingToday: Bool {
        let calendar = Calendar.current
        let today = Date()
        guard calendar.isDate(selectedDate, inSameDayAs: today) else { return false }
        return viewMode != .month || calendar.isDate(currentMonth, equalTo: today, toGranularity: .month)
    }

    private func goToToday() {
        selectedDate = Date()
        currentMonth = Date()
    }
}

// MARK: - List View
struct ListView: View {
    let now: Date
    @ObservedObject var sessionManager: ClassSessionManager
    let editSession: (ClassSession) -> Void
    
    var body: some View {
        let started = sessionManager.startedTodayOccurrences(now: now)
        let upcoming = sessionManager.upcomingOccurrences(now: now)

        if started.isEmpty && upcoming.isEmpty {
            EmptyStateView()
        } else {
            LazyVStack(alignment: .leading, spacing: 12) {
                // Classes that have started stay here until the day ends, so
                // Join is still one tap away during the lesson.
                if !started.isEmpty {
                    PlanSectionHeader(title: "Earlier today / In progress")
                    ForEach(started) { occurrence in
                        ClassCard(occurrence: occurrence, now: now, onEdit: editSession, sessionManager: sessionManager)
                    }
                }

                if !upcoming.isEmpty {
                    if !started.isEmpty { PlanSectionHeader(title: "Upcoming") }
                    ForEach(upcoming) { occurrence in
                        ClassCard(occurrence: occurrence, now: now, onEdit: editSession, sessionManager: sessionManager)
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

struct PlanSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
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
    let occurrence: ClassOccurrence
    let now: Date
    let onEdit: (ClassSession) -> Void
    let sessionManager: ClassSessionManager

    @State private var showActions = false
    @State private var isPressed = false
    @State private var showLinkError = false

    private var session: ClassSession { occurrence.session }
    private var isCompleted: Bool { occurrence.isCompleted }

    private var timeText: String {
        let end = occurrence.endDate.formatted(date: .omitted, time: .shortened)
        return "\(occurrence.date.formatted(date: .abbreviated, time: .shortened)) – \(end)"
    }

    /// Countdown before the start, "In progress" until the end time.
    private var statusText: String? {
        guard !isCompleted else { return nil }
        if let countdown = ClassSession.countdownText(from: now, to: occurrence.date) { return countdown }
        return now < occurrence.endDate ? "In progress" : nil
    }

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
                        .strikethrough(isCompleted, color: .secondary)
                        .foregroundStyle(isCompleted ? .secondary : .primary)

                    // Time
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption)
                        Text(timeText)
                            .font(.caption)
                        if session.recurring != .none {
                            Image(systemName: "repeat")
                                .font(.caption2)
                                .accessibilityLabel("Repeats \(session.recurring.rawValue.lowercased())")
                        }
                    }
                    .foregroundStyle(.secondary)

                    // Countdown
                    if let countdown = statusText {
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
                        .accessibilityLabel("Join \(session.title)")
                    }

                    // Complete Toggle
                    // Reminders follow automatically: ClapsboardApp reschedules
                    // whenever the sessions change (cancel on complete, restore on undo).
                    Button(action: { sessionManager.toggleComplete(id: session.id, occurrenceDate: occurrence.date) }) {
                        Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 24))
                            .foregroundStyle(isCompleted ? .green : .secondary)
                    }
                    .frame(width: 44, height: 44)
                    .accessibilityLabel(isCompleted ? "Mark not completed" : "Mark completed")

                    // Edit Button
                    Button(action: { onEdit(session) }) {
                        Image(systemName: "pencil")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                            .background(Color.gray.opacity(0.1), in: Circle())
                    }
                    .accessibilityLabel("Edit \(session.title)")
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
        .opacity(isCompleted ? 0.7 : 1)
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
        .alert("Can't Open Link", isPresented: $showLinkError) {
            Button("Edit Class") { onEdit(session) }
            Button("OK", role: .cancel) { }
        } message: {
            Text("\"\(session.link)\" could not be opened. Check the meeting link for this class.")
        }
    }

    private func openLink() {
        // Links typed without "https://" used to do nothing at all.
        guard let url = ClassSession.normalizedLink(session.link) else {
            showLinkError = true
            return
        }
        UIApplication.shared.open(url) { opened in
            if !opened { showLinkError = true }
        }
    }
}

// MARK: - Week View
struct WeekView: View {
    @Binding var selectedDate: Date
    let now: Date
    @ObservedObject var sessionManager: ClassSessionManager
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
                        hasEvents: !sessionManager.occurrences(on: day).isEmpty,
                        onTap: { selectedDate = day }
                    )
                }
            }
            .padding(.horizontal, 8)
            
            // Sessions for selected day
            SelectedDayList(date: selectedDate, now: now, sessionManager: sessionManager, editSession: editSession)
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

// MARK: - Selected Day List
/// The classes of the selected day (Week and Month views), with a heading that
/// says which day is listed, sorted by start time.
struct SelectedDayList: View {
    let date: Date
    let now: Date
    let sessionManager: ClassSessionManager
    let editSession: (ClassSession) -> Void

    var body: some View {
        let dayOccurrences = sessionManager.occurrences(on: date)

        VStack(alignment: .leading, spacing: 12) {
            PlanSectionHeader(title: Calendar.current.isDate(date, inSameDayAs: now)
                              ? "Today, \(date.formatted(.dateTime.day().month(.wide)))"
                              : date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))

            if dayOccurrences.isEmpty {
                Text("No classes on this day")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            } else {
                ForEach(dayOccurrences) { occurrence in
                    ClassCard(occurrence: occurrence, now: now, onEdit: editSession, sessionManager: sessionManager)
                }
            }
        }
        .padding(.horizontal, 20)
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
    let now: Date
    @ObservedObject var sessionManager: ClassSessionManager
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
                            hasEvents: !sessionManager.occurrences(on: date).isEmpty,
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

            SelectedDayList(date: selectedDate, now: now, sessionManager: sessionManager, editSession: editSession)
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
        let calendar = Calendar.current
        if let newMonth = calendar.date(byAdding: .month, value: direction, to: currentMonth) {
            currentMonth = newMonth
            // Keep the selection (and so the list below) inside the month on
            // screen: today when it is this month, otherwise the same day
            // number (clamped to the month's length by Calendar).
            if calendar.isDate(Date(), equalTo: newMonth, toGranularity: .month) {
                selectedDate = Date()
            } else if !calendar.isDate(selectedDate, equalTo: newMonth, toGranularity: .month) {
                let monthsApart = calendar.dateComponents(
                    [.month],
                    from: calendar.dateInterval(of: .month, for: selectedDate)?.start ?? selectedDate,
                    to: calendar.dateInterval(of: .month, for: newMonth)?.start ?? newMonth
                ).month ?? direction
                selectedDate = calendar.date(byAdding: .month, value: monthsApart, to: selectedDate) ?? newMonth
            }
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
        .environmentObject(ClassSessionManager())
}
