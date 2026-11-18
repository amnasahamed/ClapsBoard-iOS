//
//  ClapsBoardLiveActivitiesBundle.swift
//  ClapsBoardLiveActivities
//

import ActivityKit
import SwiftUI
import WidgetKit

@main
struct ClapsBoardLiveActivitiesBundle: WidgetBundle {
    var body: some Widget {
        ClassCountdownLiveActivity()
    }
}

// Live Activities are rendered as snapshots: `TimelineView(.animation)` does not
// tick on the Lock Screen or in the Dynamic Island, so anything driven by it
// froze at the moment of the last update. Everything time-dependent here uses
// views the system advances itself (`Text(timerInterval:)`,
// `ProgressView(timerInterval:)`), and `context.isStale` — the app sets the
// stale date to the class start — switches the layout to its "started" state.
struct ClassCountdownLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ClassCountdownAttributes.self) { context in
            LockScreenCountdownView(state: context.state, hasStarted: context.isStale)
                .activityBackgroundTint(CountdownPalette.activityBackground)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandBadge(title: "Class")
                }

                DynamicIslandExpandedRegion(.trailing) {
                    CountdownPill(scheduledStart: context.state.scheduledStart, hasStarted: context.isStale, compact: false)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedIslandClassView(state: context.state, hasStarted: context.isStale)
                }
            } compactLeading: {
                LiveActivityIconView(size: 20, cornerRadius: 6, glow: 0.28, showsEdgeLight: false)
            } compactTrailing: {
                CountdownPill(scheduledStart: context.state.scheduledStart, hasStarted: context.isStale, compact: true)
            } minimal: {
                LiveActivityIconView(size: 22, cornerRadius: 7, glow: 0.36, showsEdgeLight: false)
            }
            .keylineTint(CountdownPalette.primaryBlue.opacity(0.72))
        }
    }
}

private struct LockScreenCountdownView: View {
    let state: ClassCountdownAttributes.ContentState
    let hasStarted: Bool

    var body: some View {
        HStack(spacing: 10) {
            LiveActivityIconView(
                size: 42,
                cornerRadius: 13,
                glow: 0.5,
                showsEdgeLight: true
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(hasStarted ? "Class" : "Upcoming class")
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(CountdownPalette.paleBlue.opacity(0.82))
                    .lineLimit(1)

                Text(state.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text(hasStarted ? "Starting now" : "Starts at \(state.scheduledStart.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            CountdownPill(scheduledStart: state.scheduledStart, hasStarted: hasStarted, compact: false)
        }
        .padding(.top, 12)
        .padding(.horizontal, 14)
        .padding(.bottom, 13)
        .background {
            FrostedActivitySurface(glow: 0.5, urgency: hasStarted ? 1 : 0)
        }
        .overlay(alignment: .bottom) {
            CountdownProgressStrip(scheduledStart: state.scheduledStart, hasStarted: hasStarted)
                .padding(.horizontal, 16)
                .padding(.bottom, 1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Counts down by itself; the system redraws it every second without the app
/// or the widget extension running.
private struct CountdownText: View {
    let scheduledStart: Date
    let hasStarted: Bool

    var body: some View {
        let now = Date()
        if !hasStarted, scheduledStart > now {
            Text(timerInterval: now...scheduledStart, countsDown: true)
        } else {
            Text("Now")
        }
    }
}

private struct ExpandedIslandClassView: View {
    let state: ClassCountdownAttributes.ContentState
    let hasStarted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                LiveActivityIconView(size: 28, cornerRadius: 9, glow: 0.35, showsEdgeLight: true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(hasStarted ? "Class" : "Upcoming class")
                        .font(.caption2.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(CountdownPalette.paleBlue.opacity(0.78))

                    Text(state.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(hasStarted ? "Now" : state.scheduledStart.formatted(date: .omitted, time: .shortened))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CountdownPalette.paleBlue)
                    .lineLimit(1)
            }

            CountdownProgressStrip(scheduledStart: state.scheduledStart, hasStarted: hasStarted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }
}

private struct IslandBadge: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            LiveActivityIconView(size: 20, cornerRadius: 6, glow: 0.22, showsEdgeLight: false)

            Text(title)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            Capsule()
                .fill(CountdownPalette.blue.opacity(0.18))
                .overlay {
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .opacity(0.18)
                }
                .overlay {
                    Capsule()
                        .stroke(CountdownPalette.paleBlue.opacity(0.24), lineWidth: 0.6)
                }
        }
        .accessibilityLabel(title)
    }
}

private struct CountdownPill: View {
    let scheduledStart: Date
    let hasStarted: Bool
    let compact: Bool

    var body: some View {
        CountdownText(scheduledStart: scheduledStart, hasStarted: hasStarted)
            .font(compact ? .caption2.monospacedDigit().weight(.semibold) : .caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.76)
            // A timer text otherwise takes all the width it is offered.
            .multilineTextAlignment(compact ? .trailing : .center)
            .padding(.horizontal, compact ? 0 : 11)
            .padding(.vertical, compact ? 0 : 6)
            .frame(maxWidth: compact ? 45 : 76, alignment: compact ? .trailing : .center)
            .background {
                if !compact {
                    Capsule()
                        .fill(CountdownPalette.chipFill)
                        .overlay {
                            Capsule()
                                .fill(.ultraThinMaterial)
                                .opacity(0.16)
                        }
                        .overlay {
                            Capsule()
                                .stroke(CountdownPalette.chipEdge, lineWidth: 0.7)
                        }
                        .shadow(color: CountdownPalette.primaryBlue.opacity(hasStarted ? 0.38 : 0.18), radius: hasStarted ? 14 : 10, x: 0, y: 3)
                }
            }
            .accessibilityLabel("Class countdown")
    }
}

private struct LiveActivityIconView: View {
    let size: CGFloat
    let cornerRadius: CGFloat
    let glow: Double
    let showsEdgeLight: Bool

    var body: some View {
        Image("LiveActivityIcon")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(showsEdgeLight ? 0.16 : 0.08),
                                CountdownPalette.paleBlue.opacity(showsEdgeLight ? 0.10 : 0.04),
                                .clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .blendMode(.screen)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(showsEdgeLight ? 0.18 : 0.08), lineWidth: showsEdgeLight ? 0.7 : 0.4)
            }
            .shadow(color: CountdownPalette.primaryBlue.opacity(0.24 + (glow * 0.18)), radius: size * 0.26, x: 0, y: size * 0.08)
            .accessibilityHidden(true)
    }
}

private struct FrostedActivitySurface: View {
    let glow: Double
    let urgency: Double

    var body: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(CountdownPalette.surfaceGradient)
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.16)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                CountdownPalette.paleBlue.opacity(0.11 + (glow * 0.06) + (urgency * 0.05)),
                                .clear,
                                CountdownPalette.primaryBlue.opacity(0.04 + (urgency * 0.06))
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .blendMode(.screen)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.20),
                                CountdownPalette.paleBlue.opacity(0.18 + (urgency * 0.10)),
                                .white.opacity(0.04)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.65
                    )
            }
            .shadow(color: CountdownPalette.primaryBlue.opacity(0.12 + (glow * 0.06) + (urgency * 0.10)), radius: 18, x: 0, y: 7)
    }
}

/// Fills over the five minutes before class. `ProgressView(timerInterval:)`
/// is advanced by the system, so it keeps moving on the Lock Screen.
private struct CountdownProgressStrip: View {
    let scheduledStart: Date
    let hasStarted: Bool

    var body: some View {
        Group {
            if hasStarted || scheduledStart <= Date() {
                Capsule()
                    .fill(CountdownPalette.progressGradient)
                    .frame(height: 2)
            } else {
                ProgressView(
                    timerInterval: scheduledStart.addingTimeInterval(-CountdownPalette.countdownWindow)...scheduledStart,
                    countsDown: false,
                    label: { EmptyView() },
                    currentValueLabel: { EmptyView() }
                )
                .progressViewStyle(.linear)
                .tint(CountdownPalette.blue)
            }
        }
        .frame(height: 4)
        .accessibilityLabel("Time remaining until class starts")
    }
}

private enum CountdownPalette {
    static let countdownWindow: TimeInterval = 5 * 60
    static let activityBackground = Color(red: 0.043, green: 0.071, blue: 0.125)
    static let surface = Color(red: 0.067, green: 0.094, blue: 0.153)
    static let primaryBlue = Color(red: 0.231, green: 0.510, blue: 0.965)
    static let blue = Color(red: 0.376, green: 0.647, blue: 0.980)
    static let paleBlue = Color(red: 0.576, green: 0.773, blue: 0.992)

    static let surfaceGradient = LinearGradient(
        colors: [
            activityBackground.opacity(0.88),
            surface.opacity(0.82),
            activityBackground.opacity(0.90)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let chipFill = LinearGradient(
        colors: [
            .white.opacity(0.15),
            blue.opacity(0.16),
            activityBackground.opacity(0.34)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let chipEdge = LinearGradient(
        colors: [
            .white.opacity(0.24),
            paleBlue.opacity(0.28),
            .white.opacity(0.06)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let progressGradient = LinearGradient(
        colors: [
            primaryBlue.opacity(0.58),
            blue,
            paleBlue
        ],
        startPoint: .leading,
        endPoint: .trailing
    )
}
