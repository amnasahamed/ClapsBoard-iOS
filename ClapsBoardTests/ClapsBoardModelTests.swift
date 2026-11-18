//
//  ClapsBoardModelTests.swift
//  ClapsBoardTests
//

import CoreGraphics
import XCTest
@testable import ClapsBoard

final class AppStateTests: XCTestCase {
    private let onboardingKey = "hasSeenOnboarding"

    override func setUpWithError() throws {
        UserDefaults.standard.removeObject(forKey: onboardingKey)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: onboardingKey)
    }

    func testOnboardingStatePersistsAfterCompletion() {
        let state = AppState()

        XCTAssertTrue(state.showOnboarding)

        state.completeOnboarding()

        XCTAssertFalse(state.showOnboarding)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: onboardingKey))
    }
}

final class ClassSessionManagerTests: XCTestCase {
    private let saveKey = "classSessions"

    override func setUpWithError() throws {
        UserDefaults.standard.removeObject(forKey: saveKey)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: saveKey)
    }

    func testAddUpdateDeleteSessionPersists() {
        let manager = ClassSessionManager()
        let session = ClassSession(
            title: "Math",
            date: Date().addingTimeInterval(3600),
            link: "https://example.com",
            color: "#3b82f6",
            notes: "Fractions"
        )

        manager.addSession(session)

        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertNotNil(UserDefaults.standard.data(forKey: saveKey))

        var updated = session
        updated.title = "Science"
        manager.updateSession(updated)

        XCTAssertEqual(manager.sessions.first?.title, "Science")

        let reloaded = ClassSessionManager()
        XCTAssertEqual(reloaded.sessions.first?.title, "Science")

        manager.deleteSession(id: session.id)

        XCTAssertTrue(manager.sessions.isEmpty)
    }

    func testUpcomingSessionsExcludeCompletedAndPastSessions() {
        let manager = ClassSessionManager()
        let upcoming = ClassSession(title: "Next", date: Date().addingTimeInterval(7200))
        let completed = ClassSession(title: "Done", date: Date().addingTimeInterval(3600), isCompleted: true)
        let past = ClassSession(title: "Past", date: Date().addingTimeInterval(-3600))

        manager.addSession(completed)
        manager.addSession(past)
        manager.addSession(upcoming)

        XCTAssertEqual(manager.upcomingSessions.map(\.title), ["Next"])
    }
}

final class ClassCountdownLiveActivityCoordinatorTests: XCTestCase {
    func testCountdownCandidateUsesOnlyNextClassInsideFiveMinuteWindow() {
        let now = Date()
        let later = ClassSession(title: "Later", date: now.addingTimeInterval(900))
        let completed = ClassSession(title: "Completed", date: now.addingTimeInterval(120), isCompleted: true)
        let next = ClassSession(title: "Next", date: now.addingTimeInterval(240))
        let sooner = ClassSession(title: "Sooner", date: now.addingTimeInterval(90))

        let candidate = ClassCountdownLiveActivityCoordinator.countdownCandidate(
            from: [later, completed, next, sooner],
            now: now
        )

        XCTAssertEqual(candidate?.title, "Sooner")
    }

    func testCountdownCandidateIgnoresClassesOutsideFiveMinuteWindow() {
        let now = Date()
        let session = ClassSession(title: "Later", date: now.addingTimeInterval(301))

        let candidate = ClassCountdownLiveActivityCoordinator.countdownCandidate(from: [session], now: now)

        XCTAssertNil(candidate)
    }
}

final class DrawingElementTests: XCTestCase {
    func testPathElementCalculatesBoundsFromPoints() {
        let points = [
            CGPoint(x: 18, y: 42),
            CGPoint(x: 10, y: 60),
            CGPoint(x: 31, y: 20)
        ]

        let element = DrawingElement(type: .pen, points: points)

        XCTAssertEqual(Double(element.x), 10, accuracy: 0.001)
        XCTAssertEqual(Double(element.y), 20, accuracy: 0.001)
        XCTAssertEqual(Double(element.width), 21, accuracy: 0.001)
        XCTAssertEqual(Double(element.height), 40, accuracy: 0.001)
    }

    func testToolPropertySupportMatchesInteractiveControls() {
        XCTAssertFalse(ToolType.pan.supportsProperties)
        XCTAssertFalse(ToolType.select.supportsProperties)
        XCTAssertFalse(ToolType.image.supportsProperties)

        XCTAssertTrue(ToolType.pen.supportsProperties)
        XCTAssertTrue(ToolType.marker.supportsProperties)
        XCTAssertTrue(ToolType.eraser.supportsProperties)
        XCTAssertTrue(ToolType.text.supportsProperties)
        XCTAssertTrue(ToolType.rectangle.supportsProperties)
        XCTAssertTrue(ToolType.circle.supportsProperties)
        XCTAssertTrue(ToolType.line.supportsProperties)
        XCTAssertTrue(ToolType.sticker.supportsProperties)
    }
}

@MainActor
final class LessonStoreTests: XCTestCase {
    private let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClapsBoard", isDirectory: true)
    private lazy var files = ["lesson-workspace-v1.json", "lesson-workspace-v1-recovery.json"]
        .map { directory.appendingPathComponent($0) }
    private var originals: [URL: Data] = [:]

    override func setUp() async throws {
        // The store writes to the host app's real workspace, so keep a copy.
        for url in files { originals[url] = try? Data(contentsOf: url) }
    }

    override func tearDown() async throws {
        for url in files {
            if let data = originals[url] { try data.write(to: url) } else { try? FileManager.default.removeItem(at: url) }
        }
    }

    func testEditsAreDebouncedThenFlushedToDisk() {
        let store = LessonStore()
        let element = DrawingElement(type: .pen, points: [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)], color: .black, strokeWidth: 3)

        store.updateActivePage(elements: [element], gridStyle: .none)
        XCTAssertNotEqual(LessonStore().activePage.elements.map(\.id), [element.id], "save should be debounced, not written synchronously")

        store.flushPendingSave()
        XCTAssertEqual(LessonStore().activePage.elements.map(\.id), [element.id])
    }
}

@MainActor
final class ExportRenderingTests: XCTestCase {
    func testExportedPenStrokeKeepsItsColour() throws {
        let stroke = DrawingElement(type: .pen, points: (0...10).map { CGPoint(x: CGFloat($0) * 20, y: 100) }, color: .red, strokeWidth: 12)
        let image = try XCTUnwrap(CanvasViewModel().exportImage(elements: [stroke], gridStyle: .none)?.cgImage)

        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var red = 0, dark = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let (r, g, b) = (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
            if r > 200 && g < 80 && b < 80 { red += 1 }
            if r < 60 && g < 60 && b < 60 { dark += 1 }
        }
        XCTAssertGreaterThan(red, 0, "stroke should render in its own colour")
        XCTAssertEqual(dark, 0, "stroke rendered in the default black")
    }
}

final class MathToolkitTests: XCTestCase {
    func testExpressionParserMatchesAndroid() throws {
        let cases: [(String, Double, Double)] = [
            ("y = 2x + 1", 3, 7), ("x^2 - 3", -2, 1), ("-x^2", 2, -4), ("2(x+1)", 1, 4),
            ("3sin(x)", .pi / 2, 3), ("sqrt(x)", 9, 3), ("1/x", 4, 0.25), ("2^3^2", 0, 512),
            ("f(x) = 2πx", 1, 2 * .pi), ("x(x-1)", 3, 6), ("(x+1)(x-1)", 3, 8), ("2e", 0, 2 * M_E)
        ]
        for (source, x, expected) in cases {
            XCTAssertEqual(try MathExpression.compile(source)(x), expected, accuracy: 1e-9, source)
        }
        for bad in ["2x +", "y = foo(x)", "(x+1", "x$"] {
            XCTAssertThrowsError(try MathExpression.compile(bad), bad)
        }
    }

    func testEveryToolBuildsFromDefaults() {
        for tool in MathToolID.allCases {
            if case .failure(let error) = MathDiagramBuilder.build(tool, MathSpecs()) {
                XCTFail("\(tool) failed: \(error.message)")
            }
        }
    }

    func testInvalidInputGivesReadableErrors() {
        var specs = MathSpecs()
        specs.fractions.fractions = "3/0"
        guard case .failure(let error) = MathDiagramBuilder.build(.fractions, specs) else { return XCTFail("expected failure") }
        XCTAssertEqual(error.message, "A fraction can’t have 0 at the bottom.")

        specs.graph.functions = "y = x + 100"
        guard case .failure(let offscreen) = MathDiagramBuilder.build(.graph, specs) else { return XCTFail("expected failure") }
        XCTAssertTrue(offscreen.message.contains("doesn't pass through this window"))
    }

    func testFormatting() {
        XCTAssertEqual(mathFormat(0.1 + 0.2), "0.3")
        XCTAssertEqual(mathFormat(-2), "−2")
        XCTAssertEqual(mathFormat(-0.0), "0")
    }
}
