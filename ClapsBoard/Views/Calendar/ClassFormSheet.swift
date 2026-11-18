//
//  ClassFormSheet.swift
//  ClapsBoard
//
//  Form for adding/editing class sessions
//

import SwiftUI

struct ClassFormSheet: View {
    let session: ClassSession?
    let onSave: (ClassSession) -> Void
    let onDelete: ((UUID) -> Void)?
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var title: String = ""
    // Not "now": a class created with the untouched default would already be
    // in the past a second later and never show as upcoming.
    @State private var date: Date = ClassFormSheet.nextHalfHour()
    @State private var durationMinutes: Int = ClassSession.defaultDurationMinutes
    @State private var link: String = ""
    @State private var selectedColor: String = "#3b82f6"
    @State private var notes: String = ""
    @State private var recurring: ClassSession.RecurringType = .none
    @State private var showDeleteConfirm = false
    
    private var isEditing: Bool { session != nil }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedLink: String { link.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var linkLooksInvalid: Bool { !trimmedLink.isEmpty && ClassSession.normalizedLink(trimmedLink) == nil }

    private var durationOptions: [Int] {
        // Keep an unusual stored value selectable instead of silently changing it.
        Array(Set([30, 45, 60, 90, 120, durationMinutes])).sorted()
    }

    private var endTimeText: String {
        date.addingTimeInterval(Double(durationMinutes) * 60).formatted(date: .omitted, time: .shortened)
    }

    /// The next :00 or :30 after now.
    static func nextHalfHour(after now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let minute = calendar.component(.minute, from: now)
        return start.addingTimeInterval(minute < 30 ? 30 * 60 : 60 * 60)
    }

    private static func durationLabel(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }
    
    var body: some View {
        NavigationView {
            Form {
                // Basic Info
                Section {
                    TextField("Class Title", text: $title)
                        .font(.headline)
                    
                    DatePicker("Date & Time", selection: $date)
                        .datePickerStyle(.compact)
                    
                    Picker("Duration", selection: $durationMinutes) {
                        ForEach(durationOptions, id: \.self) { minutes in
                            Text(Self.durationLabel(minutes)).tag(minutes)
                        }
                    }
                    .pickerStyle(.menu)

                    TextField("Meeting Link (optional)", text: $link)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    if linkLooksInvalid {
                        Text("This link doesn't look valid, so Join won't be able to open it.")
                            .foregroundStyle(.red)
                    } else {
                        Text("Ends at \(endTimeText)")
                    }
                }
                
                // Color Selection
                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(SubjectColor.all) { color in
                            Circle()
                                .fill(color.color)
                                .frame(width: 36, height: 36)
                                .overlay(
                                    Circle()
                                        .stroke(.white, lineWidth: selectedColor == color.hex ? 3 : 0)
                                        .padding(-2)
                                )
                                .overlay(
                                    Circle()
                                        .stroke(color.color, lineWidth: selectedColor == color.hex ? 2 : 0)
                                        .padding(-4)
                                )
                                .onTapGesture {
                                    selectedColor = color.hex
                                }
                        }
                    }
                    .padding(.vertical, 8)
                }
                
                // Recurring
                Section("Repeat") {
                    Picker("Recurring", selection: $recurring) {
                        ForEach(ClassSession.RecurringType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.menu)

                    if recurring != .none {
                        Text("Repeats from the date above. Each day can be marked complete on its own; deleting removes every repeat.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                
                // Notes
                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 80)
                }
                
                // Delete Button (for editing)
                if isEditing, let onDelete = onDelete, let session = session {
                    Section {
                        Button(role: .destructive, action: { showDeleteConfirm = true }) {
                            HStack {
                                Image(systemName: "trash")
                                Text("Delete Class")
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .alert("Delete Class?", isPresented: $showDeleteConfirm) {
                        Button("Cancel", role: .cancel) { }
                        Button("Delete", role: .destructive) {
                            onDelete(session.id)
                            dismiss()
                        }
                    } message: {
                        Text(session.recurring == .none
                             ? "This action cannot be undone."
                             : "This deletes every repeat of this class and cannot be undone.")
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Class" : "New Class")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveSession()
                    }
                    .disabled(trimmedTitle.isEmpty) // whitespace-only is not a title
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                loadSession()
            }
        }
    }
    
    private func loadSession() {
        if let session = session {
            title = session.title
            date = session.date
            link = session.link
            selectedColor = session.color
            notes = session.notes
            recurring = session.recurring
            durationMinutes = session.durationMinutes
        }
    }
    
    private func saveSession() {
        let newSession = ClassSession(
            id: session?.id ?? UUID(),
            title: trimmedTitle,
            date: date,
            // Store the openable form ("zoom.us/j/1" → "https://zoom.us/j/1").
            link: ClassSession.normalizedLink(trimmedLink)?.absoluteString ?? trimmedLink,
            color: selectedColor,
            notes: notes,
            isCompleted: session?.isCompleted ?? false,
            recurring: recurring,
            snoozedUntil: session?.snoozedUntil,
            durationMinutes: durationMinutes,
            completedOccurrences: session?.completedOccurrences ?? []
        )
        onSave(newSession)
        dismiss()
    }
}

// MARK: - Preview
#Preview {
    ClassFormSheet(
        session: nil,
        onSave: { _ in },
        onDelete: nil
    )
}
