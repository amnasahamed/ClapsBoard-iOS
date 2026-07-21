//
//  UndoRedoToast.swift
//  ClapsBoard
//
//  Toast notification view for undo/redo feedback
//

import SwiftUI

/// Toast notification for undo/redo visual feedback
struct UndoRedoToast: View {
    let message: String
    let systemImage: String

    @State private var isVisible = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
            Text(message)
                .font(.subheadline)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible ? 0 : 20)
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isVisible = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeOut(duration: 0.2)) {
                    isVisible = false
                }
            }
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        UndoRedoToast(message: "Drawing undone", systemImage: "arrow.uturn.backward")
        UndoRedoToast(message: "Redo restored", systemImage: "arrow.uturn.forward")
    }
    .padding()
    .background(Color.gray.opacity(0.3))
}