import SwiftUI

/// Full-screen countdown timer for a hold-for-time movement (plank, wall sit,
/// dead hang). It runs two phases back to back:
///
/// 1. **Prep** — a short "get ready" countdown (3 · 2 · 1) with a tick each
///    second so you can settle into position.
/// 2. **Hold** — a ring depletes and the clock counts the target time *down*
///    to zero. Reaching zero fires a success haptic and logs the set.
///
/// The lifter can only nudge the target while holding: **+15s** extends the
/// countdown, **−15s** trims it. Subtracting when 15 seconds or fewer remain
/// simply logs the set with the time held so far. The whole view is
/// self-contained — no session state — so it can be presented from anywhere the
/// target time is known.
struct HoldTimerView: View {
    let exerciseName: String
    /// The time to reach, in seconds.
    let targetSeconds: Double
    /// Called with the total seconds held when the countdown finishes or is cut
    /// short with the −15s button. Not called if the lifter cancels during prep.
    let onFinish: (Double) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Phase { case prep, hold }

    @State private var phase: Phase = .prep
    @State private var prepRemaining = 3
    /// Whole seconds elapsed since the hold began.
    @State private var elapsed = 0
    /// The countdown target in seconds, adjustable with the ±15s buttons.
    @State private var duration: Int

    init(exerciseName: String, targetSeconds: Double, onFinish: @escaping (Double) -> Void) {
        self.exerciseName = exerciseName
        self.targetSeconds = targetSeconds
        self.onFinish = onFinish
        _duration = State(initialValue: max(1, Int(targetSeconds.rounded())))
    }

    /// Seconds still to hold.
    private var remaining: Int { max(0, duration - elapsed) }

    var body: some View {
        VStack(spacing: 28) {
            header
            Spacer()
            timerRing
            phaseCaption
            Spacer()
            controls
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .obsidianBackground()
        .keepScreenAwake()
        .task { await run() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Text(exerciseName)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
            Text("TARGET \(Double(duration).clockString)")
                .font(.caption.weight(.bold))
                .kerning(1.5)
                .foregroundStyle(Theme.textDim)
                .contentTransition(.numericText())
                .animation(.snappy, value: duration)
        }
    }

    // MARK: - Ring

    private var ringProgress: Double {
        switch phase {
        case .prep: return 0
        case .hold: return Double(remaining) / Double(duration)
        }
    }

    private var accent: Color { Theme.emerald }

    private var timerRing: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: 14)
            Circle()
                .trim(from: 0, to: ringProgress)
                .stroke(accent, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: ringProgress)
                .shadow(color: accent.opacity(0.5), radius: 12)

            VStack(spacing: 4) {
                Text(clockText)
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: phase == .hold))
                    .animation(.snappy, value: clockText)
                if phase == .prep {
                    Text("GET READY")
                        .font(.caption.weight(.bold))
                        .kerning(2)
                        .foregroundStyle(Theme.textDim)
                }
            }
        }
        .frame(width: 260, height: 260)
    }

    private var clockText: String {
        switch phase {
        case .prep: return "\(max(0, prepRemaining))"
        case .hold: return Double(remaining).clockString
        }
    }

    // MARK: - Caption

    @ViewBuilder
    private var phaseCaption: some View {
        switch phase {
        case .prep:
            Text("Settling in…")
                .font(.subheadline)
                .foregroundStyle(Theme.textDim)
        case .hold:
            Text("Hold to the target")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.emerald)
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        if phase == .prep {
            Button {
                Haptics.shared.tick()
                dismiss()
            } label: {
                Text("CANCEL")
                    .font(.headline)
                    .kerning(1.5)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .foregroundStyle(.white)
                    .glassCTA(tint: Theme.crimson.opacity(0.6))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel timer")
        } else {
            HStack(spacing: 14) {
                adjustButton(title: "−15s", tint: Theme.crimson, action: subtract)
                adjustButton(title: "+15s", tint: Theme.emerald, action: add)
            }
        }
    }

    private func adjustButton(title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .kerning(1.5)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .foregroundStyle(.white)
                .glassCTA(tint: tint.opacity(0.7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title == "+15s" ? "Add fifteen seconds" : "Subtract fifteen seconds")
    }

    private func add() {
        Haptics.shared.tick()
        withAnimation(.snappy) { duration += 15 }
    }

    private func subtract() {
        // With 15 seconds or fewer to go, trimming just finishes the hold.
        if remaining <= 15 {
            finish()
        } else {
            Haptics.shared.tick()
            withAnimation(.snappy) { duration -= 15 }
        }
    }

    // MARK: - Finish

    /// Log the time held so far and close the timer.
    private func finish() {
        onFinish(Double(elapsed))
        Haptics.shared.success()
        dismiss()
    }

    // MARK: - Clock loop

    private func run() async {
        // Prep countdown: 3 · 2 · 1.
        while prepRemaining > 0 {
            Haptics.shared.tick()
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            prepRemaining -= 1
        }

        // Hold: count down to zero, then log the set.
        withAnimation(.snappy) { phase = .hold }
        while elapsed < duration {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            elapsed += 1
        }

        finish()
    }
}

// MARK: - Keep screen awake

extension View {
    /// Disables the system idle timer while the view is on screen so the display
    /// won't dim or sleep mid-countdown, then restores it on disappear. Use for
    /// timer surfaces where the lifter needs to tap without waking the screen.
    func keepScreenAwake() -> some View {
        onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}
