//
//  ToolbarView.swift
//  ClapsBoard
//
//  Bottom toolbar with drawing tools and quick actions
//

import SwiftUI
import UniformTypeIdentifiers

/// Bottom toolbar with drawing tools (HIG: Gestures & Touch, Accessibility)
struct ToolbarView: View {
    @ObservedObject var viewModel: CanvasViewModel
    
    // HIG: Reduce Motion support
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    private let mainTools: [ToolType] = [.pan, .select, .pen, .marker, .eraser, .rectangle, .circle, .line, .sticker]
    
    var body: some View {
        VStack(spacing: 8) {
            // Undo/Redo Bar
            HStack(spacing: 12) {
                Button(action: viewModel.undo) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(viewModel.canUndo ? .primary : .tertiary)
                }
                .disabled(!viewModel.canUndo)
                
                Button(action: viewModel.redo) {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(viewModel.canRedo ? .primary : .tertiary)
                }
                .disabled(!viewModel.canRedo)
                
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            
            // Main Tools
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { // Increased spacing
                    ForEach(mainTools, id: \.self) { tool in
                        ToolButton(
                            tool: tool,
                            isSelected: viewModel.tool == tool,
                            reduceMotion: reduceMotion,
                            action: {
                                // HIG: Respect Reduce Motion accessibility setting
                                if reduceMotion {
                                    if viewModel.tool == tool {
                                        viewModel.showProperties.toggle()
                                    } else {
                                        viewModel.tool = tool
                                        viewModel.showProperties = true
                                    }
                                } else {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        if viewModel.tool == tool {
                                            viewModel.showProperties.toggle()
                                        } else {
                                            viewModel.tool = tool
                                            viewModel.showProperties = true
                                        }
                                    }
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Tool Button
/// Individual tool button with accessibility support (HIG: Accessibility)
struct ToolButton: View {
    let tool: ToolType
    let isSelected: Bool
    let reduceMotion: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: tool.iconName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isSelected ? .white : .primary.opacity(0.7))
                    .frame(width: 44, height: 36)
                
                Text(tool.rawValue)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isSelected ? .white : .primary.opacity(0.7))
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                isSelected ? Color.blue : Color.gray.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .buttonStyle(.plain)
        // HIG: Accessibility labels for VoiceOver support
        .accessibilityLabel(tool.accessibilityLabel)
        .accessibilityHint(isSelected ? "Selected. Double tap to toggle properties panel." : "Double tap to select this tool.")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Preview
#Preview {
    VStack {
        Spacer()
        ToolbarView(viewModel: CanvasViewModel())
    }
    .background(Color.gray.opacity(0.3))
}
