//
//  DrawingModels.swift
//  ClapsBoard
//
//  Core data models for drawing elements
//

import SwiftUI

enum AppTheme {
    /// Shared brand blue (same as Android). White text on it is 5.2:1 and it
    /// is 5.2:1 as text on white, so both pass WCAG AA.
    static let accent = Color(hex: "3566D6")
    static let accentSoft = Color(hex: "3566D6").opacity(0.12)
    static let canvasBase = Color(hex: "FBFAF7")
    static let canvasWarmth = Color(hex: "F1EEE7")
}

enum GridStyle: String, CaseIterable, Codable {
    case none
    case dots
    case lines
    case graph
    case isometric

    var title: String {
        switch self {
        case .none: return "Off"
        case .dots: return "Dots"
        case .lines: return "Lines"
        case .graph: return "Graph"
        case .isometric: return "Isometric"
        }
    }

    var iconName: String {
        switch self {
        case .none: return "xmark"
        case .dots: return "circle.grid.2x2"
        case .lines: return "line.3.horizontal"
        case .graph: return "grid"
        case .isometric: return "cube"
        }
    }

    var isVisible: Bool { self != .none }

    /// A value written by a newer app version must not make the whole
    /// workspace file unreadable; fall back to no grid.
    init(from decoder: Decoder) throws {
        self = GridStyle(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .none
    }
}

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

    /// User-friendly display name for UI
    var displayName: String {
        switch self {
        case .pan: return "Pan"
        case .select: return "Select"
        case .pen: return "Pen"
        case .marker: return "Marker"
        case .eraser: return "Eraser"
        case .text: return "Text"
        case .rectangle: return "Box"
        case .circle: return "Circle"
        case .line: return "Line"
        case .sticker: return "Sticker"
        case .image: return "Image"
        }
    }

    var supportsProperties: Bool {
        switch self {
        case .pan, .select, .image:
            return false
        case .pen, .marker, .eraser, .text, .rectangle, .circle, .line, .sticker:
            return true
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

    /// Unknown values (newer app version) fall back instead of failing the load.
    init(from decoder: Decoder) throws {
        self = TextAlignment(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .left
    }
    
    var swiftUIAlignment: SwiftUI.TextAlignment {
        switch self {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }
}

enum AnswerLayer: String, CaseIterable, Codable, Hashable {
    case base, hint, solution

    /// Unknown values (newer app version) fall back instead of failing the load.
    init(from decoder: Decoder) throws {
        self = AnswerLayer(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .base
    }

    var title: String {
        switch self {
        case .base: return "Board"
        case .hint: return "Hints"
        case .solution: return "Solutions"
        }
    }

    var iconName: String {
        switch self {
        case .base: return "square.on.square"
        case .hint: return "lightbulb"
        case .solution: return "checkmark.seal"
        }
    }
}

// MARK: - Drawing Element
struct DrawingElement: Identifiable, Codable, Equatable {
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
    var layer: AnswerLayer?
    
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
        textAlign: TextAlignment = .left,
        layer: AnswerLayer = .base
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
        self.layer = layer
    }
}

// MARK: - Element Geometry
/// One definition of "where is this element", shared by the canvas (hit
/// testing, eraser, selection) and the exporter so they cannot drift apart.
extension DrawingElement {
    var textFontSize: CGFloat { max(strokeWidth * 8, 1) }
    var stickerFontSize: CGFloat { max(strokeWidth * 10, 1) }

    var textLines: [String] { (text ?? "").components(separatedBy: "\n") }

    /// Text is stored with zero width/height, so its real rectangle has to be
    /// measured. `x` is the alignment anchor (left edge, centre or right edge,
    /// like the Android/web canvas) and `y` is the top.
    var measuredTextBounds: CGRect {
        let font = UIFont.systemFont(ofSize: textFontSize, weight: .medium)
        let lines = textLines
        let lineWidth = lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let size = CGSize(width: max(ceil(lineWidth), 1), height: ceil(font.lineHeight * CGFloat(max(lines.count, 1))))
        let originX: CGFloat
        switch textAlign {
        case .left: originX = x
        case .center: originX = x - size.width / 2
        case .right: originX = x - size.width
        }
        return CGRect(origin: CGPoint(x: originX, y: y), size: size)
    }

    /// Stickers are drawn centred on x/y.
    var measuredStickerBounds: CGRect {
        let font = UIFont.systemFont(ofSize: stickerFontSize)
        let size = ((text ?? "") as NSString).size(withAttributes: [.font: font])
        let width = max(ceil(size.width), 1), height = max(ceil(size.height), 1)
        return CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
    }

    /// The rectangle the element covers when drawn, including stroke thickness.
    var contentBounds: CGRect {
        switch type {
        case .pen, .marker, .line:
            guard let first = points.first else { return CGRect(x: x, y: y, width: width, height: height) }
            var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
            for point in points.dropFirst() {
                minX = min(minX, point.x); minY = min(minY, point.y)
                maxX = max(maxX, point.x); maxY = max(maxY, point.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                .insetBy(dx: -strokeWidth / 2, dy: -strokeWidth / 2)
        case .text:
            return measuredTextBounds
        case .sticker:
            return measuredStickerBounds
        case .rectangle, .circle:
            return CGRect(x: x, y: y, width: width, height: height).standardized
                .insetBy(dx: -strokeWidth / 2, dy: -strokeWidth / 2)
        default:
            return CGRect(x: x, y: y, width: width, height: height).standardized
        }
    }

    /// The point `rotation` turns the element about: the centre of what is
    /// drawn. One definition for the canvas, hit testing and the exporter.
    /// (For shapes, images and strokes this is the centre of the stored box;
    /// text and stickers store an anchor point instead, so they are measured.)
    var rotationPivot: CGPoint {
        let bounds = contentBounds
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// `point` as the element sees it before its rotation is applied, so the
    /// unrotated hit tests can be used on a rotated element.
    func unrotated(_ point: CGPoint) -> CGPoint {
        guard rotation != 0 else { return point }
        let pivot = rotationPivot
        let dx = point.x - pivot.x, dy = point.y - pivot.y
        let c = cos(-rotation), s = sin(-rotation)
        return CGPoint(x: pivot.x + dx * c - dy * s, y: pivot.y + dx * s + dy * c)
    }

    /// Distance from `point` to the drawn outline of a rectangle or ellipse
    /// (0 on the line, growing both inside and outside the shape).
    func distanceToShapeOutline(from point: CGPoint) -> CGFloat {
        let rect = CGRect(x: x, y: y, width: width, height: height).standardized
        if type == .circle, rect.width > 1, rect.height > 1 {
            // Radial approximation: compare with the point where the ray from
            // the centre crosses the ellipse. Exact for circles, close enough
            // for ovals at finger precision.
            let dx = point.x - rect.midX, dy = point.y - rect.midY
            let a = rect.width / 2, b = rect.height / 2
            let normalised = sqrt((dx * dx) / (a * a) + (dy * dy) / (b * b))
            guard normalised > 0.0001 else { return min(a, b) }
            return abs(hypot(dx, dy) * (1 - 1 / normalised))
        }
        let outsideX = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let outsideY = max(rect.minY - point.y, 0, point.y - rect.maxY)
        if outsideX > 0 || outsideY > 0 { return hypot(outsideX, outsideY) }
        return min(point.x - rect.minX, rect.maxX - point.x, point.y - rect.minY, rect.maxY - point.y)
    }
}

// MARK: - Codable Color
struct CodableColor: Codable, Equatable {
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
        AppTheme.accent, // Periwinkle
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

// MARK: - Offline Lesson Workspace
struct StudentFolder: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var colorHex: String
    let createdAt: Date
    var notes: String?
    var documentNames: [String]?
    var homework: [HomeworkItem]?
    var lessonHistory: [LessonHistoryItem]?
}

struct HomeworkItem: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var isComplete: Bool
    let createdAt: Date
}

struct LessonHistoryItem: Identifiable, Codable, Equatable {
    let id: UUID
    var lessonId: UUID
    var lessonTitle: String
    let startedAt: Date
    var finishedAt: Date?
    var durationSeconds: Int?
}

struct LessonPage: Identifiable, Codable {
    let id: UUID
    var title: String
    var elements: [DrawingElement]
    var gridStyle: GridStyle
    let createdAt: Date
    var updatedAt: Date
}

struct TutorLesson: Identifiable, Codable {
    let id: UUID
    var studentId: UUID
    var title: String
    var pages: [LessonPage]
    var activePageId: UUID
    let createdAt: Date
    var updatedAt: Date
}

private struct LessonWorkspaceData: Codable {
    var version: Int
    var students: [StudentFolder]
    var lessons: [TutorLesson]
    var activeLessonId: UUID
}

@MainActor
final class LessonStore: ObservableObject {
    @Published private(set) var students: [StudentFolder] = []
    @Published private(set) var lessons: [TutorLesson] = []
    @Published private(set) var activeLessonId: UUID

    private let fileManager = FileManager.default
    private let workspaceURL: URL
    private let recoveryURL: URL
    /// False when an unreadable recovery file could not be copied aside.
    private var canWriteRecovery = true
    /// Encoding and writing run here, debounced, instead of on the main thread
    /// for every stroke, eraser hit and drag frame. Serial, so writes land in order.
    private let saveQueue = DispatchQueue(label: "com.clapsboard.lessonStore.save", qos: .utility)
    private var pendingSave: DispatchWorkItem?
    private static let saveDelay: TimeInterval = 0.4
    private var backgroundObservers: [NSObjectProtocol] = []

    var activeLesson: TutorLesson {
        lessons.first(where: { $0.id == activeLessonId }) ?? lessons[0]
    }

    var activePage: LessonPage {
        let lesson = activeLesson
        return lesson.pages.first(where: { $0.id == lesson.activePageId }) ?? lesson.pages[0]
    }

    init() {
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ClapsBoard", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        workspaceURL = directory.appendingPathComponent("lesson-workspace-v1.json")
        recoveryURL = directory.appendingPathComponent("lesson-workspace-v1-recovery.json")

        // A file that exists but cannot be used (corrupt, or written by a
        // newer version) is moved aside with a timestamp before anything is
        // saved again, so the next save can never destroy the only copy.
        var loaded = Self.loadData(from: workspaceURL)
        if loaded == nil {
            Self.setAsideUnreadableFile(at: workspaceURL, fileManager: fileManager)
            loaded = Self.loadData(from: recoveryURL)
            if loaded == nil, !Self.setAsideUnreadableFile(at: recoveryURL, fileManager: fileManager) {
                // Couldn't keep a copy: leave the recovery file alone this
                // session rather than replace it with a blank workspace.
                canWriteRecovery = false
            }
        }

        if let data = loaded {
            students = data.students
            lessons = data.lessons
            activeLessonId = data.lessons.contains(where: { $0.id == data.activeLessonId }) ? data.activeLessonId : data.lessons[0].id
        } else {
            let student = StudentFolder(id: UUID(), name: "General", colorHex: "3566D6", createdAt: Date(), notes: "", documentNames: [], homework: [], lessonHistory: [])
            let legacy = StorageService.shared.loadElements()
            let page = LessonPage(id: UUID(), title: "Page 1", elements: legacy, gridStyle: .none, createdAt: Date(), updatedAt: Date())
            let lesson = TutorLesson(id: UUID(), studentId: student.id, title: "My Board", pages: [page], activePageId: page.id, createdAt: Date(), updatedAt: Date())
            students = [student]
            lessons = [lesson]
            activeLessonId = lesson.id
            save()
        }

        // Don't leave the last edits waiting on the debounce if iOS suspends
        // or kills the app.
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
            backgroundObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushPendingSave() }
            })
        }
    }

    deinit {
        backgroundObservers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Returns the workspace only if it is fully usable.
    private static func loadData(from url: URL) -> LessonWorkspaceData? {
        guard let data = try? Data(contentsOf: url),
              let workspace = try? JSONDecoder().decode(LessonWorkspaceData.self, from: data),
              workspace.version == 1, !workspace.students.isEmpty, !workspace.lessons.isEmpty,
              workspace.lessons.allSatisfy({ !$0.pages.isEmpty }) else { return nil }
        return workspace
    }

    /// Moves an existing, unusable file to "<name>-unreadable-<timestamp>.json"
    /// next to it. Returns true when there is nothing left at `url` to lose.
    @discardableResult
    private static func setAsideUnreadableFile(at url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return true }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = url.deletingPathExtension().lastPathComponent + "-unreadable-" + formatter.string(from: Date()) + ".json"
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try fileManager.moveItem(at: url, to: destination)
            print("⚠️ Unreadable workspace file kept as \(name)")
            return true
        } catch {
            if (try? fileManager.copyItem(at: url, to: destination)) != nil { return true }
            print("❌ Could not set aside unreadable workspace file: \(error.localizedDescription)")
            return false
        }
    }

    private var snapshot: LessonWorkspaceData {
        LessonWorkspaceData(version: 1, students: students, lessons: lessons, activeLessonId: activeLessonId)
    }

    private nonisolated static func write(_ snapshot: LessonWorkspaceData, to workspaceURL: URL, recoveryURL: URL?) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        if let recoveryURL {
            try? data.write(to: recoveryURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        try? data.write(to: workspaceURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func save() {
        pendingSave?.cancel()
        // Capture the snapshot now (copy-on-write, cheap); encode it later.
        let snapshot = snapshot, workspaceURL = workspaceURL, recoveryURL = canWriteRecovery ? recoveryURL : nil
        let item = DispatchWorkItem { Self.write(snapshot, to: workspaceURL, recoveryURL: recoveryURL) }
        pendingSave = item
        saveQueue.asyncAfter(deadline: .now() + Self.saveDelay, execute: item)
    }

    /// Writes any debounced save immediately and waits for it to finish.
    func flushPendingSave() {
        guard let pending = pendingSave else { return }
        pendingSave = nil
        pending.cancel()
        let snapshot = snapshot, workspaceURL = workspaceURL, recoveryURL = canWriteRecovery ? recoveryURL : nil
        saveQueue.sync { Self.write(snapshot, to: workspaceURL, recoveryURL: recoveryURL) }
    }

    func addStudent(name: String) -> StudentFolder {
        let student = StudentFolder(id: UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), colorHex: "3566D6", createdAt: Date(), notes: "", documentNames: [], homework: [], lessonHistory: [])
        students.append(student); save(); return student
    }

    func updateStudent(_ student: StudentFolder) {
        guard let index = students.firstIndex(where: { $0.id == student.id }) else { return }
        students[index] = student
        save()
    }

    func addLesson(studentId: UUID, title: String) -> TutorLesson {
        let page = LessonPage(id: UUID(), title: "Page 1", elements: [], gridStyle: .none, createdAt: Date(), updatedAt: Date())
        let lesson = TutorLesson(id: UUID(), studentId: studentId, title: title.trimmingCharacters(in: .whitespacesAndNewlines), pages: [page], activePageId: page.id, createdAt: Date(), updatedAt: Date())
        lessons.append(lesson); activeLessonId = lesson.id; save(); return lesson
    }

    func openLesson(_ id: UUID) {
        guard lessons.contains(where: { $0.id == id }) else { return }
        activeLessonId = id; save()
    }

    func deleteLesson(_ id: UUID) {
        guard lessons.count > 1 else { return }
        lessons.removeAll { $0.id == id }
        if activeLessonId == id { activeLessonId = lessons[0].id }
        save()
    }

    func openPage(_ id: UUID) {
        guard let lessonIndex = lessons.firstIndex(where: { $0.id == activeLessonId }), lessons[lessonIndex].pages.contains(where: { $0.id == id }) else { return }
        lessons[lessonIndex].activePageId = id; save()
    }

    @discardableResult func addPage() -> LessonPage {
        let lessonIndex = lessons.firstIndex(where: { $0.id == activeLessonId })!
        let page = LessonPage(id: UUID(), title: "Page \(lessons[lessonIndex].pages.count + 1)", elements: [], gridStyle: lessons[lessonIndex].pages.last?.gridStyle ?? .none, createdAt: Date(), updatedAt: Date())
        lessons[lessonIndex].pages.append(page); lessons[lessonIndex].activePageId = page.id; lessons[lessonIndex].updatedAt = Date(); save(); return page
    }

    func deleteActivePage() {
        guard let lessonIndex = lessons.firstIndex(where: { $0.id == activeLessonId }), lessons[lessonIndex].pages.count > 1 else { return }
        let pageId = lessons[lessonIndex].activePageId
        let oldIndex = lessons[lessonIndex].pages.firstIndex(where: { $0.id == pageId }) ?? 0
        lessons[lessonIndex].pages.removeAll { $0.id == pageId }
        lessons[lessonIndex].activePageId = lessons[lessonIndex].pages[min(oldIndex, lessons[lessonIndex].pages.count - 1)].id
        lessons[lessonIndex].updatedAt = Date(); save()
    }

    /// Every media file id still used by any page of any lesson.
    var referencedMediaIds: Set<String> {
        var ids = Set<String>()
        for lesson in lessons {
            for page in lesson.pages {
                for element in page.elements {
                    if let id = element.mediaId { ids.insert(id) }
                }
            }
        }
        return ids
    }

    func updateActivePage(elements: [DrawingElement], gridStyle: GridStyle) {
        guard let lessonIndex = lessons.firstIndex(where: { $0.id == activeLessonId }),
              let pageIndex = lessons[lessonIndex].pages.firstIndex(where: { $0.id == lessons[lessonIndex].activePageId }) else { return }
        lessons[lessonIndex].pages[pageIndex].elements = elements
        lessons[lessonIndex].pages[pageIndex].gridStyle = gridStyle
        lessons[lessonIndex].pages[pageIndex].updatedAt = Date()
        lessons[lessonIndex].updatedAt = Date()
        save()
    }
}
