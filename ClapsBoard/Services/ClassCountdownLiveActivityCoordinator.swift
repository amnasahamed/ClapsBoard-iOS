//
//  ClassCountdownLiveActivityCoordinator.swift
//  ClapsBoard
//
//  Starts a local Live Activity when a class is inside the five-minute countdown window.
//

import ActivityKit
import Foundation

@MainActor
final class ClassCountdownLiveActivityCoordinator: ObservableObject {
    nonisolated static let countdownWindow: TimeInterval = 5 * 60

    private var timer: Timer?
    private var sessions: [ClassSession] = []

    deinit {
        timer?.invalidate()
    }

    func startMonitoring(sessions: [ClassSession]) {
        self.sessions = sessions
        syncNow()

        guard timer == nil else { return }

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncNow()
            }
        }
    }

    func updateSessions(_ sessions: [ClassSession]) {
        self.sessions = sessions
        syncNow()
    }

    func endActivity(for classId: UUID) {
        guard #available(iOS 16.2, *) else { return }

        Task {
            for activity in Activity<ClassCountdownAttributes>.activities where activity.attributes.classId == classId {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    nonisolated static func countdownCandidate(from sessions: [ClassSession], now: Date = Date()) -> ClassSession? {
        sessions
            .filter { session in
                let timeUntilStart = session.date.timeIntervalSince(now)
                return !session.isCompleted && timeUntilStart > 0 && timeUntilStart <= countdownWindow
            }
            .sorted { $0.date < $1.date }
            .first
    }

    private func syncNow() {
        guard #available(iOS 16.2, *) else { return }

        let snapshot = sessions
        Task {
            await reconcileActivities(with: snapshot)
        }
    }

    @available(iOS 16.2, *)
    private func reconcileActivities(with sessions: [ClassSession]) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            await endAllActivities()
            return
        }

        guard let candidate = Self.countdownCandidate(from: sessions) else {
            await endAllActivities()
            return
        }

        let activeActivities = Activity<ClassCountdownAttributes>.activities

        for activity in activeActivities where activity.attributes.classId != candidate.id {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        let state = ClassCountdownAttributes.ContentState(
            title: candidate.title.isEmpty ? "Class" : candidate.title,
            scheduledStart: candidate.date
        )
        let content = ActivityContent(state: state, staleDate: candidate.date.addingTimeInterval(60))

        if let existing = activeActivities.first(where: { $0.attributes.classId == candidate.id }) {
            await existing.update(content)
            return
        }

        do {
            let attributes = ClassCountdownAttributes(classId: candidate.id)
            _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
        } catch {
            print("Failed to start class countdown Live Activity: \(error.localizedDescription)")
        }
    }

    @available(iOS 16.2, *)
    private func endAllActivities() async {
        for activity in Activity<ClassCountdownAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
