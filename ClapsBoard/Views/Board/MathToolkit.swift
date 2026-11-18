//
//  MathToolkit.swift
//  ClapsBoard
//
//  Builds accurate, labelled math diagrams from values the tutor types in.
//  Each builder returns a flat list of drawing primitives that is drawn both
//  in the live preview and onto the board image. The Android app has a
//  matching builder (utils/mathDiagrams.ts) — keep them in step.
//

import SwiftUI
import UIKit

// MARK: - Tools and specs

enum MathToolID: String, CaseIterable, Identifiable, Codable {
    case numberLine, graph, fractions, angle, protractor, ruler, shape
    var id: String { rawValue }

    var label: String {
        switch self {
        case .numberLine: return "Number line"
        case .graph: return "Graph"
        case .fractions: return "Fractions"
        case .angle: return "Angle"
        case .protractor: return "Protractor"
        case .ruler: return "Ruler"
        case .shape: return "Shape"
        }
    }

    var hint: String {
        switch self {
        case .numberLine: return "Any range and step, with marked points"
        case .graph: return "Plot functions like y = x^2 - 3 and points"
        case .fractions: return "Shaded bars to compare fractions"
        case .angle: return "An exact angle, labelled by type"
        case .protractor: return "Degree scale with a marked angle"
        case .ruler: return "Centimetre or inch scale"
        case .shape: return "Rectangles and right triangles with answers"
        }
    }
}

struct MathSpecs: Codable, Equatable {
    struct NumberLine: Codable, Equatable { var from = "-5", to = "5", step = "1", marks = "" }
    struct Graph: Codable, Equatable { var xMin = "-5", xMax = "5", yMin = "-5", yMax = "5", functions = "y = 2x + 1", points = "" }
    struct Fractions: Codable, Equatable { var fractions = "1/2, 3/4, 2/3" }
    struct Angle: Codable, Equatable { var degrees = "65"; var hideMeasure = false }
    struct Protractor: Codable, Equatable { var degrees = "40" }
    struct Ruler: Codable, Equatable { var length = "10"; var unit = "cm" }
    struct Shape: Codable, Equatable { var kind = "rightTriangle", a = "3", b = "4", unit = "cm"; var hideAnswer = false }

    var numberLine = NumberLine()
    var graph = Graph()
    var fractions = Fractions()
    var angle = Angle()
    var protractor = Protractor()
    var ruler = Ruler()
    var shape = Shape()
}

// MARK: - Primitives

enum MathPrimitive {
    case line(CGPoint, CGPoint, color: Color, width: CGFloat)
    case poly([CGPoint], color: Color, width: CGFloat, fill: Color? = nil, closed: Bool = false, clip: CGRect? = nil)
    case circle(CGPoint, r: CGFloat, fill: Color)
    case rect(CGRect, fill: Color, stroke: Color?, width: CGFloat, radius: CGFloat = 0)
    case text(String, CGPoint, size: CGFloat, color: Color, bold: Bool = false, anchor: TextAnchor = .start)

    enum TextAnchor { case start, middle, end }
}

struct MathDiagram {
    var size: CGSize
    var items: [MathPrimitive]
    var title: String
}

fileprivate enum MathPalette {
    static let ink = Color(hex: "1e293b")
    static let muted = Color(hex: "94a3b8")
    static let grid = Color(hex: "e2e8f0")
    static let label = Color(hex: "475569")
    static let secondary = Color(hex: "64748b")
    static let accent = AppTheme.accent
    static let accentFill = AppTheme.accent.opacity(0.22)
    static let accentTint = AppTheme.accent.opacity(0.08)
    static let mark = Color(hex: "dc2626")
    static let curves: [Color] = [AppTheme.accent, Color(hex: "dc2626"), Color(hex: "059669")]
}

struct MathInputError: Error { let message: String }

// MARK: - Helpers

private func number(_ raw: String, _ name: String) throws -> Double {
    // "," is the decimal separator on many keyboards (2,5 means 2.5).
    let text = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: ",", with: ".")
    guard !text.isEmpty, let value = Double(text), value.isFinite else { throw MathInputError(message: "\(name) needs to be a number.") }
    return value
}

/// 3.50 → "3.5", -2 → "−2" (typographic minus).
func mathFormat(_ value: Double) -> String {
    var rounded = (value * 1e4).rounded() / 1e4
    if rounded == 0 { rounded = 0 }
    let text = rounded == rounded.rounded() && abs(rounded) < 1e15 ? String(Int(rounded)) : String(rounded)
    return text.hasPrefix("-") ? "−" + text.dropFirst() : text
}

private func niceStep(_ rough: Double) -> Double {
    let power = pow(10, floor(log10(rough)))
    let unit = rough / power
    return (unit <= 1 ? 1 : unit <= 2 ? 2 : unit <= 5 ? 5 : 10) * power
}

/// Angles in degrees, counter-clockwise from +x, with screen y pointing down.
private func arc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, from: Double, to: Double) -> [CGPoint] {
    let steps = max(8, Int(ceil(abs(to - from) / 3)))
    return (0...steps).map { i in
        let a = (from + (to - from) * Double(i) / Double(steps)) * .pi / 180
        return CGPoint(x: cx + r * cos(a), y: cy - r * sin(a))
    }
}

// MARK: - Expression parser
// Supports + − × ÷ ^, parentheses, implicit multiplication (2x, 3(x+1)),
// x, pi, e and sin cos tan sqrt abs ln log. Anything else is rejected.

enum MathExpression {
    typealias Fn = (Double) -> Double
    private enum Token { case num(Double), id(String), op(Character) }
    private static let names = ["sqrt", "sin", "cos", "tan", "abs", "log", "ln", "pi", "x", "e"]
    private static let functions: [String: Fn] = ["sqrt": { $0.squareRoot() }, "sin": sin, "cos": cos, "tan": tan, "abs": abs, "ln": log, "log": log10]

    private static func tokenize(_ source: String) throws -> [Token] {
        var s = source.lowercased()
        for (from, to) in [("−", "-"), ("–", "-"), ("×", "*"), ("·", "*"), ("÷", "/"), ("π", "pi"), ("²", "^2"), ("³", "^3")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        let chars = Array(s)
        var tokens: [Token] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || c == "." {
                // No scientific notation: "2e" means 2 × e here.
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                guard let value = Double(String(chars[i..<j])) else { throw MathInputError(message: "\"\(String(chars[i..<j]))\" isn't a number.") }
                tokens.append(.num(value)); i = j; continue
            }
            if c.isLetter {
                let rest = String(chars[i...])
                guard let name = names.first(where: { rest.hasPrefix($0) }) else {
                    let word = rest.prefix(while: { $0.isLetter })
                    throw MathInputError(message: "Unknown name \"\(word)\". Use x, pi, e, sin, cos, tan, sqrt, abs, ln, log.")
                }
                tokens.append(.id(name)); i += name.count; continue
            }
            if "+-*/^()".contains(c) { tokens.append(.op(c)); i += 1; continue }
            throw MathInputError(message: "\"\(c)\" isn't allowed in a function.")
        }
        return tokens
    }

    static func compile(_ source: String) throws -> Fn {
        let body = source.contains("=") ? String(source[source.index(after: source.lastIndex(of: "=")!)...]) : source
        let tokens = try tokenize(body)
        guard !tokens.isEmpty else { throw MathInputError(message: "Type a function, for example y = 2x + 1.") }
        var pos = 0

        func isOp(_ c: Character) -> Bool { if pos < tokens.count, case .op(let o) = tokens[pos], o == c { return true }; return false }
        func startsPrimary() -> Bool {
            guard pos < tokens.count else { return false }
            switch tokens[pos] { case .num, .id: return true; case .op(let o): return o == "(" }
        }
        func expr() throws -> Fn {
            var left = try term()
            while isOp("+") || isOp("-") {
                let plus = isOp("+"); pos += 1
                let right = try term(); let l = left
                left = plus ? { l($0) + right($0) } : { l($0) - right($0) }
            }
            return left
        }
        func term() throws -> Fn {
            var left = try unary()
            while true {
                if isOp("*") || isOp("/") {
                    let times = isOp("*"); pos += 1
                    let right = try unary(); let l = left
                    left = times ? { l($0) * right($0) } : { l($0) / right($0) }
                } else if startsPrimary() {
                    let right = try power(); let l = left
                    left = { l($0) * right($0) }
                } else { return left }
            }
        }
        func unary() throws -> Fn {
            if isOp("-") { pos += 1; let inner = try unary(); return { -inner($0) } }
            if isOp("+") { pos += 1; return try unary() }
            return try power()
        }
        func power() throws -> Fn {
            let base = try primary()
            if isOp("^") { pos += 1; let exponent = try unary(); return { pow(base($0), exponent($0)) } }
            return base
        }
        func primary() throws -> Fn {
            guard pos < tokens.count else { throw MathInputError(message: "The function ends too early.") }
            let token = tokens[pos]; pos += 1
            switch token {
            case .num(let v): return { _ in v }
            case .id(let name):
                if name == "x" { return { $0 } }
                if name == "pi" { return { _ in .pi } }
                if name == "e" { return { _ in M_E } }
                guard isOp("(") else { throw MathInputError(message: "Put brackets after \(name), like \(name)(x).") }
                pos += 1
                let inner = try expr()
                guard isOp(")") else { throw MathInputError(message: "A closing bracket is missing.") }
                pos += 1
                let fn = functions[name]!
                return { fn(inner($0)) }
            case .op(let o):
                guard o == "(" else { throw MathInputError(message: "Unexpected \"\(o)\".") }
                let inner = try expr()
                guard isOp(")") else { throw MathInputError(message: "A closing bracket is missing.") }
                pos += 1
                return inner
            }
        }

        let result = try expr()
        if pos < tokens.count {
            switch tokens[pos] {
            case .op(let o): throw MathInputError(message: "Unexpected \"\(o)\".")
            default: throw MathInputError(message: "Something after the function wasn't understood.")
            }
        }
        return result
    }
}

// MARK: - Builders

enum MathDiagramBuilder {
    fileprivate typealias P = MathPalette

    static func build(_ tool: MathToolID, _ specs: MathSpecs) -> Result<MathDiagram, MathInputError> {
        do {
            switch tool {
            case .numberLine: return .success(try numberLine(specs.numberLine))
            case .graph: return .success(try graph(specs.graph))
            case .fractions: return .success(try fractions(specs.fractions))
            case .angle: return .success(try angle(specs.angle))
            case .protractor: return .success(try protractor(specs.protractor))
            case .ruler: return .success(try ruler(specs.ruler))
            case .shape: return .success(try shape(specs.shape))
            }
        } catch let error as MathInputError {
            return .failure(error)
        } catch {
            return .failure(MathInputError(message: error.localizedDescription))
        }
    }

    private static func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    static func numberLine(_ spec: MathSpecs.NumberLine) throws -> MathDiagram {
        let from = try number(spec.from, "From"), to = try number(spec.to, "To"), step = try number(spec.step, "Step")
        guard to > from else { throw MathInputError(message: "\"To\" must be bigger than \"From\".") }
        guard step > 0 else { throw MathInputError(message: "Step must be more than 0.") }
        // Check the size before converting: Int() traps on huge or infinite
        // values (a tiny step, or a range that overflows).
        let steps = (to - from) / step
        guard steps.isFinite else { throw MathInputError(message: "That range is too big. Use smaller numbers.") }
        guard steps <= 40 + 1e-9 else { throw MathInputError(message: "That makes more than 40 ticks. Use a bigger step.") }
        // Round down so the last tick never lands past "To"; the tiny nudge
        // absorbs float error (0.3 / 0.1 is 2.9999…).
        let count = Int((steps + 1e-9).rounded(.down))
        let marks = try spec.marks.split(whereSeparator: { ",; ".contains($0) }).map { try number(String($0), "Each marked point") }

        let width: CGFloat = 760, height: CGFloat = 170, left: CGFloat = 50, right = width - 50, y: CGFloat = 80
        func toX(_ v: Double) -> CGFloat { left + CGFloat((v - from) / (to - from)) * (right - left) }
        var items: [MathPrimitive] = [
            .line(pt(left - 30, y), pt(right + 30, y), color: P.ink, width: 3),
            .poly([pt(left - 18, y - 9), pt(left - 32, y), pt(left - 18, y + 9)], color: P.ink, width: 3),
            .poly([pt(right + 18, y - 9), pt(right + 32, y), pt(right + 18, y + 9)], color: P.ink, width: 3)
        ]
        let labelEvery = max(1, Int(ceil(Double(count) / 20)))
        for i in 0...max(count, 0) {
            let v = from + Double(i) * step, x = toX(v), major = i % labelEvery == 0
            items.append(.line(pt(x, y - (major ? 14 : 8)), pt(x, y + (major ? 14 : 8)), color: P.ink, width: 2.5))
            if major { items.append(.text(mathFormat(v), pt(x, y + 38), size: 20, color: P.ink, anchor: .middle)) }
        }
        for m in marks {
            guard m >= from, m <= to else { throw MathInputError(message: "\(mathFormat(m)) is outside \(mathFormat(from)) to \(mathFormat(to)).") }
            items.append(.circle(pt(toX(m), y), r: 8, fill: P.mark))
            items.append(.text(mathFormat(m), pt(toX(m), y - 26), size: 20, color: P.mark, bold: true, anchor: .middle))
        }
        return MathDiagram(size: CGSize(width: width, height: height), items: items, title: "Number line \(mathFormat(from)) to \(mathFormat(to))")
    }

    static func graph(_ spec: MathSpecs.Graph) throws -> MathDiagram {
        let xMin = try number(spec.xMin, "x from"), xMax = try number(spec.xMax, "x to")
        let yMin = try number(spec.yMin, "y from"), yMax = try number(spec.yMax, "y to")
        guard xMax > xMin else { throw MathInputError(message: "x \"to\" must be bigger than x \"from\".") }
        guard yMax > yMin else { throw MathInputError(message: "y \"to\" must be bigger than y \"from\".") }
        let functions = spec.functions.split(whereSeparator: { $0 == ";" || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard functions.count <= 3 else { throw MathInputError(message: "Plot up to 3 functions at once.") }
        let compiled = try functions.map { (label: $0.contains("=") ? $0 : "y = \($0)", fn: try MathExpression.compile($0)) }

        let regex = try! NSRegularExpression(pattern: "([a-zA-Z]?)\\s*\\(\\s*([-−]?[\\d.]+)\\s*,\\s*([-−]?[\\d.]+)\\s*\\)")
        let ns = spec.points as NSString
        let points = try regex.matches(in: spec.points, range: NSRange(location: 0, length: ns.length)).map {
            (name: ns.substring(with: $0.range(at: 1)).uppercased(), x: try number(ns.substring(with: $0.range(at: 2)), "Point x"), y: try number(ns.substring(with: $0.range(at: 3)), "Point y"))
        }
        if !spec.points.trimmingCharacters(in: .whitespaces).isEmpty && points.isEmpty { throw MathInputError(message: "Write points like (2, 3) or A(2, 3).") }

        // Equal units on both axes so slopes and shapes look right.
        let xr = xMax - xMin, yr = yMax - yMin
        let unit = 520 / max(xr, yr)
        let pad: CGFloat = 36
        let plot = CGRect(x: pad, y: pad, width: CGFloat(xr * unit), height: CGFloat(yr * unit))
        func toX(_ v: Double) -> CGFloat { plot.minX + CGFloat((v - xMin) * unit) }
        func toY(_ v: Double) -> CGFloat { plot.minY + CGFloat((yMax - v) * unit) }
        var items: [MathPrimitive] = []

        let gridStep = niceStep(max(xr, yr) / 20), labelStep = niceStep(max(xr, yr) / 10)
        var v = ceil(xMin / gridStep) * gridStep
        while v <= xMax + 1e-9 { items.append(.line(pt(toX(v), plot.minY), pt(toX(v), plot.maxY), color: P.grid, width: 1.5)); v += gridStep }
        v = ceil(yMin / gridStep) * gridStep
        while v <= yMax + 1e-9 { items.append(.line(pt(plot.minX, toY(v)), pt(plot.maxX, toY(v)), color: P.grid, width: 1.5)); v += gridStep }

        // Axes sit at 0 when 0 is in range, otherwise along the edge.
        let axisY = toY(min(max(0, yMin), yMax)), axisX = toX(min(max(0, xMin), xMax))
        items.append(.line(pt(plot.minX, axisY), pt(plot.maxX, axisY), color: P.ink, width: 2.5))
        items.append(.line(pt(axisX, plot.minY), pt(axisX, plot.maxY), color: P.ink, width: 2.5))
        items.append(.text("x", pt(plot.maxX + 14, axisY + 6), size: 20, color: P.ink, bold: true))
        items.append(.text("y", pt(axisX, plot.minY - 14), size: 20, color: P.ink, bold: true, anchor: .middle))
        v = ceil(xMin / labelStep) * labelStep
        while v <= xMax + 1e-9 {
            if abs(v) > 1e-9 {
                items.append(.line(pt(toX(v), axisY - 5), pt(toX(v), axisY + 5), color: P.ink, width: 2))
                items.append(.text(mathFormat(v), pt(toX(v), axisY + 22), size: 14, color: P.label, anchor: .middle))
            }
            v += labelStep
        }
        v = ceil(yMin / labelStep) * labelStep
        while v <= yMax + 1e-9 {
            if abs(v) > 1e-9 {
                items.append(.line(pt(axisX - 5, toY(v)), pt(axisX + 5, toY(v)), color: P.ink, width: 2))
                items.append(.text(mathFormat(v), pt(axisX - 9, toY(v) + 5), size: 14, color: P.label, anchor: .end))
            }
            v += labelStep
        }

        for (index, curve) in compiled.enumerated() {
            let color = P.curves[index]
            var segment: [CGPoint] = []
            var lastY: Double?
            var visible = false
            func flush() { if segment.count > 1 { items.append(.poly(segment, color: color, width: 3.5, clip: plot)) }; segment = [] }
            for i in 0...600 {
                let x = xMin + xr * Double(i) / 600
                let y = curve.fn(x)
                // Break the curve at gaps (sqrt of negatives) and asymptotes (1/x).
                guard y.isFinite else { flush(); lastY = nil; continue }
                if let last = lastY, abs(y - last) > yr * 2 { flush() }
                lastY = y
                segment.append(pt(toX(x), toY(min(max(y, yMin - yr), yMax + yr))))
                if y >= yMin && y <= yMax { visible = true }
            }
            flush()
            guard visible else { throw MathInputError(message: "\(curve.label) doesn't pass through this window. Try a bigger range.") }
        }

        // A colour-coded key in the corner; labels along the curves collided
        // whenever two curves left the window at the same edge.
        if !compiled.isEmpty {
            let rowH: CGFloat = 24
            let keyW = 34 + CGFloat(compiled.map(\.label.count).max() ?? 0) * 9.5
            items.append(.rect(CGRect(x: plot.minX + 8, y: plot.minY + 8, width: keyW, height: CGFloat(compiled.count) * rowH + 10), fill: Color.white.opacity(0.92), stroke: P.grid, width: 1.5, radius: 8))
            for (index, curve) in compiled.enumerated() {
                let rowY = plot.minY + 13 + CGFloat(index) * rowH + rowH / 2
                items.append(.line(pt(plot.minX + 18, rowY), pt(plot.minX + 34, rowY), color: P.curves[index], width: 4))
                items.append(.text(curve.label.replacingOccurrences(of: "*", with: "·"), pt(plot.minX + 40, rowY + 6), size: 16, color: P.curves[index], bold: true))
            }
        }

        for p in points {
            guard p.x >= xMin, p.x <= xMax, p.y >= yMin, p.y <= yMax else { throw MathInputError(message: "(\(mathFormat(p.x)), \(mathFormat(p.y))) is outside the graph window.") }
            items.append(.circle(pt(toX(p.x), toY(p.y)), r: 7, fill: P.mark))
            items.append(.text("\(p.name.isEmpty ? "" : "\(p.name) ")(\(mathFormat(p.x)), \(mathFormat(p.y)))", pt(toX(p.x) + 11, toY(p.y) - 10), size: 16, color: P.mark, bold: true))
        }
        let size = CGSize(width: plot.width + pad * 2, height: plot.height + pad * 2)
        return MathDiagram(size: size, items: items, title: functions.first ?? "Coordinate grid")
    }

    static func fractions(_ spec: MathSpecs.Fractions) throws -> MathDiagram {
        let parsed = try spec.fractions.split(whereSeparator: { ",;\n".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { text -> (n: Int, d: Int, text: String) in
            let parts = text.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let n = Int(parts[0]), let d = Int(parts[1]), n >= 0 else { throw MathInputError(message: "\"\(text)\" isn't a fraction. Write fractions like 3/4.") }
            guard d != 0 else { throw MathInputError(message: "A fraction can’t have 0 at the bottom.") }
            guard d <= 24 else { throw MathInputError(message: "Keep the bottom number at 24 or less so the parts stay visible.") }
            guard n <= d * 3 else { throw MathInputError(message: "\(text) is more than 3 wholes. Try a smaller fraction.") }
            return (n, d, "\(n)/\(d)")
        }
        guard !parsed.isEmpty else { throw MathInputError(message: "Type at least one fraction, like 1/2.") }
        guard parsed.count <= 6 else { throw MathInputError(message: "Compare up to 6 fractions at once.") }

        let labelW: CGFloat = 90, barW: CGFloat = 560, rowH: CGFloat = 64, gap: CGFloat = 22, pad: CGFloat = 20
        let size = CGSize(width: pad * 2 + labelW + barW, height: pad * 2 + CGFloat(parsed.count) * rowH + CGFloat(parsed.count - 1) * gap)
        var items: [MathPrimitive] = []
        for (row, f) in parsed.enumerated() {
            let y = pad + CGFloat(row) * (rowH + gap)
            let wholes = max(1, Int(ceil(Double(f.n) / Double(f.d))))
            let wholeW = (barW - CGFloat(wholes - 1) * 12) / CGFloat(wholes)
            items.append(.text(f.text, pt(pad + labelW - 20, y + rowH / 2 + 9), size: 26, color: P.ink, bold: true, anchor: .end))
            for w in 0..<wholes {
                let x0 = pad + labelW + CGFloat(w) * (wholeW + 12)
                let partW = wholeW / CGFloat(f.d)
                for p in 0..<f.d {
                    let filled = w * f.d + p < f.n
                    items.append(.rect(CGRect(x: x0 + CGFloat(p) * partW, y: y, width: partW, height: rowH), fill: filled ? P.accentFill : .white, stroke: P.ink, width: 2.5))
                }
            }
        }
        return MathDiagram(size: size, items: items, title: "Fractions \(parsed.map(\.text).joined(separator: ", "))")
    }

    private static func angleType(_ deg: Double) -> String {
        deg < 90 ? "Acute" : deg == 90 ? "Right" : deg < 180 ? "Obtuse" : deg == 180 ? "Straight" : "Reflex"
    }

    static func angle(_ spec: MathSpecs.Angle) throws -> MathDiagram {
        let deg = try number(spec.degrees, "The angle")
        guard deg > 0, deg < 360 else { throw MathInputError(message: "Use an angle between 0° and 360°.") }
        let width: CGFloat = 560, height: CGFloat = 400, len: CGFloat = 230
        let vx: CGFloat = deg > 180 ? width / 2 : deg > 90 ? width / 2 + 30 : 150
        let vy: CGFloat = deg > 180 ? height / 2 : 300
        let rad = deg * .pi / 180
        var items: [MathPrimitive] = [
            .line(pt(vx, vy), pt(vx + len, vy), color: P.ink, width: 4),
            .line(pt(vx, vy), pt(vx + len * CGFloat(cos(rad)), vy - len * CGFloat(sin(rad))), color: P.ink, width: 4),
            .circle(pt(vx, vy), r: 5, fill: P.ink)
        ]
        if deg == 90 {
            items.append(.poly([pt(vx + 34, vy), pt(vx + 34, vy - 34), pt(vx, vy - 34)], color: P.accent, width: 3))
        } else {
            items.append(.poly(arc(vx, vy, 60, from: 0, to: deg), color: P.accent, width: 3))
        }
        let mid = rad / 2
        items.append(.text(spec.hideMeasure ? "?" : "\(mathFormat(deg))°", pt(vx + 100 * CGFloat(cos(mid)), vy - 100 * CGFloat(sin(mid)) + 9), size: 28, color: P.accent, bold: true, anchor: .middle))
        items.append(.text(spec.hideMeasure ? "Measure the angle" : "\(angleType(deg)) angle", pt(width / 2, height - 16), size: 18, color: P.label, anchor: .middle))
        return MathDiagram(size: CGSize(width: width, height: height), items: items, title: "\(mathFormat(deg))° angle")
    }

    static func protractor(_ spec: MathSpecs.Protractor) throws -> MathDiagram {
        let trimmed = spec.degrees.trimmingCharacters(in: .whitespaces)
        let marked: Double? = trimmed.isEmpty ? nil : try number(trimmed, "The angle")
        if let marked, marked < 0 || marked > 180 { throw MathInputError(message: "A protractor shows 0° to 180°.") }
        let width: CGFloat = 660, height: CGFloat = 380, cx = width / 2, cy: CGFloat = 330, r: CGFloat = 290
        var items: [MathPrimitive] = [
            .poly(arc(cx, cy, r, from: 0, to: 180) + [pt(cx - r, cy)], color: P.ink, width: 3, fill: AppTheme.accent.opacity(0.05), closed: true),
            .poly(arc(cx, cy, r - 70, from: 0, to: 180), color: P.muted, width: 1.5)
        ]
        for d in 0...180 {
            let tick: CGFloat = d % 10 == 0 ? 22 : d % 5 == 0 ? 15 : 8
            let a = Double(d) * .pi / 180
            let (c, s) = (CGFloat(cos(a)), CGFloat(sin(a)))
            items.append(.line(pt(cx + r * c, cy - r * s), pt(cx + (r - tick) * c, cy - (r - tick) * s), color: P.ink, width: d % 10 == 0 ? 2 : 1))
            if d % 10 == 0 {
                items.append(.text("\(180 - d)", pt(cx + (r - 40) * c, cy - (r - 40) * s + 5), size: 14, color: P.ink, anchor: .middle))
                items.append(.text("\(d)", pt(cx + (r - 92) * c, cy - (r - 92) * s + 5), size: 12, color: P.secondary, anchor: .middle))
            }
        }
        items.append(.line(pt(cx - r, cy), pt(cx + r, cy), color: P.ink, width: 3))
        items.append(.circle(pt(cx, cy), r: 5, fill: P.ink))
        if let marked {
            // Measured from the left-hand zero, matching the outer scale.
            let a = (180 - marked) * .pi / 180
            items.append(.line(pt(cx, cy), pt(cx + (r + 10) * CGFloat(cos(a)), cy - (r + 10) * CGFloat(sin(a))), color: P.mark, width: 3.5))
            items.append(.line(pt(cx, cy), pt(cx - r - 10, cy), color: P.mark, width: 3.5))
            items.append(.poly(arc(cx, cy, 70, from: 180 - marked, to: 180), color: P.mark, width: 3))
            items.append(.text("\(mathFormat(marked))°", pt(cx, cy + 38), size: 24, color: P.mark, bold: true, anchor: .middle))
        }
        return MathDiagram(size: CGSize(width: width, height: marked != nil ? height + 10 : height), items: items, title: marked.map { "Protractor \(mathFormat($0))°" } ?? "Protractor")
    }

    static func ruler(_ spec: MathSpecs.Ruler) throws -> MathDiagram {
        let length = try number(spec.length, "Length")
        guard length > 0, length <= 30, length == length.rounded() else { throw MathInputError(message: "Use a whole-number length from 1 to 30.") }
        let cm = spec.unit == "cm"
        let perUnit: CGFloat = cm ? 50 : 96, subdivisions = cm ? 10 : 8
        let pad: CGFloat = 30, total = Int(length) * subdivisions
        let size = CGSize(width: CGFloat(length) * perUnit + pad * 2 + 20, height: 140)
        var items: [MathPrimitive] = [.rect(CGRect(x: pad - 10, y: 20, width: CGFloat(length) * perUnit + 40, height: 100), fill: Color(hex: "fefce8"), stroke: P.ink, width: 2.5, radius: 10)]
        for i in 0...total {
            let x = pad + 10 + CGFloat(i) * perUnit / CGFloat(subdivisions)
            let whole = i % subdivisions == 0, half = i % (subdivisions / 2) == 0
            let tick: CGFloat = whole ? 38 : half ? 26 : (!cm && i % 2 == 0) ? 18 : 13
            items.append(.line(pt(x, 20), pt(x, 20 + tick), color: P.ink, width: whole ? 2.2 : 1.3))
            if whole { items.append(.text("\(i / subdivisions)", pt(x, 84), size: 18, color: P.ink, bold: true, anchor: .middle)) }
        }
        items.append(.text(spec.unit, pt(pad + 10 + CGFloat(length) * perUnit, 110), size: 14, color: P.secondary, anchor: .end))
        return MathDiagram(size: size, items: items, title: "\(mathFormat(length)) \(spec.unit) ruler")
    }

    static func shape(_ spec: MathSpecs.Shape) throws -> MathDiagram {
        let rect = spec.kind == "rectangle"
        let a = try number(spec.a, rect ? "Width" : "Side a"), b = try number(spec.b, rect ? "Height" : "Side b")
        guard a > 0, b > 0 else { throw MathInputError(message: "Side lengths must be more than 0.") }
        guard max(a, b) / min(a, b) <= 8 else { throw MathInputError(message: "Keep the longer side under 8× the shorter one so it stays readable.") }
        let unit = spec.unit.trimmingCharacters(in: .whitespaces)
        func withUnit(_ v: Double) -> String { unit.isEmpty ? mathFormat(v) : "\(mathFormat(v)) \(unit)" }
        let width: CGFloat = 560, height: CGFloat = 470, box: CGFloat = 320
        let scale = box / CGFloat(max(a, b))
        let w = CGFloat(a) * scale, h = CGFloat(b) * scale
        let x0 = (width - w) / 2, y0 = 50 + (box - h) / 2 + 10
        var items: [MathPrimitive] = []
        if rect {
            items.append(.rect(CGRect(x: x0, y: y0, width: w, height: h), fill: P.accentTint, stroke: P.ink, width: 4))
            items.append(.text(withUnit(a), pt(x0 + w / 2, y0 + h + 32), size: 22, color: P.ink, bold: true, anchor: .middle))
            items.append(.text(withUnit(b), pt(x0 + w + 14, y0 + h / 2 + 8), size: 22, color: P.ink, bold: true))
            items.append(.text(spec.hideAnswer ? "Area = ?" : "Area = \(mathFormat(a * b))\(unit.isEmpty ? "" : " \(unit)²")", pt(width / 2, height - 34), size: 20, color: P.accent, bold: true, anchor: .middle))
            items.append(.text(spec.hideAnswer ? "Perimeter = ?" : "Perimeter = \(withUnit(2 * (a + b)))", pt(width / 2, height - 8), size: 18, color: P.accent, anchor: .middle))
            return MathDiagram(size: CGSize(width: width, height: height), items: items, title: "Rectangle \(mathFormat(a)) × \(mathFormat(b))")
        }
        // Right angle bottom-left: a along the bottom, b up the left side.
        items.append(.poly([pt(x0, y0), pt(x0, y0 + h), pt(x0 + w, y0 + h)], color: P.ink, width: 4, fill: P.accentTint, closed: true))
        items.append(.poly([pt(x0 + 26, y0 + h), pt(x0 + 26, y0 + h - 26), pt(x0, y0 + h - 26)], color: P.ink, width: 2.5))
        let c = hypot(a, b)
        items.append(.text(withUnit(a), pt(x0 + w / 2, y0 + h + 32), size: 22, color: P.ink, bold: true, anchor: .middle))
        items.append(.text(withUnit(b), pt(x0 - 14, y0 + h / 2 + 8), size: 22, color: P.ink, bold: true, anchor: .end))
        items.append(.text(spec.hideAnswer ? "?" : withUnit(c), pt(x0 + w / 2 + 18, y0 + h / 2 - 6), size: 22, color: P.accent, bold: true))
        items.append(.text(spec.hideAnswer ? "Find the hypotenuse" : "\(mathFormat(a))² + \(mathFormat(b))² = \(mathFormat(c))²", pt(width / 2, height - 8), size: 18, color: P.label, anchor: .middle))
        return MathDiagram(size: CGSize(width: width, height: height), items: items, title: "Right triangle \(mathFormat(a)), \(mathFormat(b))")
    }
}

// MARK: - Drawing

/// Draws a diagram scaled to fit its frame. `card` adds the white background
/// used on the board so strokes underneath don't hide the labels.
struct MathDiagramView: View {
    let diagram: MathDiagram
    var card = false

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / diagram.size.width, size.height / diagram.size.height)
            context.translateBy(x: (size.width - diagram.size.width * scale) / 2, y: (size.height - diagram.size.height * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            if card {
                context.fill(Path(roundedRect: CGRect(origin: .zero, size: diagram.size), cornerRadius: 16), with: .color(.white))
            }
            let round = StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
            for item in diagram.items {
                switch item {
                case let .line(a, b, color, width):
                    var path = Path(); path.move(to: a); path.addLine(to: b)
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
                case let .poly(points, color, width, fill, closed, clip):
                    var path = Path(); path.addLines(points); if closed { path.closeSubpath() }
                    context.drawLayer { layer in
                        if let clip { layer.clip(to: Path(clip)) }
                        if let fill { layer.fill(path, with: .color(fill)) }
                        var style = round; style.lineWidth = width
                        layer.stroke(path, with: .color(color), style: style)
                    }
                case let .circle(center, r, fill):
                    context.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)), with: .color(fill))
                case let .rect(rect, fill, stroke, width, radius):
                    let path = Path(roundedRect: rect, cornerRadius: radius)
                    context.fill(path, with: .color(fill))
                    if let stroke { context.stroke(path, with: .color(stroke), lineWidth: width) }
                case let .text(string, point, size, color, bold, anchor):
                    // Points are text baselines (as in SVG); Canvas anchors by
                    // the text's centre, so lift by roughly a third of the size.
                    let text = Text(string).font(.system(size: size, weight: bold ? .bold : .medium)).foregroundColor(color)
                    let unitAnchor: UnitPoint = anchor == .start ? .leading : anchor == .end ? .trailing : .center
                    context.draw(text, at: CGPoint(x: point.x, y: point.y - size * 0.35), anchor: unitAnchor)
                }
            }
        }
        .accessibilityLabel(diagram.title)
    }
}

@MainActor
enum MathDiagramRenderer {
    /// Renders at 2× so diagrams stay crisp when the tutor zooms the board.
    static func image(for diagram: MathDiagram) -> UIImage? {
        let renderer = ImageRenderer(content: MathDiagramView(diagram: diagram, card: true).frame(width: diagram.size.width, height: diagram.size.height))
        renderer.scale = 2
        renderer.isOpaque = false
        return renderer.uiImage
    }
}

// MARK: - Toolkit sheet

struct MathToolkitView: View {
    let onInsert: (UIImage, MathDiagram) -> Void
    @Environment(\.dismiss) private var dismiss

    @AppStorage("mathToolkit.tool") private var toolRaw = MathToolID.graph.rawValue
    @AppStorage("mathToolkit.specs") private var specsJSON = ""
    @State private var specs = MathSpecs()
    @State private var lastGood: MathDiagram?
    @State private var insertFailed = false

    private var tool: MathToolID { MathToolID(rawValue: toolRaw) ?? .graph }
    private var result: Result<MathDiagram, MathInputError> { MathDiagramBuilder.build(tool, specs) }

    private static let functionExamples = ["2x + 1", "x^2 - 3", "-x^2 + 4", "sin(x)", "1/x", "sqrt(x)", "abs(x)"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                toolPicker
                Text(tool.hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                preview
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                Form {
                    fields
                    if case .failure(let error) = result {
                        Section { Label(error.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.subheadline.weight(.semibold)) }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Math Toolkit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add to board", action: insert).bold().disabled(!isValid)
                }
            }
            .alert("Couldn't add this diagram", isPresented: $insertFailed) { Button("OK", role: .cancel) {} }
        }
        .presentationDetents([.large])
        .onAppear {
            if let data = specsJSON.data(using: .utf8), let saved = try? JSONDecoder().decode(MathSpecs.self, from: data) { specs = saved }
            refreshPreview()
        }
        .onChange(of: specs) {
            if let data = try? JSONEncoder().encode(specs) { specsJSON = String(decoding: data, as: UTF8.self) }
            refreshPreview()
        }
        .onChange(of: toolRaw) { lastGood = nil; refreshPreview() }
    }

    private var isValid: Bool { if case .success = result { return true }; return false }

    // Keep showing the last valid drawing while the tutor is mid-edit.
    private func refreshPreview() { if case .success(let diagram) = result { lastGood = diagram } }

    private var toolPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MathToolID.allCases) { item in
                    Button { toolRaw = item.rawValue } label: {
                        Text(item.label).font(.subheadline.weight(.bold))
                            .padding(.horizontal, 16).frame(height: 40)
                            .background(item == tool ? AppTheme.accent : Color.secondary.opacity(0.12), in: Capsule())
                            .foregroundStyle(item == tool ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(item == tool ? .isSelected : [])
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18).fill(Color.secondary.opacity(0.07))
            if let lastGood {
                MathDiagramView(diagram: lastGood).padding(12).opacity(isValid ? 1 : 0.4)
            } else {
                Text("Fill in the values to see a preview").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(height: 220)
    }

    private func numberField(_ label: String, _ text: Binding<String>, keyboard: UIKeyboardType = .numbersAndPunctuation) -> some View {
        LabeledContent(label) {
            TextField(label, text: text).keyboardType(keyboard).multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private var fields: some View {
        switch tool {
        case .numberLine:
            Section {
                numberField("From", $specs.numberLine.from)
                numberField("To", $specs.numberLine.to)
                numberField("Step", $specs.numberLine.step)
            }
            Section { TextField("e.g. -2, 3.5", text: $specs.numberLine.marks).keyboardType(.numbersAndPunctuation) } header: { Text("Mark points (optional)") }
        case .graph:
            Section {
                TextField("y = 2x + 1", text: $specs.graph.functions).textInputAutocapitalization(.never).autocorrectionDisabled()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(Self.functionExamples, id: \.self) { example in
                            Button(example) { specs.graph.functions = "y = \(example)" }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                        }
                    }
                }
            } header: { Text("Functions") } footer: { Text("Up to 3, separated by ;") }
            Section { TextField("e.g. A(1, 2), (-3, 4)", text: $specs.graph.points).textInputAutocapitalization(.characters).autocorrectionDisabled() } header: { Text("Points (optional)") }
            Section("Window") {
                numberField("x from", $specs.graph.xMin)
                numberField("x to", $specs.graph.xMax)
                numberField("y from", $specs.graph.yMin)
                numberField("y to", $specs.graph.yMax)
            }
        case .fractions:
            Section { TextField("1/2, 3/4", text: $specs.fractions.fractions).keyboardType(.numbersAndPunctuation) } header: { Text("Fractions to compare") } footer: { Text("Separate with commas, e.g. 1/2, 3/4, 5/4") }
        case .angle:
            Section {
                numberField("Angle (degrees)", $specs.angle.degrees, keyboard: .decimalPad)
                Toggle("Hide the measurement (for a question)", isOn: $specs.angle.hideMeasure)
            }
        case .protractor:
            Section { numberField("Mark an angle", $specs.protractor.degrees, keyboard: .decimalPad) } footer: { Text("0 to 180 degrees; leave empty for a plain protractor") }
        case .ruler:
            Section {
                numberField("Length", $specs.ruler.length, keyboard: .numberPad)
                Picker("Units", selection: $specs.ruler.unit) { Text("cm").tag("cm"); Text("inches").tag("in") }.pickerStyle(.segmented)
            }
        case .shape:
            Section {
                Picker("Shape", selection: $specs.shape.kind) { Text("Right triangle").tag("rightTriangle"); Text("Rectangle").tag("rectangle") }.pickerStyle(.segmented)
                numberField(specs.shape.kind == "rectangle" ? "Width" : "Base (a)", $specs.shape.a, keyboard: .decimalPad)
                numberField(specs.shape.kind == "rectangle" ? "Height" : "Height (b)", $specs.shape.b, keyboard: .decimalPad)
                LabeledContent("Unit") { TextField("Unit", text: $specs.shape.unit).multilineTextAlignment(.trailing) }
                Toggle(specs.shape.kind == "rectangle" ? "Hide area and perimeter" : "Hide the hypotenuse", isOn: $specs.shape.hideAnswer)
            } footer: { Text("Hide the answer to pose it as a question.") }
        }
    }

    private func insert() {
        guard case .success(let diagram) = result, let image = MathDiagramRenderer.image(for: diagram) else { insertFailed = true; return }
        onInsert(image, diagram)
        dismiss()
    }
}

#Preview {
    MathToolkitView { _, _ in }
}
