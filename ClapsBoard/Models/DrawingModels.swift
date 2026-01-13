//
//  DrawingModels.swift
//  ClapsBoard
//
//  Core data models for drawing elements
//

import SwiftUI

// MARK: - Tool Types
/// Drawing tool types with accessibility support (HIG: Accessibility)
enum ToolType: String, CaseIterable, Codable {
    case pan = "Pan"
    case select = "Select"
    case pen = "Pen"
    case marker = "Highlighter"
    case eraser = "Eraser"
    case text = "Text"
    case rectangle = "Box"
    case circle = "Circle"
    case line = "Line"
    case sticker = "Sticker"
    case image = "Image"
    
    var iconName: String {
        switch self {
        case .pan: return "hand.raised"
        case .select: return "hand.point.up.left"
        case .pen: return "pencil"
        case .marker: return "highlighter"
        case .eraser: return "eraser"
        case .text: return "textformat"
        case .rectangle: return "rectangle"
        case .circle: return "circle"
        case .line: return "line.diagonal"
        case .sticker: return "star"
        case .image: return "photo"
        }
    }
    
    /// HIG: Accessibility labels for VoiceOver users
    var accessibilityLabel: String {
        switch self {
        case .pan: return "Pan tool. Move the canvas around."
        case .select: return "Selection tool. Tap to select and move elements."
        case .pen: return "Pen tool. Draw with a fine line."
        case .marker: return "Highlighter tool. Draw with a transparent marker."
        case .eraser: return "Eraser tool. Remove drawn elements."
        case .text: return "Text tool. Add text annotations."
        case .rectangle: return "Rectangle tool. Draw rectangular shapes."
        case .circle: return "Circle tool. Draw oval shapes."
        case .line: return "Line tool. Draw straight lines."
        case .sticker: return "Sticker tool. Add emoji stickers."
        case .image: return "Image tool. Insert photos."
        }
    }
}

enum TextAlignment: String, CaseIterable, Codable {
    case left, center, right
    
    var swiftUIAlignment: SwiftUI.TextAlignment {
        switch self {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }
}

// MARK: - Drawing Element
struct DrawingElement: Identifiable, Codable {
    let id: UUID
    var type: ToolType
    var points: [CGPoint]
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var text: String?
    var mediaId: String? // Pointer to file in StorageService
    var color: CodableColor
    var strokeWidth: CGFloat
    var opacity: CGFloat
    var rotation: CGFloat
    var isDeleted: Bool
    var textAlign: TextAlignment
    
    init(
        id: UUID = UUID(),
        type: ToolType,
        points: [CGPoint] = [],
        x: CGFloat = 0,
        y: CGFloat = 0,
        width: CGFloat = 0,
        height: CGFloat = 0,
        text: String? = nil,
        mediaId: String? = nil,
        color: Color = Color(hex: "1e293b"),
        strokeWidth: CGFloat = 3,
        opacity: CGFloat = 1,
        rotation: CGFloat = 0,
        isDeleted: Bool = false,
        textAlign: TextAlignment = .left
    ) {
        self.id = id
        self.type = type
        self.points = points
        
        // HIG: Automatically calculate bounding box for path-based tools
        if (type == .pen || type == .marker || type == .line) && !points.isEmpty {
            let minX = points.map { $0.x }.min() ?? 0
            let minY = points.map { $0.y }.min() ?? 0
            let maxX = points.map { $0.x }.max() ?? 0
            let maxY = points.map { $0.y }.max() ?? 0
            
            self.x = minX
            self.y = minY
            self.width = maxX - minX
            self.height = maxY - minY
        } else {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
        
        self.text = text
        self.mediaId = mediaId
        self.color = CodableColor(color)
        self.strokeWidth = strokeWidth
        self.opacity = opacity
        self.rotation = rotation
        self.isDeleted = isDeleted
        self.textAlign = textAlign
    }
}

// MARK: - Codable Color
struct CodableColor: Codable {
    let red: Double
    let green: Double
    let blue: Double
    let opacity: Double
    
    init(_ color: Color) {
        let uiColor = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.red = Double(r)
        self.green = Double(g)
        self.blue = Double(b)
        self.opacity = Double(a)
    }
    
    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: opacity)
    }
}

// MARK: - Constants
struct DrawingConstants {
    static let defaultColor = Color(hex: "1e293b")
    static let defaultStrokeWidth: CGFloat = 3
    static let eraserSize: CGFloat = 20
    
    static let colors: [Color] = [
        Color(hex: "1e293b"), // Black/Slate
        Color(hex: "ef4444"), // Red
        Color(hex: "3b82f6"), // Blue
        Color(hex: "22c55e"), // Green
        Color(hex: "eab308"), // Yellow
        Color(hex: "a855f7"), // Purple
        Color(hex: "f97316"), // Orange
        Color(hex: "ec4899"), // Pink
        .white
    ]
    
    static let stickers = [
        "⭐", "🌟", "🎉", "💯", "✅", "❌", "❤️", "👍", "👎",
        "😊", "🤔", "💡", "🔥", "🚀", "🌈", "🍎", "🐶", "🐱",
        "🎓", "📚", "✏️", "🏆", "🥇", "🌍", "⏰", "⚡", "👀"
    ]
}

// MARK: - Color Extensions
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
    
    var hexString: String {
        let uiColor = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X",
                      Int(r * 255),
                      Int(g * 255),
                      Int(b * 255))
    }
}
