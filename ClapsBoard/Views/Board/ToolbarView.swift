//
//  ToolbarView.swift
//  ClapsBoard
//
//  Quiet bottom toolbar for canvas-first drawing
//

import SwiftUI
import UIKit

enum BoardControlOrientation {
    case horizontal
    case vertical
}

struct ToolbarView: View {
    @ObservedObject var viewModel: CanvasViewModel
    var orientation: BoardControlOrientation = .horizontal
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let feedback = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        Group {
            if orientation == .vertical {
                VStack(spacing: 6) {
                    toolbarItems
                }
            } else {
                // Pen, marker and eraser get one-tap buttons because tutors
                // switch between them constantly. On the narrowest phones the
                // marker falls back into the "+" menu so the bar still fits.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 2) { toolbarItems }
                    HStack(spacing: 2) { compactToolbarItems }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, orientation == .vertical ? 8 : 6)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .opacity(0.82)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.07), radius: 18, y: 8)
        .opacity(viewModel.isDrawing ? 0.34 : 1)
        .blur(radius: viewModel.isDrawing ? 0.7 : 0)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: viewModel.isDrawing)
    }

    private static let primaryTools: [ToolType] = [.pen, .marker, .eraser]
    private static let compactPrimaryTools: [ToolType] = [.pen, .eraser]

    private var toolbarItems: some View { items(primaryTools: Self.primaryTools) }
    private var compactToolbarItems: some View { items(primaryTools: Self.compactPrimaryTools) }

    @ViewBuilder
    private func items(primaryTools: [ToolType] = ToolbarView.primaryTools) -> some View {
        ToolbarIconButton(
            icon: "arrow.uturn.backward",
            isEnabled: viewModel.canUndo,
            action: performUndo
        )

        ToolbarIconButton(
            icon: "arrow.uturn.forward",
            isEnabled: viewModel.canRedo,
            action: performRedo
        )

        ToolbarIconButton(
            icon: "hand.raised",
            isSelected: viewModel.tool == .pan,
            action: { selectTool(.pan) }
        )

        ForEach(primaryTools, id: \.self) { tool in
            ToolbarIconButton(
                icon: tool.iconName,
                isSelected: viewModel.tool == tool,
                action: { selectTool(tool) }
            )
        }

        if viewModel.tool.supportsProperties {
            ToolbarIconButton(
                icon: "slider.horizontal.3",
                isSelected: viewModel.showProperties,
                action: toggleProperties
            )
        }

        ToolOverflowMenu(viewModel: viewModel, primaryTools: primaryTools, selectTool: selectTool)
    }

    private func selectTool(_ tool: ToolType) {
        feedback.impactOccurred()
        if viewModel.tool == tool {
            viewModel.showProperties = tool.supportsProperties ? !viewModel.showProperties : false
        } else {
            viewModel.tool = tool
            viewModel.showProperties = tool.supportsProperties
        }
    }

    private func toggleProperties() {
        guard viewModel.tool.supportsProperties else { return }
        feedback.impactOccurred()
        viewModel.showProperties.toggle()
    }

    private func performUndo() {
        guard viewModel.canUndo else { return }
        feedback.impactOccurred()
        viewModel.undo()
    }

    private func performRedo() {
        guard viewModel.canRedo else { return }
        feedback.impactOccurred()
        viewModel.redo()
    }
}

private struct ToolOverflowMenu: View {
    @ObservedObject var viewModel: CanvasViewModel
    let primaryTools: [ToolType]
    let selectTool: (ToolType) -> Void

    private static let allSecondaryTools: [ToolType] = [
        .select,
        .marker,
        .eraser,
        .text,
        .rectangle,
        .circle,
        .line,
        .sticker
    ]

    /// Whatever isn't already a button in the bar.
    private var secondaryTools: [ToolType] {
        Self.allSecondaryTools.filter { !primaryTools.contains($0) }
    }

    var body: some View {
        Menu {
            ForEach(secondaryTools, id: \.self) { tool in
                Button {
                    selectTool(tool)
                } label: {
                    Label(tool.displayName, systemImage: tool.iconName)
                }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(isSecondaryToolActive ? AppTheme.accentSoft : Color.primary.opacity(0.045))
                    .frame(width: 42, height: 42)

                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .accessibilityLabel("More tools")
        .accessibilityHint("Opens additional drawing tools")
    }

    private var isSecondaryToolActive: Bool {
        secondaryTools.contains(viewModel.tool)
    }
}

private struct ToolbarIconButton: View {
    let icon: String
    var isSelected: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isSelected ? AppTheme.accentSoft : Color.clear)
                    .frame(width: 42, height: 42)

                Image(systemName: icon)
                    .font(.system(size: 17, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? AppTheme.accent : (isEnabled ? Color.primary.opacity(0.82) : Color.secondary.opacity(0.7)))
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .scaleEffect(isPressed ? 0.94 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.28)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }

    private var accessibilityLabel: String {
        switch icon {
        case "arrow.uturn.backward": return "Undo"
        case "arrow.uturn.forward": return "Redo"
        case "hand.raised": return "Pan tool"
        case "pencil": return "Pencil tool"
        case "highlighter": return "Marker tool"
        case "eraser": return "Eraser tool"
        case "slider.horizontal.3": return "Tool adjustments"
        default: return icon
        }
    }

    private var accessibilityHint: String {
        switch icon {
        case "arrow.uturn.backward": return "Tap to undo last action"
        case "arrow.uturn.forward": return "Tap to redo last action"
        case "hand.raised": return "Tap to pan the canvas"
        case "pencil": return "Tap to draw with pencil"
        case "highlighter": return "Tap to highlight"
        case "eraser": return "Tap to erase"
        case "slider.horizontal.3": return "Shows or hides settings for the selected tool"
        default: return "Tap to use this control"
        }
    }
}

#Preview {
    VStack {
        Spacer()
        ToolbarView(viewModel: CanvasViewModel())
            .padding(.bottom, 24)
    }
    .background(AppTheme.canvasBase)
}
