//
//  ClassCountdownLiveActivityCoordinator.swift
//  ClapsBoard
//
//  Starts a local Live Activity when a class is inside the five-minute countdown window.
//

import ActivityKit
import Foundation
import UIKit

@MainActor
final class ClassCountdownLiveActivityCoordinator: ObservableObject {
    nonisolated static let countdownWindow: TimeInterval = 5 * 60

    /// How long the "Starting now" state stays up after class start before the
    /// system removes the activity.
    nonisolated static let lingerAfterStart: TimeInterval = 3 * 60

    private var timer: Timer?
    private var sessions: [ClassSession] = []
    /// Reconciles run one at a time. Two overlapping runs could both see "no
    /// activity yet" and each request one, leaving a duplicate on the Lock Screen.
    private var isReconciling = false
    private var needsAnotherReconcile = false
    /// Activities whose end has already been scheduled with the system.
    private var scheduledEndActivityIDs: Set<String> = []

    private var backgroundObserver: NSObjectProtocol?

    init() {
        // Once the app leaves the foreground it can be suspended and may never
        // get to end the countdown itself, so hand the ending to the system then.
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleEndsForBackground()
            }
        }
    }

    deinit {
        timer?.invalidate()
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
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

        // Already running: remember to run once more with the latest sessions.
        guard !isReconciling else {
            needsAnotherReconcile = true
            return
        }
        isReconciling = true
        Task {
            repeat {
                needsAnotherReconcile = false
                await reconcileActivities(with: sessions)
            } while needsAnotherReconcile
            isReconciling = false
        }
    }

    @available(iOS 16.2, *)
    private func reconcileActivities(with sessions: [ClassSession]) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            await endAllActivities()
            return
        }

        guard let candidate = Self.countdownCandidate(from: sessions) else {
            // No class in the countdown window. Activities whose end is already
            // scheduled are left to the system, so "Starting now" stays for its
            // few minutes; anything else (deleted or completed class) ends now.
            let now = Date()
            for activity in Activity<ClassCountdownAttributes>.activities {
                let session = sessions.first { $0.id == activity.attributes.classId }
                let justStarted = session.map {
                    !$0.isCompleted && $0.date <= now && now.timeIntervalSince($0.date) < Self.lingerAfterStart
                } ?? false
                if justStarted, scheduledEndActivityIDs.contains(activity.id) { continue }
                await activity.end(nil, dismissalPolicy: .immediate)
                scheduledEndActivityIDs.remove(activity.id)
            }
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
        // Stale exactly at class start: the widget uses `isStale` to switch to
        // its "Starting now" look without the app having to run.
        let content = ActivityContent(state: state, staleDate: candidate.date)

        if let existing = activeActivities.first(where: { $0.attributes.classId == candidate.id }) {
            // Only touch it when something changed (title or time edited);
            // an update would cancel the end already scheduled below.
            guard existing.content.state != state else { return }
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

    /// Called when the app enters the background. Ending with a dismissal date
    /// lets the system keep the countdown on the Lock Screen, mark it stale at
    /// class start ("Starting now") and remove it a few minutes later, even if
    /// ClapsBoard never runs again. Previously it sat at 0:00 until the app was
    /// next opened. Trade-off: an ended activity leaves the Dynamic Island, so
    /// while the app is in the background the countdown is Lock Screen only.
    private func scheduleEndsForBackground() {
        guard #available(iOS 16.2, *) else { return }
        for activity in Activity<ClassCountdownAttributes>.activities
        where activity.activityState == .active || activity.activityState == .stale {
            guard !scheduledEndActivityIDs.contains(activity.id) else { continue }
            guard let session = sessions.first(where: { $0.id == activity.attributes.classId }), !session.isCompleted else {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
                continue
            }
            scheduledEndActivityIDs.insert(activity.id)
            let finalContent = ActivityContent(state: activity.content.state, staleDate: session.date)
            let dismissal = session.date.addingTimeInterval(Self.lingerAfterStart)
            Task {
                await activity.end(finalContent, dismissalPolicy: .after(dismissal))
            }
        }
    }

    @available(iOS 16.2, *)
    private func endAllActivities() async {
        for activity in Activity<ClassCountdownAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
