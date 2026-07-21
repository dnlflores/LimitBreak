import SwiftUI

/// Non-intrusive rest countdown pinned above the tab bar during a session.
struct RestTimerOverlay: View {
    @Environment(WorkoutManager.self) private var workout

    private var progress: Double {
        workout.restTotal > 0 ? workout.restRemaining / workout.restTotal : 0
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Theme.emerald, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: progress)
                Image(systemName: "timer")
                    .font(.caption)
                    .foregroundStyle(Theme.emerald)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 1) {
                Text("REST")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textDim)
                    .kerning(1)
                Text(workout.restRemaining.clockString)
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.default, value: workout.restRemaining)
            }

            Spacer()

            Button("+15s") {
                workout.addRest(seconds: 15)
                Haptics.shared.tick()
            }
            .font(.caption.weight(.bold))
            .buttonStyle(.glass)
            .tint(Theme.violet)

            Button("Skip") {
                workout.stopRest()
            }
            .font(.caption.weight(.bold))
            .buttonStyle(.glass)
            .tint(Theme.coral)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}
