import SwiftUI

/// Per-exercise logging card: haptic dial controls, quick-fill, live e1RM readout.
struct ExerciseLogCard: View {
    @Environment(WorkoutManager.self) private var workout
    let exercise: Exercise

    @State private var weight: Double = 0
    @State private var reps: Int = 8
    @State private var durationSeconds: Double = 30
    @State private var distanceMeters: Double = 1600
    @State private var isWarmup = false
    @State private var didPrefill = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            loggedSets
            inputControls
            logButton
        }
        .cardStyle()
        .onAppear(perform: prefillFromHistory)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.name)
                    .font(.headline)
                Text(exercise.muscleGroupRaw)
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }
            Spacer()
            if showsOneRM {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("e1RM")
                        .font(.caption2)
                        .foregroundStyle(Theme.textDim)
                    Text(liveOneRepMax.cleanWeight)
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(wouldLimitBreak ? Theme.gold : .primary)
                }
            }
        }
    }

    private var showsOneRM: Bool {
        exercise.trackingType == .weightAndReps ||
            (exercise.trackingType == .bodyweightAndReps && weight > 0)
    }

    private var liveOneRepMax: Double {
        exercise.formula.estimate(weight: weight, reps: reps)
    }

    /// Live preview: would committing this set shatter the current ceiling?
    private var wouldLimitBreak: Bool {
        showsOneRM && liveOneRepMax > exercise.ceiling(for: "1RM") && exercise.ceiling(for: "1RM") > 0
    }

    // MARK: - Logged sets

    @ViewBuilder
    private var loggedSets: some View {
        let sets = workout.sets(for: exercise)
        if !sets.isEmpty {
            VStack(spacing: 6) {
                ForEach(Array(sets.enumerated()), id: \.element.id) { index, set in
                    HStack {
                        Text("SET \(index + 1)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(set.isPR ? Theme.gold : Theme.textDim)
                            .frame(width: 44, alignment: .leading)
                        Text(setSummary(set))
                            .font(.subheadline)
                            .monospacedDigit()
                        Spacer()
                        if set.isPR {
                            Label("PR", systemImage: "crown.fill")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Theme.gold)
                        } else if set.isWarmup {
                            Text("warmup")
                                .font(.caption2)
                                .foregroundStyle(Theme.textDim)
                        }
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                    .background(
                        set.isPR ? Theme.gold.opacity(0.08) : Color.white.opacity(0.03),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }
            }
        }
    }

    private func setSummary(_ set: ExerciseSet) -> String {
        switch exercise.trackingType {
        case .weightAndReps:
            return "\(set.weight.cleanWeight) lbs × \(set.reps)"
        case .bodyweightAndReps:
            return set.weight > 0 ? "BW+\(set.weight.cleanWeight) × \(set.reps)" : "BW × \(set.reps)"
        case .durationAndReps:
            return "\((set.durationSeconds ?? 0).clockString) × \(set.reps)"
        case .timeAndDistance:
            return "\(Int(set.distanceMeters ?? 0)) m in \((set.durationSeconds ?? 0).clockString)"
        case .customMetric:
            return "\(set.weight.cleanWeight) \(exercise.customMetricUnit ?? "") × \(set.reps)"
        }
    }

    // MARK: - Inputs

    @ViewBuilder
    private var inputControls: some View {
        switch exercise.trackingType {
        case .weightAndReps:
            HapticDial(label: "WEIGHT", value: $weight, step: exercise.defaultIncrement, unit: "lbs")
            HapticDial(label: "REPS", value: repsBinding, step: 1, unit: "reps")
        case .bodyweightAndReps:
            HapticDial(label: "ADDED WEIGHT", value: $weight, step: exercise.defaultIncrement, unit: "lbs")
            HapticDial(label: "REPS", value: repsBinding, step: 1, unit: "reps")
        case .durationAndReps:
            HapticDial(label: "DURATION", value: $durationSeconds, step: 5, unit: "sec")
            HapticDial(label: "REPS", value: repsBinding, step: 1, unit: "reps")
        case .timeAndDistance:
            HapticDial(label: "TIME", value: $durationSeconds, step: 15, unit: "sec")
            HapticDial(label: "DISTANCE", value: $distanceMeters, step: 100, unit: "m")
        case .customMetric:
            HapticDial(label: exercise.customMetricUnit?.uppercased() ?? "VALUE", value: $weight, step: exercise.defaultIncrement, unit: exercise.customMetricUnit ?? "")
            HapticDial(label: "REPS", value: repsBinding, step: 1, unit: "reps")
        }

        HStack {
            Toggle(isOn: $isWarmup) {
                Text("Warmup")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }
            .toggleStyle(.button)
            .tint(Theme.violet)

            Spacer()

            if workout.lastSet(for: exercise) != nil {
                Button {
                    quickFill()
                } label: {
                    Label("Quick-Fill", systemImage: "arrow.counterclockwise")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(Theme.emerald)
            }
        }
    }

    private var repsBinding: Binding<Double> {
        Binding(get: { Double(reps) }, set: { reps = Int($0) })
    }

    // MARK: - Actions

    private var logButton: some View {
        Button {
            logCurrentSet()
        } label: {
            Text(isWarmup ? "LOG WARMUP" : "LOG SET")
                .font(.subheadline.weight(.bold))
                .kerning(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    wouldLimitBreak ? AnyShapeStyle(Theme.limitBreakGradient) : AnyShapeStyle(Theme.emerald),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .foregroundStyle(.black)
        }
    }

    private func logCurrentSet() {
        switch exercise.trackingType {
        case .weightAndReps, .bodyweightAndReps:
            workout.logSet(exercise: exercise, weight: weight, reps: reps, isWarmup: isWarmup)
        case .durationAndReps:
            workout.logSet(exercise: exercise, weight: 0, reps: reps, durationSeconds: durationSeconds, isWarmup: isWarmup)
        case .timeAndDistance:
            workout.logSet(exercise: exercise, weight: 0, reps: 1, durationSeconds: durationSeconds, distanceMeters: distanceMeters, isWarmup: isWarmup)
        case .customMetric:
            workout.logSet(exercise: exercise, weight: weight, reps: reps, isWarmup: isWarmup)
        }
        isWarmup = false
    }

    private func quickFill() {
        guard let last = workout.lastSet(for: exercise) else { return }
        weight = last.weight
        reps = last.reps
        if let duration = last.durationSeconds { durationSeconds = duration }
        if let distance = last.distanceMeters { distanceMeters = distance }
        Haptics.shared.tick()
    }

    /// Seed inputs from the most recent historical set of this exercise.
    private func prefillFromHistory() {
        guard !didPrefill else { return }
        didPrefill = true
        let historical = exercise.sets.max(by: { $0.timestamp < $1.timestamp })
        if let historical {
            weight = historical.weight
            reps = historical.reps
            if let duration = historical.durationSeconds { durationSeconds = duration }
            if let distance = historical.distanceMeters { distanceMeters = distance }
        } else if exercise.trackingType == .weightAndReps {
            weight = 45
        }
    }
}

// MARK: - Haptic dial control

/// Granular incrementer: tap the end buttons or drag across the track.
/// Every step change fires a haptic tick.
struct HapticDial: View {
    let label: String
    @Binding var value: Double
    let step: Double
    let unit: String

    @State private var dragAccumulator: CGFloat = 0

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textDim)
                .kerning(0.5)
                .frame(width: 78, alignment: .leading)

            dialButton(systemImage: "minus") { adjust(by: -step) }

            GeometryReader { _ in
                Text("\(value.cleanWeight)")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { gesture in
                                let delta = gesture.translation.width - dragAccumulator
                                if abs(delta) >= 9 {
                                    adjust(by: delta > 0 ? step : -step)
                                    dragAccumulator = gesture.translation.width
                                }
                            }
                            .onEnded { _ in dragAccumulator = 0 }
                    )
            }
            .frame(height: 40)

            dialButton(systemImage: "plus") { adjust(by: step) }
        }
    }

    private func dialButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .frame(width: 40, height: 40)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.primary)
        }
        .buttonRepeatBehavior(.enabled)
    }

    private func adjust(by delta: Double) {
        let newValue = max(0, value + delta)
        guard newValue != value else { return }
        value = newValue
        Haptics.shared.tick()
    }
}
