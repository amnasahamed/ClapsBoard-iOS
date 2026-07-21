//
//  UndoRedoManager.swift
//  ClapsBoard
//
//  Centralized undo/redo state management with action descriptions
//

import Combine
import Foundation

/// Manages undo/redo state and provides action descriptions for feedback
class UndoRedoManager: ObservableObject {
    /// Whether undo is available
    @Published var canUndo: Bool = false

    /// Whether redo is available
    @Published var canRedo: Bool = false

    /// Description of the action that will be undone
    @Published var undoDescription: String?

    /// Description of the action that will be redone
    @Published var redoDescription: String?

    private var undoStack: [String] = []
    private var redoStack: [String] = []
    private let maxHistory = 50

    /// Pushes a new action onto the undo stack
    /// - Parameter description: Human-readable description of the action
    func pushAction(description: String) {
        undoStack.append(description)
        if undoStack.count > maxHistory {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
        updateState()
    }

    /// Performs an undo operation
    /// - Returns: The description of the undone action, or nil if nothing to undo
    func undo() -> String? {
        guard let action = undoStack.popLast() else { return nil }
        redoStack.append(action)
        updateState()
        return action
    }

    /// Performs a redo operation
    /// - Returns: The description of the redone action, or nil if nothing to redo
    func redo() -> String? {
        guard let action = redoStack.popLast() else { return nil }
        undoStack.append(action)
        updateState()
        return action
    }

    /// Clears all undo/redo history
    func clearHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        updateState()
    }

    private func updateState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        undoDescription = undoStack.last
        redoDescription = redoStack.last
    }
}
