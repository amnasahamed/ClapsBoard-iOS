//
//  PropertiesPanel.swift
//  ClapsBoard
//
//  Properties panel for tool customization (color, stroke width, etc.)
//

import SwiftUI

struct PropertiesPanel: View {
    @ObservedObject var viewModel: CanvasViewModel
    
    var body: some View {
        VStack(spacing: 16) {
            switch viewModel.tool {
            case .pen, .marker, .line, .rectangle, .circle:
                // Color Picker
                ColorPicker(selectedColor: $viewModel.color)
                
                // Stroke Width Slider
                StrokeWidthPicker(strokeWidth: $viewModel.strokeWidth)
                
            case .eraser:
                // Eraser Size Slider
                EraserSizePicker(eraserSize: $viewModel.eraserSize)
                
            case .text:
                // Color Picker
                ColorPicker(selectedColor: $viewModel.color)
                
                // Text Size Slider
                TextSizePicker(size: $viewModel.strokeWidth)
                
                // Text Alignment
                TextAlignmentPicker(alignment: $viewModel.textAlign)
                
            case .sticker:
                // Sticker Picker
                StickerPicker(selectedSticker: $viewModel.currentSticker)
                
            default:
                EmptyView()
            }
        }
        .padding(16)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 24)
        )
        .shadow(color: .black.opacity(0.1), radius: 20, y: 5)
        .padding(.horizontal, 16)
    }
}

// MARK: - Color Picker
struct ColorPicker: View {
    @Binding var selectedColor: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Color")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            
            HStack(spacing: 8) {
                ForEach(DrawingConstants.colors, id: \.self) { color in
                    Button(action: { selectedColor = color }) {
                        Circle()
                            .fill(color)
                            .frame(width: 32, height: 32)
                            .overlay(
                                Circle()
                                    .stroke(color == .white ? .gray : .clear, lineWidth: 1)
                            )
                            .overlay(
                                Circle()
                                    .stroke(.blue, lineWidth: selectedColor == color ? 3 : 0)
                                    .padding(-2)
                            )
                    }
                }
            }
        }
    }
}

// MARK: - Stroke Width Picker
struct StrokeWidthPicker: View {
    @Binding var strokeWidth: CGFloat
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Stroke")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Text("\(Int(strokeWidth))px")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            
            Slider(value: $strokeWidth, in: 1...20, step: 1)
                .tint(.blue)
        }
    }
}

// MARK: - Eraser Size Picker
struct EraserSizePicker: View {
    @Binding var eraserSize: CGFloat
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Eraser Size")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Text("\(Int(eraserSize))px")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            
            Slider(value: $eraserSize, in: 10...50, step: 5)
                .tint(.blue)
            
            // Visual Preview
            HStack {
                Spacer()
                Circle()
                    .stroke(Color.gray, lineWidth: 2)
                    .frame(width: eraserSize, height: eraserSize)
                    .animation(.easeInOut, value: eraserSize)
                Spacer()
            }
            .padding(.top, 8)
        }
    }
}

// MARK: - Text Size Picker
struct TextSizePicker: View {
    @Binding var size: CGFloat
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Text Size")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Text("\(Int(size * 8))pt")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            
            Slider(value: $size, in: 1...6, step: 0.5)
                .tint(.blue)
        }
    }
}

// MARK: - Text Alignment Picker
struct TextAlignmentPicker: View {
    @Binding var alignment: TextAlignment
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Alignment")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            
            HStack(spacing: 8) {
                ForEach(TextAlignment.allCases, id: \.self) { align in
                    Button(action: { alignment = align }) {
                        Image(systemName: iconName(for: align))
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(alignment == align ? .white : .secondary)
                            .frame(width: 36, height: 36)
                            .background(
                                alignment == align ? Color.blue : Color.gray.opacity(0.2),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                    }
                }
            }
        }
    }
    
    private func iconName(for alignment: TextAlignment) -> String {
        switch alignment {
        case .left: return "text.alignleft"
        case .center: return "text.aligncenter"
        case .right: return "text.alignright"
        }
    }
}

// MARK: - Sticker Picker
struct StickerPicker: View {
    @Binding var selectedSticker: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stickers")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 9), spacing: 4) {
                ForEach(DrawingConstants.stickers, id: \.self) { sticker in
                    Button(action: { selectedSticker = sticker }) {
                        Text(sticker)
                            .font(.system(size: 24))
                            .frame(width: 32, height: 32)
                            .background(
                                selectedSticker == sticker ? Color.blue.opacity(0.2) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                }
            }
        }
    }
}

// MARK: - Preview
#Preview {
    VStack {
        Spacer()
        PropertiesPanel(viewModel: CanvasViewModel())
        Spacer()
    }
    .background(Color.gray.opacity(0.3))
}
