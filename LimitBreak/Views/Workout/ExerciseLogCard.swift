import SwiftUI

/// Per-exercise logging card. Collapsed, it shows just the exercise name and the
/// Log Set button. Tapping the name expands the card into one input row per rep —
/// each row carries that rep's weight (or duration), and rows can be added or
/// removed freely. The per-rep values are stored on the set for later calculation.
struct ExerciseLogCard: View {
    @Environment(WorkoutManager.self) private var workout
    let exercise: Exercise

    @State private var repRows: [RepRow] = []
    @State private var durationSeconds: Double = 30
    @State private var distanceMeters: Double = 1600
    @State private var isWarmup = false
    @State private var isExpanded = false
    @State private var didPrefill = false

    /// One editable rep. `value` is weight in lbs for weight-based types, or
    /// seconds for duration-based types.
    private struct RepRow: Identifiable {
        let id = UUID()
        var value: Double
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            loggedSets
            if isExpanded {
                expandedInputs
            }
            logButton
        }
        .cardStyle()
        .onAppear(perform: prefillFromHistory)
    }

    // MARK: - Header

    private var header: some View {
        Button {
            withAnimation(.snappy) { isExpanded.toggle() }
            Haptics.shared.tick()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(exercise.name)
                            .font(.headline)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.textDim)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var showsOneRM: Bool {
        guard usesRepRows else { return false }
        return exercise.trackingType == .weightAndReps ||
            (exercise.trackingType == .bodyweightAndReps && liveAvgWeight > 0)
    }

    private var liveOneRepMax: Double {
        exercise.formula.estimate(weight: liveAvgWeight, reps: liveReps)
    }

    /// Live preview: would committing these rows shatter the current ceiling?
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

    /// Rep-row logging applies to every rep-based type; time/distance keeps dials.
    private var usesRepRows: Bool {
        exercise.trackingType != .timeAndDistance
    }

    @ViewBuilder
    private var expandedInputs: some View {
        if usesRepRows {
            repRowInputs
        } else {
            HapticDial(label: "TIME", value: $durationSeconds, step: 15, unit: "sec")
            HapticDial(label: "DISTANCE", value: $distanceMeters, step: 100, unit: "m")
        }
        warmupAndQuickFill
    }

    private var repRowInputs: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(rowSectionTitle)
                .font(.caption2.weight(.semibold))
                .kerning(0.5)
                .foregroundStyle(Theme.textDim)

            ForEach(Array(repRows.enumerated()), id: \.element.id) { index, row in
                RepInputRow(
                    index: index,
                    value: $repRows[index].value,
                    step: rowStep,
                    canDelete: repRows.count > 1,
                    onDelete: { deleteRow(row.id) }
                )
            }

            Button(action: addRow) {
                Label("Add Rep", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.emerald)
            .padding(.top, 2)
        }
    }

    private var warmupAndQuickFill: some View {
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

    private var rowSectionTitle: String {
        switch exercise.trackingType {
        case .weightAndReps:      return "WEIGHT PER REP · LBS"
        case .bodyweightAndReps:  return "ADDED WEIGHT PER REP · LBS"
        case .durationAndReps:    return "DURATION PER REP · SEC"
        case .customMetric:       return "\((exercise.customMetricUnit ?? "VALUE").uppercased()) PER REP"
        case .timeAndDistance:    return ""
        }
    }

    private var rowStep: Double {
        switch exercise.trackingType {
        case .durationAndReps: return 5
        default:               return exercise.defaultIncrement
        }
    }

    private var initialRowValue: Double {
        switch exercise.trackingType {
        case .weightAndReps:   return 45
        case .durationAndReps: return 30
        default:               return 0
        }
    }

    // MARK: - Live aggregates

    private var liveValues: [Double] { repRows.map(\.value) }

    private var liveReps: Int { repRows.count }

    /// Average of the per-rep values — reduces to the classic single weight when
    /// every row carries the same load, and generalises to mixed loads.
    private var liveAvgWeight: Double {
        guard !liveValues.isEmpty else { return 0 }
        return liveValues.reduce(0, +) / Double(liveValues.count)
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

    private func addRow() {
        let value = repRows.last?.value ?? initialRowValue
        withAnimation(.snappy) { repRows.append(RepRow(value: value)) }
        Haptics.shared.tick()
    }

    private func deleteRow(_ id: UUID) {
        guard repRows.count > 1 else { return }
        withAnimation(.snappy) { repRows.removeAll { $0.id == id } }
        Haptics.shared.tick()
    }

    private func logCurrentSet() {
        if usesRepRows {
            let values = liveValues
            guard !values.isEmpty else { return }
            switch exercise.trackingType {
            case .weightAndReps, .bodyweightAndReps, .customMetric:
                workout.logSet(exercise: exercise, weight: liveAvgWeight, reps: values.count, isWarmup: isWarmup, repWeights: values)
            case .durationAndReps:
                workout.logSet(exercise: exercise, weight: 0, reps: values.count, durationSeconds: liveAvgWeight, isWarmup: isWarmup, repWeights: values)
            case .timeAndDistance:
                break
            }
        } else {
            workout.logSet(exercise: exercise, weight: 0, reps: 1, durationSeconds: durationSeconds, distanceMeters: distanceMeters, isWarmup: isWarmup)
        }
        isWarmup = false
    }

    private func quickFill() {
        guard let last = workout.lastSet(for: exercise) else { return }
        if usesRepRows {
            repRows = rows(from: last)
        } else {
            if let duration = last.durationSeconds { durationSeconds = duration }
            if let distance = last.distanceMeters { distanceMeters = distance }
        }
        Haptics.shared.tick()
    }

    /// Seed inputs from the most recent historical set of this exercise.
    private func prefillFromHistory() {
        guard !didPrefill else { return }
        didPrefill = true
        let historical = exercise.sets.max(by: { $0.timestamp < $1.timestamp })
        if usesRepRows {
            repRows = historical.map(rows(from:)) ?? [RepRow(value: initialRowValue)]
        } else if let historical {
            if let duration = historical.durationSeconds { durationSeconds = duration }
            if let distance = historical.distanceMeters { distanceMeters = distance }
        }
        if repRows.isEmpty { repRows = [RepRow(value: initialRowValue)] }
    }

    /// Rebuild editable rows from a stored set: prefer its saved per-rep values,
    /// otherwise expand its single weight/duration across `reps` identical rows.
    private func rows(from set: ExerciseSet) -> [RepRow] {
        if !set.repWeights.isEmpty {
            return set.repWeights.map { RepRow(value: $0) }
        }
        let value: Double
        switch exercise.trackingType {
        case .durationAndReps: value = set.durationSeconds ?? 0
        default:               value = set.weight
        }
        return (0..<max(1, set.reps)).map { _ in RepRow(value: value) }
    }
}

// MARK: - Rep input row

/// A single rep's input: index label, granular incrementer, and a delete button.
/// Tap the end buttons or drag across the value to adjust; each step fires a tick.
private struct RepInputRow: View {
    let index: Int
    @Binding var value: Double
    let step: Double
    let canDelete: Bool
    let onDelete: () -> Void

    @State private var dragAccumulator: CGFloat = 0
    @FocusState private var isEditing: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("REP \(index + 1)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.textDim)
                .kerning(0.5)
                .frame(width: 50, alignment: .leading)

            adjustButton(systemImage: "minus") { adjust(by: -step) }

            // Tap to type a value directly; drag horizontally to scrub.
            TextField("", value: $value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .monospacedDigit()
                .focused($isEditing)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { gesture in
                            let delta = gesture.translation.width - dragAccumulator
                            if abs(delta) >= 9 {
                                adjust(by: delta > 0 ? step : -step)
                                dragAccumulator = gesture.translation.width
                            }
                        }
                        .onEnded { _ in dragAccumulator = 0 }
                )
                .onChange(of: value) { _, newValue in
                    if newValue < 0 { value = 0 }
                }
                .toolbar {
                    if isEditing {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { isEditing = false }
                        }
                    }
                }

            adjustButton(systemImage: "plus") { adjust(by: step) }

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textDim)
            .opacity(canDelete ? 1 : 0)
            .disabled(!canDelete)
        }
    }

    private func adjustButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .frame(width: 40, height: 40)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
    }

    private func adjust(by delta: Double) {
        let newValue = max(0, value + delta)
        guard newValue != value else { return }
        value = newValue
        Haptics.shared.tick()
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
