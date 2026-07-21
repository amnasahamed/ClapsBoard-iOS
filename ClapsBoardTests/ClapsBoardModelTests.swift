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
