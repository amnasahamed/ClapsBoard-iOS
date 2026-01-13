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
    @State private var date: Date = Date()
    @State private var link: String = ""
    @State private var selectedColor: String = "#3b82f6"
    @State private var notes: String = ""
    @State private var recurring: ClassSession.RecurringType = .none
    @State private var showDeleteConfirm = false
    
    private var isEditing: Bool { session != nil }
    
    var body: some View {
        NavigationView {
            Form {
                // Basic Info
                Section {
                    TextField("Class Title", text: $title)
                        .font(.headline)
                    
                    DatePicker("Date & Time", selection: $date)
                        .datePickerStyle(.compact)
                    
                    TextField("Meeting Link (optional)", text: $link)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
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
                        Text("This action cannot be undone.")
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
                    .disabled(title.isEmpty)
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
        }
    }
    
    private func saveSession() {
        let newSession = ClassSession(
            id: session?.id ?? UUID(),
            title: title,
            date: date,
            link: link,
            color: selectedColor,
            notes: notes,
            isCompleted: session?.isCompleted ?? false,
            recurring: recurring,
            snoozedUntil: session?.snoozedUntil
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
