import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Live Activity for an active LimitBreak session: lock-screen card and
/// Dynamic Island, both with a LOG SET button that checks off the next
/// planned set in exercise order (same semantics as the watch app).
struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(LBColor.background.opacity(0.85))
                .activitySystemActionForegroundColor(LBColor.emerald)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "bolt.fill")
                        .font(.title2)
                        .foregroundStyle(LBColor.limitBreakGradient)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.exerciseName)
                            .font(.subheadline.weight(.bold))
                            .lineLimit(1)
                        Text(progressLine(context.state))
                            .font(.caption2)
                            .foregroundStyle(LBColor.dim)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    setDots(context.state)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    bottomRow(context.state)
                }
            } compactLeading: {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(LBColor.gold)
            } compactTrailing: {
                Text("\(context.state.totalDone)/\(context.state.totalTarget)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(LBColor.emerald)
            } minimal: {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(LBColor.gold)
            }
        }
    }

    private func progressLine(_ state: SessionActivityAttributes.ContentState) -> String {
        state.isComplete
            ? "All sets complete"
            : "Set \(min(state.exerciseDone + 1, state.exerciseTarget)) of \(state.exerciseTarget) · \(state.totalDone)/\(state.totalTarget) total"
    }

    @ViewBuilder
    private func setDots(_ state: SessionActivityAttributes.ContentState) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<max(state.exerciseTarget, 1), id: \.self) { index in
                Circle()
                    .fill(index < state.exerciseDone ? LBColor.emerald : Color.white.opacity(0.15))
                    .frame(width: 6, height: 6)
            }
        }
    }

    @ViewBuilder
    private func bottomRow(_ state: SessionActivityAttributes.ContentState) -> some View {
        HStack(spacing: 10) {
            if let restEndsAt = state.restEndsAt, restEndsAt > Date() {
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                        .font(.caption)
                    Text(timerInterval: Date()...restEndsAt, countsDown: true)
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .frame(maxWidth: 50)
                }
                .foregroundStyle(LBColor.teal)
            }

            Spacer()

            if !state.isComplete {
                Button(intent: LogNextSetIntent()) {
                    Label("LOG SET", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .tint(LBColor.emerald)
                .buttonStyle(.borderedProminent)
                .foregroundStyle(.black)
            }
        }
    }
}

// MARK: - Lock screen

private struct LockScreenView: View {
    let context: ActivityViewContext<SessionActivityAttributes>

    private var state: SessionActivityAttributes.ContentState { context.state }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.fill")
                .font(.title2)
                .foregroundStyle(LBColor.limitBreakGradient)
                .frame(width: 40, height: 40)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 3) {
                Text(context.attributes.sessionName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(LBColor.dim)
                    .lineLimit(1)
                Text(state.exerciseName)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    ForEach(0..<max(state.exerciseTarget, 1), id: \.self) { index in
                        Capsule()
                            .fill(index < state.exerciseDone ? LBColor.emerald : Color.white.opacity(0.15))
                            .frame(width: 14, height: 4)
                    }
                    if let restEndsAt = state.restEndsAt, restEndsAt > Date() {
                        Text(timerInterval: Date()...restEndsAt, countsDown: true)
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(LBColor.teal)
                            .frame(maxWidth: 44, alignment: .leading)
                    }
                }
            }

            Spacer()

            if state.isComplete {
                Label("Done", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(LBColor.emerald)
            } else {
                Button(intent: LogNextSetIntent()) {
                    Label("LOG SET", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                }
                .tint(LBColor.emerald)
                .buttonStyle(.borderedProminent)
                .foregroundStyle(.black)
            }
        }
        .padding(14)
    }
}
