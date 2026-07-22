import SwiftUI

/// Per-exercise logging card built around planned set rows.
///
/// Expanded, the card lists every set: checked-off sets show their summary
/// with a crown for PRs and a tappable check to undo; upcoming sets are dim
/// placeholders. One big value pair below the rows edits whatever LOG SET
/// will record next. Collapsed, the card shows a compact progress strip, and
/// Replace/Remove controls cover mid-session pivots.
struct ExerciseLogCard: View {
    @Environment(WorkoutManager.self) private var workout
    let exercise: Exercise

    @State private var drafts: [SetDraft] = []
    @State private var isWarmup = false
    @State private var isExpanded = false
    @State private var didPrefill = false
    @State private var showReplacePicker = false
    @State private var showRemoveConfirmation = false

    /// One planned set. `primary` is weight (lbs) for weight-based types,
    /// seconds for duration-based types, or the custom-metric value.
    /// `loggedSet` links the persisted record once the set is checked off.
    private struct SetDraft: Identifiable {
        let id = UUID()
        var primary: Double
        var reps: Int
        var distance: Double = 1600
        var loggedSet: ExerciseSet?

        var isLogged: Bool { loggedSet != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if isExpanded {
                setRows
                nextSetInputs
                addSetButton
                warmupToggle
                logButton
                sessionActions
            } else {
                progressStrip
            }
        }
        .cardStyle()
        .onAppear(perform: initialSetup)
        .onChange(of: workout.sets(for: exercise).count) {
            // Sets can arrive from the watch or the Live Activity button;
            // fold them into the planned rows so the card stays in step.
            adoptLoggedSets()
        }
        .sheet(isPresented: $showReplacePicker) {
            ExercisePickerSheet { replacement in
                workout.replaceExercise(exercise, with: replacement)
            }
        }
        .confirmationDialog(
            "Remove \(exercise.name)?",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Exercise", role: .destructive) {
                workout.removeExercise(exercise)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let logged = loggedCount
            Text(logged > 0
                ? "This also deletes the \(logged) set\(logged == 1 ? "" : "s") you logged for it in this session."
                : "Removes this movement from the session.")
        }
    }

    // MARK: - Derived state

    private var loggedCount: Int { drafts.filter(\.isLogged).count }

    private var nextPendingIndex: Int? { drafts.firstIndex { !$0.isLogged } }

    private var nextPending: SetDraft? { nextPendingIndex.map { drafts[$0] } }

    /// Body weight factored into bodyweight/assisted movements (Health first,
    /// manual fallback), matching what WorkoutManager will stamp on the set.
    private var bodyWeight: Double? {
        guard exercise.trackingType == .bodyweightAndReps || exercise.isAssisted else { return nil }
        return HealthKitManager.shared.currentBodyWeightLbs
    }

    private var showsOneRM: Bool {
        guard let next = nextPending else { return false }
        switch exercise.trackingType {
        case .weightAndReps: return next.primary + (bodyWeight ?? 0) > 0
        case .bodyweightAndReps: return next.primary > 0 || bodyWeight != nil
        default: return false
        }
    }

    private var liveOneRepMax: Double {
        guard let next = nextPending else { return 0 }
        return exercise.formula.estimate(weight: next.primary + (bodyWeight ?? 0), reps: next.reps)
    }

    /// Live preview: would checking off the next set shatter the ceiling?
    private var wouldLimitBreak: Bool {
        showsOneRM && liveOneRepMax > exercise.ceiling(for: "1RM") && exercise.ceiling(for: "1RM") > 0
    }

    // MARK: - Header

    private var header: some View {
        Button {
            withAnimation(.snappy) { isExpanded.toggle() }
            Haptics.shared.tick()
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(exercise.name)
                            .font(.headline)
                            .multilineTextAlignment(.leading)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.textDim)
                            .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    }
                    Text(exercise.muscleGroupRaw)
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                }
                Spacer()
                if isExpanded && showsOneRM {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("e1RM")
                            .font(.caption)
                            .foregroundStyle(Theme.textDim)
                        Text(liveOneRepMax.cleanWeight)
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(wouldLimitBreak ? Theme.gold : .primary)
                    }
                } else if !isExpanded {
                    Text("\(loggedCount)/\(drafts.count)")
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(loggedCount == drafts.count && !drafts.isEmpty ? Theme.emerald : Theme.textDim)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Collapsed progress

    /// Visual march through the planned sets: one segment per set, filled as
    /// each one is checked off (gold when it minted a PR).
    private var progressStrip: some View {
        HStack(spacing: 6) {
            ForEach(Array(drafts.enumerated()), id: \.element.id) { _, draft in
                Capsule()
                    .fill(segmentColor(for: draft))
                    .frame(height: 6)
                    .overlay(
                        Capsule().strokeBorder(
                            draft.isLogged ? Color.clear : Theme.stroke,
                            lineWidth: 1
                        )
                    )
            }
            Text(progressLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textDim)
                .fixedSize()
                .padding(.leading, 4)
        }
    }

    private func segmentColor(for draft: SetDraft) -> Color {
        guard draft.isLogged else { return Color.white.opacity(0.05) }
        return draft.loggedSet?.isPR == true ? Theme.gold : Theme.emerald
    }

    private var progressLabel: String {
        if drafts.isEmpty { return "no sets" }
        return loggedCount == drafts.count ? "complete" : "\(loggedCount)/\(drafts.count) sets"
    }

    // MARK: - Set rows

    private var setRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(drafts.enumerated()), id: \.element.id) { index, draft in
                if draft.isLogged {
                    loggedRow(index: index, draft: draft)
                } else {
                    upcomingRow(index: index)
                }
            }
        }
    }

    /// A checked-off set: summary text, crown for PRs, tappable check to undo.
    private func loggedRow(index: Int, draft: SetDraft) -> some View {
        let set = draft.loggedSet!
        return HStack(spacing: 10) {
            Text("SET \(index + 1)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(set.isPR ? Theme.gold : Theme.emerald)

            Text(setSummary(set))
                .font(.subheadline.weight(.medium))
                .monospacedDigit()

            Spacer()

            if set.isPR {
                Label("PR", systemImage: "crown.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.gold)
            } else if set.isWarmup {
                Text("warmup")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }

            Button {
                undoSet(at: index)
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.emerald)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Undo set \(index + 1)")
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(
            set.isPR ? Theme.gold.opacity(0.10) : Theme.emerald.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }

    /// A planned set still to come: dim placeholder line. Long-press to remove.
    private func upcomingRow(index: Int) -> some View {
        HStack(spacing: 10) {
            Text("SET \(index + 1)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textDim)

            Text("…")
                .font(.subheadline)
                .foregroundStyle(Theme.textDim)

            Spacer()

            Text("upcoming")
                .font(.subheadline)
                .foregroundStyle(Theme.textDim)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .contextMenu {
            if canDeleteRows {
                Button(role: .destructive) {
                    deleteSet(at: index)
                } label: {
                    Label("Remove Set", systemImage: "trash")
                }
            }
        }
    }

    private var canDeleteRows: Bool { drafts.count > 1 }

    private func setSummary(_ set: ExerciseSet) -> String {
        switch exercise.trackingType {
        case .weightAndReps:
            return "\(set.weight.cleanWeight) lbs × \(set.reps)"
        case .bodyweightAndReps:
            if set.weight > 0 { return "BW+\(set.weight.cleanWeight) × \(set.reps)" }
            if set.weight < 0 { return "BW\(set.weight.cleanWeight) × \(set.reps)" }
            return "BW × \(set.reps)"
        case .durationAndReps:
            return "\((set.durationSeconds ?? 0).clockString) × \(set.reps)"
        case .timeAndDistance:
            return "\(Int(set.distanceMeters ?? 0)) m in \((set.durationSeconds ?? 0).clockString)"
        case .customMetric:
            return "\(set.weight.cleanWeight) \(exercise.customMetricUnit ?? "") × \(set.reps)"
        }
    }

    // MARK: - Next-set inputs

    /// One big value pair that edits whatever LOG SET records next.
    @ViewBuilder
    private var nextSetInputs: some View {
        if let index = nextPendingIndex {
            HStack(spacing: 12) {
                switch exercise.trackingType {
                case .weightAndReps, .bodyweightAndReps, .customMetric:
                    BigValueField(
                        value: $drafts[index].primary,
                        step: exercise.defaultIncrement,
                        allowsNegative: exercise.isAssisted
                    )
                    separator("x")
                    BigValueField(value: repsBinding(index), step: 1, allowsNegative: false, minimum: 1)
                        .frame(maxWidth: 110)
                case .durationAndReps:
                    BigValueField(value: $drafts[index].primary, step: 5, allowsNegative: false)
                    separator("x")
                    BigValueField(value: repsBinding(index), step: 1, allowsNegative: false, minimum: 1)
                        .frame(maxWidth: 110)
                case .timeAndDistance:
                    BigValueField(value: $drafts[index].primary, step: 15, allowsNegative: false)
                    separator("·")
                    BigValueField(value: $drafts[index].distance, step: 100, allowsNegative: false)
                }
            }
        }
    }

    private func separator(_ symbol: String) -> some View {
        Text(symbol)
            .font(.headline)
            .foregroundStyle(Theme.textDim)
    }

    private func repsBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { Double(drafts[index].reps) },
            set: { drafts[index].reps = max(1, Int($0)) }
        )
    }

    private var addSetButton: some View {
        Button {
            addSet()
        } label: {
            Label("Add Set", systemImage: "plus.circle.fill")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.emerald)
    }

    // MARK: - Warmup & actions

    private var warmupToggle: some View {
        HStack {
            Toggle(isOn: $isWarmup) {
                Text("Warmup")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }
            .toggleStyle(.button)
            .tint(Theme.violet)

            Spacer()

            Text(loadHint)
                .font(.caption2)
                .foregroundStyle(Theme.textDim)
        }
    }

    private var loadHint: String {
        if let bodyWeight {
            return "incl. BW \(bodyWeight.cleanWeight) lbs"
        }
        return exercise.isAssisted ? "Assisted — negative = help" : ""
    }

    @ViewBuilder
    private var logButton: some View {
        if nextPending != nil {
            Button {
                logNextSet()
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
        } else {
            Label("All sets complete", systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.emerald)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
    }

    /// Mid-session pivots: swap this movement for another, or drop it entirely.
    private var sessionActions: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.shared.tick()
                showReplacePicker = true
            } label: {
                Label("Replace", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .foregroundStyle(Theme.teal)
                    .background(Theme.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            Button {
                Haptics.shared.tick()
                showRemoveConfirmation = true
            } label: {
                Label("Remove", systemImage: "trash")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .foregroundStyle(Theme.crimson)
                    .background(Theme.crimson.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 2)
    }

    // MARK: - Mutations

    private func addSet() {
        let template = drafts.last
        var draft = SetDraft(
            primary: template?.primary ?? initialPrimary,
            reps: template?.reps ?? 8
        )
        if let template { draft.distance = template.distance }
        withAnimation(.snappy) { drafts.append(draft) }
        Haptics.shared.tick()
    }

    private func deleteSet(at index: Int) {
        guard canDeleteRows, drafts.indices.contains(index), !drafts[index].isLogged else { return }
        _ = withAnimation(.snappy) { drafts.remove(at: index) }
        Haptics.shared.tick()
    }

    private func logNextSet() {
        guard let index = nextPendingIndex else { return }
        let draft = drafts[index]

        switch exercise.trackingType {
        case .weightAndReps, .bodyweightAndReps, .customMetric:
            workout.logSet(exercise: exercise, weight: draft.primary, reps: draft.reps, isWarmup: isWarmup)
        case .durationAndReps:
            workout.logSet(exercise: exercise, weight: 0, reps: draft.reps, durationSeconds: draft.primary, isWarmup: isWarmup)
        case .timeAndDistance:
            workout.logSet(exercise: exercise, weight: 0, reps: 1, durationSeconds: draft.primary, distanceMeters: draft.distance, isWarmup: isWarmup)
        }

        // The set just persisted is the newest one for this exercise.
        drafts[index].loggedSet = workout.lastSet(for: exercise)
        isWarmup = false
    }

    private func undoSet(at index: Int) {
        guard drafts.indices.contains(index), let set = drafts[index].loggedSet else { return }
        workout.undoSet(set)
        withAnimation(.snappy) { drafts[index].loggedSet = nil }
    }

    // MARK: - Prefill

    private var initialPrimary: Double {
        switch exercise.trackingType {
        case .weightAndReps: return exercise.isAssisted ? 0 : 45
        case .durationAndReps: return 30
        case .timeAndDistance: return 300
        default: return 0
        }
    }

    /// Cards for movements with nothing logged yet open ready to plan; once
    /// sets exist the card arrives collapsed, showing progress.
    private func initialSetup() {
        guard !didPrefill else { return }
        didPrefill = true
        prefillFromHistory()
        adoptLoggedSets()
        isExpanded = loggedCount == 0
    }

    /// Plan rows from the movement's most recent session, or a sensible default.
    private func prefillFromHistory() {
        guard let latest = exercise.sets.max(by: { $0.timestamp < $1.timestamp }),
              let lastSession = latest.session else {
            drafts = (0..<3).map { _ in SetDraft(primary: initialPrimary, reps: 8) }
            return
        }
        let historySets = exercise.sets
            .filter { $0.session?.id == lastSession.id && !$0.isWarmup }
            .sorted { $0.timestamp < $1.timestamp }
        guard !historySets.isEmpty else {
            drafts = (0..<3).map { _ in SetDraft(primary: initialPrimary, reps: 8) }
            return
        }
        drafts = historySets.map { set in
            var draft = SetDraft(primary: primaryValue(from: set), reps: max(1, set.reps))
            draft.distance = set.distanceMeters ?? 1600
            return draft
        }
    }

    /// Reattach any sets already logged this session (card re-created on scroll,
    /// tab switch, or replace-undo) so progress survives view identity churn.
    private func adoptLoggedSets() {
        let logged = workout.sets(for: exercise)
        guard !logged.isEmpty else { return }
        for (offset, set) in logged.enumerated() {
            var draft = SetDraft(primary: primaryValue(from: set), reps: max(1, set.reps))
            draft.distance = set.distanceMeters ?? 1600
            draft.loggedSet = set
            if offset < drafts.count {
                drafts[offset] = draft
            } else {
                drafts.append(draft)
            }
        }
    }

    private func primaryValue(from set: ExerciseSet) -> Double {
        switch exercise.trackingType {
        case .durationAndReps, .timeAndDistance: return set.durationSeconds ?? 0
        default: return set.weight
        }
    }
}

// MARK: - Big value field

/// A large, tappable value field for the next set: type directly, or scrub
/// horizontally to step the value with a haptic tick per increment.
private struct BigValueField: View {
    @Binding var value: Double
    let step: Double
    let allowsNegative: Bool
    var minimum: Double? = nil

    @State private var dragAccumulator: CGFloat = 0
    @FocusState private var isEditing: Bool

    var body: some View {
        TextField("", value: $value, format: .number)
            .keyboardType(allowsNegative ? .numbersAndPunctuation : .decimalPad)
            .multilineTextAlignment(.center)
            .font(.system(.title2, design: .rounded, weight: .bold))
            .monospacedDigit()
            .focused($isEditing)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Theme.surfaceRaised.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.white.opacity(isEditing ? 0.45 : 0.22), lineWidth: 1.5)
            )
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
                value = clamped(newValue)
            }
            .toolbar {
                if isEditing {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { isEditing = false }
                    }
                }
            }
    }

    private func clamped(_ proposed: Double) -> Double {
        var result = proposed
        if let minimum { result = max(minimum, result) }
        if !allowsNegative { result = max(minimum ?? 0, result) }
        return result
    }

    private func adjust(by delta: Double) {
        let newValue = clamped(value + delta)
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
