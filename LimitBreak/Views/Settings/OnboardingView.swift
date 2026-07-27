import SwiftUI
import SwiftData

/// First-launch flow: asks what the lifter is training for, then offers the
/// smarter AI. Everything here is editable later in Settings, so nothing is
/// load-bearing — the flow can be dismissed at any point and the app works
/// with sensible defaults.
struct OnboardingView: View {
    @Environment(\.modelContext) private var modelContext
    let profile: TrainingProfile
    let onFinish: () -> Void

    @State private var step = 0
    @State private var goal: TrainingGoal = .buildMuscle
    @State private var experience: ExperienceLevel = .intermediate
    @State private var daysPerWeek = 4

    private let stepCount = 3

    var body: some View {
        VStack(spacing: 0) {
            progressBar

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch step {
                    case 0: goalStep
                    case 1: experienceStep
                    default: aiStep
                    }
                }
                .padding()
            }

            actionBar
        }
        .obsidianBackground()
    }

    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(0..<stepCount, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? AnyShapeStyle(Theme.emerald) : AnyShapeStyle(Theme.surfaceRaised))
                    .frame(height: 4)
            }
        }
        .padding(.horizontal)
        .padding(.top, 20)
        .animation(.snappy, value: step)
    }

    // MARK: - Steps

    private var goalStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            header(
                icon: "target",
                title: "What are you training for?",
                subtitle: "This shapes your rep ranges, rest, and how hard the coach pushes your loads."
            )
            VStack(spacing: 8) {
                ForEach(TrainingGoal.allCases) { option in
                    choiceRow(
                        title: option.rawValue,
                        blurb: option.blurb,
                        icon: option.icon,
                        isSelected: goal == option
                    ) { goal = option }
                }
            }
        }
    }

    private var experienceStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            header(
                icon: "chart.line.uptrend.xyaxis",
                title: "How long have you been lifting?",
                subtitle: "Keeps the movement selection appropriate for where you are."
            )
            VStack(spacing: 8) {
                ForEach(ExperienceLevel.allCases) { option in
                    choiceRow(
                        title: option.rawValue,
                        blurb: option.blurb,
                        icon: nil,
                        isSelected: experience == option
                    ) { experience = option }
                }
            }

            Text("HOW MANY DAYS A WEEK?")
                .font(.caption.weight(.bold))
                .kerning(1)
                .foregroundStyle(Theme.textDim)
                .padding(.top, 6)

            HStack(spacing: 8) {
                ForEach(2...6, id: \.self) { days in
                    let selected = daysPerWeek == days
                    Button {
                        daysPerWeek = days
                        Haptics.shared.tick()
                    } label: {
                        Text("\(days)")
                            .font(.headline)
                            .monospacedDigit()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundStyle(selected ? .black : .white)
                            .background(
                                selected ? AnyShapeStyle(Theme.emerald) : AnyShapeStyle(Theme.surfaceRaised),
                                in: RoundedRectangle(cornerRadius: 12)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var aiStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            header(
                icon: "sparkles",
                title: "Want a smarter coach?",
                subtitle: "LimitBreak builds workouts on your device by default. Connect an Anthropic API key and it can do considerably more."
            )

            VStack(alignment: .leading, spacing: 10) {
                capability("Reads your muscle fatigue and steers around what needs rest")
                capability("Pairs muscle groups that belong in the same session")
                capability("Tailors rep ranges and loads to your goal")
                capability("Prescribes real working weights from your recorded lifts")
            }
            .cardStyle()

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.teal)
                Text("You can turn this on any time in Settings — it needs your own API key, "
                     + "and it sends your training data to Anthropic when generating a plan. "
                     + "Everything works offline without it.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textDim)
            }
            .padding(10)
            .background(Theme.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Chrome

    private func header(icon: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(Theme.limitBreakGradient)
                .padding(.top, 8)
            Text(title)
                .font(.title.bold())
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(Theme.textDim)
        }
    }

    private func capability(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Theme.emerald)
            Text(text)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            Button {
                advance()
            } label: {
                Text(step == stepCount - 1 ? "START TRAINING" : "CONTINUE")
                    .font(.headline)
                    .kerning(1.5)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .foregroundStyle(.white)
                    .glassCTA(tint: Theme.emerald.opacity(0.85))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if step < stepCount - 1 {
                Button("Skip setup") { finish() }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textDim)
                    .buttonStyle(.plain)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private func advance() {
        Haptics.shared.tick()
        if step < stepCount - 1 {
            withAnimation(.snappy) { step += 1 }
        } else {
            finish()
        }
    }

    /// Persists whatever has been chosen so far. Cloud AI stays off — turning
    /// it on requires a key, which belongs in Settings rather than in the way
    /// of a first workout.
    private func finish() {
        profile.goal = goal
        profile.experience = experience
        profile.daysPerWeek = daysPerWeek
        profile.hasCompletedOnboarding = true
        try? modelContext.save()
        Haptics.shared.success()
        onFinish()
    }

    private func choiceRow(
        title: String,
        blurb: String,
        icon: String?,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            Haptics.shared.tick()
        } label: {
            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .font(.subheadline)
                        .foregroundStyle(isSelected ? .black : Theme.emerald)
                        .frame(width: 24)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(blurb)
                        .font(.caption2)
                        .foregroundStyle(isSelected ? .black.opacity(0.7) : Theme.textDim)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.black)
                }
            }
            .padding(12)
            .foregroundStyle(isSelected ? .black : .white)
            .background(
                isSelected ? AnyShapeStyle(Theme.emerald) : AnyShapeStyle(Theme.surfaceRaised),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}
