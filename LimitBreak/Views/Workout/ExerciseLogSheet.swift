import SwiftUI

// MARK: - Exercise log sheet

/// The primary logging surface for a movement, opened by tapping its session
/// card. Shows a large header with the example image and targeted muscle, an
/// expandable "how to perform" guide, an editable list of set rows (weight ×
/// reps, add/delete, edit any value), and a big LOG SET button pinned at the
/// bottom. When the movement is part of a superset, logging a set rolls the
/// sheet on to the next movement in the group instead of dismissing.
struct ExerciseLogSheet: View {
    @Environment(WorkoutManager.self) private var workout

    /// The movement currently shown. Mutated to rotate through a superset run.
    @State private var currentExercise: Exercise

    init(exercise: Exercise) {
        _currentExercise = State(initialValue: exercise)
    }

    var body: some View {
        // No navigation bar — the image banner runs to the very top of the sheet.
        // Re-mounting on identity change re-seeds the editor's drafts for the
        // next movement when a superset advances.
        ExerciseLogEditor(exercise: currentExercise, onLoggedInSuperset: advanceSuperset)
            .id(currentExercise.id)
            .presentationDragIndicator(.visible)
    }

    /// After a set is logged for a superset member, advance to the next movement
    /// in the run (wrapping) so the lifter rolls through the group.
    private func advanceSuperset() {
        let runs = workout.sessionSupersetRuns()
        guard let run = runs.first(where: { run in run.contains { $0.id == currentExercise.id } }),
              run.count > 1,
              let index = run.firstIndex(where: { $0.id == currentExercise.id }) else { return }
        let next = run[(index + 1) % run.count]
        guard next.id != currentExercise.id else { return }
        withAnimation(.snappy) { currentExercise = next }
    }
}

// MARK: - Editor

/// The stateful body of the log sheet for a single movement: header, how-to,
/// target, editable set rows, warmup, reps-in-reserve, and the pinned LOG SET.
private struct ExerciseLogEditor: View {
    @Environment(WorkoutManager.self) private var workout
    let exercise: Exercise
    /// Called after a set is logged while this movement is in a superset, so the
    /// enclosing sheet can advance to the next member.
    var onLoggedInSuperset: () -> Void

    @State private var drafts: [SetDraft] = []
    @State private var isWarmup = false
    @State private var didPrefill = false
    @State private var repsInReserve: Int?
    @State private var showHowTo = false
    @State private var target: ProgressionTarget?
    /// Drives the full-screen hold timer for hold-for-time movements.
    @State private var showHoldTimer = false

    /// One planned set. `primary` is weight (lbs) for weight-based types, seconds
    /// for duration-based types, or the custom-metric value.
    private struct SetDraft: Identifiable {
        let id = UUID()
        var primary: Double
        var reps: Int
        var distance: Double = 1600
        var loggedSet: ExerciseSet?

        var isLogged: Bool { loggedSet != nil }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Full-bleed image at the very top, dissolving into the canvas.
                ExerciseImageBanner(exercise: exercise, height: 220, blendsIntoBackground: true)
                    .overlay(alignment: .bottomLeading) {
                        MuscleBadge(exercise: exercise)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 6)
                    }

                VStack(alignment: .leading, spacing: 16) {
                    titleBlock
                    howToPerform
                    targetBanner
                    setList
                    addSetButton
                    warmupToggle
                    repsInReserveSection
                }
                .padding()
                .padding(.bottom, 8)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .obsidianBackground()
        .safeAreaInset(edge: .bottom) { bottomStack }
        .onAppear(perform: initialSetup)
        // Capture any edits to the pending rows' values when leaving this
        // movement, so the plan is restored intact on the way back.
        .onDisappear { if didPrefill { persistPlan() } }
        .onChange(of: workout.sets(for: exercise).count) {
            adoptLoggedSets()
            persistPlan()
        }
        .fullScreenCover(isPresented: $showHoldTimer) {
            HoldTimerView(
                exerciseName: exercise.name,
                targetSeconds: nextPending?.primary ?? initialPrimary
            ) { held in
                logHold(seconds: held)
            }
        }
    }

    // MARK: - Header

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let letter = workout.supersetLabel(for: exercise) {
                Label("SUPERSET \(letter)", systemImage: "link")
                    .font(.caption2.weight(.bold))
                    .kerning(0.5)
                    .foregroundStyle(Theme.teal)
            }
            Text(exercise.name)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.leading)
            Text("\(exercise.muscleGroupDisplay) · \(exercise.equipmentType)")
                .font(.caption)
                .foregroundStyle(Theme.textDim)

            if showsOneRM {
                HStack(spacing: 6) {
                    Text("e1RM")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textDim)
                    Text("\(exercise.displayWeightString(fromPounds: liveOneRepMax)) \(exercise.weightUnit.abbreviation)")
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(wouldLimitBreak ? Theme.gold : .primary)
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - How to perform

    /// Tappable guide: expands to the movement's description and numbered steps.
    /// Hidden entirely when the movement carries neither.
    @ViewBuilder
    private var howToPerform: some View {
        let steps = exercise.instructionSteps
        let hasGuide = !steps.isEmpty || (exercise.exerciseDescription?.isEmpty == false)
        if hasGuide {
            VStack(alignment: .leading, spacing: showHowTo ? 12 : 0) {
                Button {
                    withAnimation(.snappy) { showHowTo.toggle() }
                    Haptics.shared.tick()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "figure.strengthtraining.traditional")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.violet)
                        Text("How to perform")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.textDim)
                            .rotationEffect(.degrees(showHowTo ? 0 : -90))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showHowTo {
                    if let desc = exercise.exerciseDescription, !desc.isEmpty {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(Theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.caption2.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.violet)
                                .frame(width: 20, height: 20)
                                .background(Theme.violet.opacity(0.15), in: Circle())
                            Text(step)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.glassBorder, lineWidth: 1))
        }
    }

    // MARK: - Progression target

    @ViewBuilder
    private var targetBanner: some View {
        if let target, nextPending != nil {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "target")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.violet)
                VStack(alignment: .leading, spacing: 2) {
                    Text(targetHeadline(target))
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                    Text(targetSubline(target))
                        .font(.caption2)
                        .foregroundStyle(Theme.textDim)
                }
                Spacer()
                Text(target.emphasis.label.uppercased())
                    .font(.caption2.weight(.bold))
                    .kerning(0.5)
                    .foregroundStyle(target.emphasis == .heavy ? Theme.gold : Theme.teal)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        (target.emphasis == .heavy ? Theme.gold : Theme.teal).opacity(0.14),
                        in: Capsule()
                    )
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.violet.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func targetHeadline(_ target: ProgressionTarget) -> String {
        var text = "Aim for \(target.sets)\u{00D7}\(target.targetReps)"
        if let pounds = target.targetWeightPounds, pounds > 0 {
            text += " \u{00B7} \(exercise.displayWeightString(fromPounds: pounds)) \(exercise.weightUnit.abbreviation)"
        }
        return text
    }

    private func targetSubline(_ target: ProgressionTarget) -> String {
        guard let previous = target.previous else { return target.emphasis.descriptor }
        var text = "Beat last \(previous.sets)\u{00D7}\(previous.topReps)"
        if previous.weightPounds > 0 {
            text += " @ \(exercise.displayWeightString(fromPounds: previous.weightPounds)) \(exercise.weightUnit.abbreviation)"
        }
        return text
    }

    // MARK: - Set list

    private var setList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SETS")
                    .font(.caption.weight(.bold))
                    .kerning(1)
                    .foregroundStyle(Theme.textDim)
                Spacer()
                if exercise.usesWeightUnit { unitToggle.frame(width: 92) }
            }
            ForEach(Array(drafts.enumerated()), id: \.element.id) { index, draft in
                if draft.isLogged {
                    loggedRow(index: index, draft: draft)
                } else {
                    editableRow(index: index)
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
                .frame(width: 54, alignment: .leading)

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
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            set.isPR ? Theme.gold.opacity(0.10) : Theme.emerald.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .contextMenu {
            Button {
                undoSet(at: index)
            } label: {
                Label("Undo Set", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) {
                deleteLoggedSet(at: index)
            } label: {
                Label("Delete Set", systemImage: "trash")
            }
        }
    }

    /// A planned, not-yet-logged set: every value is editable inline, with a
    /// delete control. The next one LOG SET will record is highlighted.
    private func editableRow(index: Int) -> some View {
        let isNext = index == nextPendingIndex
        return HStack(spacing: 10) {
            Text("SET \(index + 1)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isNext ? .primary : Theme.textDim)
                .frame(width: 54, alignment: .leading)

            rowInputs(index)

            Spacer(minLength: 4)

            if canDeleteRows {
                Button {
                    deleteSet(at: index)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.crimson.opacity(0.8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete set \(index + 1)")
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            (isNext ? Theme.emerald.opacity(0.06) : Color.white.opacity(0.02)),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isNext ? Theme.emerald.opacity(0.5) : Theme.stroke, lineWidth: 1)
        )
    }

    /// The weight × reps (or duration/distance) editors for one planned row.
    @ViewBuilder
    private func rowInputs(_ index: Int) -> some View {
        switch exercise.trackingType {
        case .weightAndReps, .bodyweightAndReps, .customMetric:
            BigValueField(
                value: primaryBinding(index),
                step: exercise.defaultIncrement,
                allowsNegative: exercise.isAssisted
            )
            separator("x")
            BigValueField(value: repsBinding(index), step: 1, allowsNegative: false, minimum: 1)
                .frame(maxWidth: 96)
        case .durationAndReps:
            BigValueField(value: primaryBinding(index), step: 5, allowsNegative: false)
            separator("x")
            BigValueField(value: repsBinding(index), step: 1, allowsNegative: false, minimum: 1)
                .frame(maxWidth: 96)
        case .durationOnly:
            BigValueField(value: primaryBinding(index), step: 5, allowsNegative: false, minimum: 1)
            Text("sec")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textDim)
        case .timeAndDistance:
            BigValueField(value: primaryBinding(index), step: 15, allowsNegative: false)
            separator("·")
            BigValueField(value: distanceBinding(index), step: 100, allowsNegative: false)
        }
    }

    private func separator(_ symbol: String) -> some View {
        Text(symbol)
            .font(.headline)
            .foregroundStyle(Theme.textDim)
    }

    /// The primary value (weight/duration) editor for a row. Editing a pending
    /// set carries the new value through to every later, not-yet-logged set so
    /// tuning an early set updates the remaining sets for this session.
    private func primaryBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { drafts[index].primary },
            set: { newValue in
                drafts[index].primary = newValue
                cascadeToLaterPending(from: index) { $0.primary = newValue }
            }
        )
    }

    private func repsBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { Double(drafts[index].reps) },
            set: { newValue in
                let reps = max(1, Int(newValue))
                drafts[index].reps = reps
                cascadeToLaterPending(from: index) { $0.reps = reps }
            }
        )
    }

    private func distanceBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { drafts[index].distance },
            set: { newValue in
                drafts[index].distance = newValue
                cascadeToLaterPending(from: index) { $0.distance = newValue }
            }
        )
    }

    /// Apply an edit to every set after `index` that hasn't been logged yet,
    /// leaving already-logged sets and the edited row's predecessors untouched.
    private func cascadeToLaterPending(from index: Int, _ apply: (inout SetDraft) -> Void) {
        guard index + 1 < drafts.count else { return }
        for j in (index + 1)..<drafts.count where !drafts[j].isLogged {
            apply(&drafts[j])
        }
    }

    private var unitToggle: some View {
        HStack(spacing: 0) {
            ForEach(WeightUnit.allCases) { unit in
                let selected = exercise.weightUnit == unit
                Button {
                    setUnit(unit)
                } label: {
                    Text(unit.tag)
                        .font(.caption2.weight(.bold))
                        .kerning(0.5)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .foregroundStyle(selected ? .black : Theme.textDim)
                        .background(
                            selected ? AnyShapeStyle(Theme.emerald) : AnyShapeStyle(Color.clear),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .frame(height: 24)
        .background(Theme.surfaceRaised.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
    }

    private func setUnit(_ unit: WeightUnit) {
        let old = exercise.weightUnit
        guard old != unit else { return }
        for i in drafts.indices where !drafts[i].isLogged {
            drafts[i].primary = unit.fromPounds(old.toPounds(drafts[i].primary))
        }
        workout.setWeightUnit(unit, for: exercise)
        persistPlan()
        Haptics.shared.tick()
    }

    private var addSetButton: some View {
        Button {
            addSet()
        } label: {
            Label("Add Set", systemImage: "plus.circle.fill")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(Theme.emerald)
                .glassControl(cornerRadius: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Warmup

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

    // MARK: - Reps in reserve

    private var hasWorkingSet: Bool {
        drafts.contains { $0.loggedSet?.isWarmup == false }
    }

    @ViewBuilder
    private var repsInReserveSection: some View {
        // Hold-for-time movements have no reps, so the rep-based effort read
        // doesn't apply — the timer already captures how long you lasted.
        if exercise.trackingType.usesReps && nextPending == nil && hasWorkingSet {
            VStack(alignment: .leading, spacing: 10) {
                Text("How many more reps could you have done?")
                    .font(.subheadline.weight(.semibold))
                Text("Your honest read tunes how hard your coach pushes this lift next time.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textDim)

                HStack(spacing: 8) {
                    ForEach(1...5, id: \.self) { value in
                        repsInReserveButton(value)
                    }
                }

                HStack {
                    Text("1 · near failure")
                    Spacer()
                    Text("5 · easy")
                }
                .font(.caption2)
                .foregroundStyle(Theme.textDim)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.emerald.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func repsInReserveButton(_ value: Int) -> some View {
        let selected = repsInReserve == value
        return Button {
            Haptics.shared.tick()
            withAnimation(.snappy) { repsInReserve = value }
            workout.setRepsInReserve(value, for: exercise)
        } label: {
            Text("\(value)")
                .font(.headline.weight(.bold))
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(selected ? .black : .primary)
                .background(
                    selected ? AnyShapeStyle(Theme.emerald) : AnyShapeStyle(Theme.surfaceRaised.opacity(0.5)),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(selected ? Color.clear : Theme.stroke, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(value) more rep\(value == 1 ? "" : "s") in reserve")
    }

    // MARK: - Bottom bar

    /// The rest countdown (started automatically after logging a set) stacked
    /// above the log bar, so the cooldown stays visible while the sheet is open.
    private var bottomStack: some View {
        VStack(spacing: 0) {
            if workout.isResting {
                RestTimerOverlay()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            bottomBar
        }
        .animation(.spring(duration: 0.35), value: workout.isResting)
    }

    @ViewBuilder
    private var bottomBar: some View {
        if let pending = nextPending {
            if exercise.trackingType == .durationOnly {
                holdTimerBottomBar(pending)
            } else {
                Button {
                    logNextSet()
                } label: {
                    Text(isWarmup ? "LOG WARMUP" : "LOG SET")
                        .font(.headline)
                        .kerning(1.5)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundStyle(wouldLimitBreak ? .black : .white)
                        .glassCTA(tint: wouldLimitBreak ? Theme.gold.opacity(0.9) : Theme.emerald.opacity(0.85))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
                .padding(.bottom, 10)
            }
        }
    }

    /// For hold-for-time movements: the timer is the primary way to log — it
    /// counts you into the target and past it — with a manual fallback below.
    private func holdTimerBottomBar(_ pending: SetDraft) -> some View {
        VStack(spacing: 10) {
            Button {
                Haptics.shared.tick()
                showHoldTimer = true
            } label: {
                Label("START HOLD TIMER", systemImage: "timer")
                    .font(.headline)
                    .kerning(1.5)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .foregroundStyle(.black)
                    .glassCTA(tint: Theme.emerald.opacity(0.85))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                logNextSet()
            } label: {
                Text(isWarmup ? "Log warmup manually" : "Log \(pending.primary.clockString) manually")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textDim)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.bottom, 10)
    }

    // MARK: - Derived state

    private var loggedCount: Int { drafts.filter(\.isLogged).count }
    private var nextPendingIndex: Int? { drafts.firstIndex { !$0.isLogged } }
    private var nextPending: SetDraft? { nextPendingIndex.map { drafts[$0] } }
    private var canDeleteRows: Bool { drafts.filter { !$0.isLogged }.count > 1 }

    private var bodyWeight: Double? {
        guard exercise.trackingType == .bodyweightAndReps || exercise.isAssisted else { return nil }
        return HealthKitManager.shared.currentBodyWeightLbs
    }

    private var showsOneRM: Bool {
        guard let next = nextPending else { return false }
        switch exercise.trackingType {
        case .weightAndReps: return exercise.weightUnit.toPounds(next.primary) + (bodyWeight ?? 0) > 0
        case .bodyweightAndReps: return next.primary > 0 || bodyWeight != nil
        default: return false
        }
    }

    private var liveOneRepMax: Double {
        guard let next = nextPending else { return 0 }
        let addedPounds = exercise.usesWeightUnit ? exercise.weightUnit.toPounds(next.primary) : next.primary
        return exercise.formula.estimate(weight: addedPounds + (bodyWeight ?? 0), reps: next.reps)
    }

    private var wouldLimitBreak: Bool {
        showsOneRM && liveOneRepMax > exercise.ceiling(for: "1RM") && exercise.ceiling(for: "1RM") > 0
    }

    // MARK: - Summaries

    private func setSummary(_ set: ExerciseSet) -> String {
        switch exercise.trackingType {
        case .weightAndReps:
            return "\(exercise.displayWeightString(fromPounds: set.weight)) \(exercise.weightUnit.abbreviation) × \(set.reps)"
        case .bodyweightAndReps:
            if set.weight > 0 { return "BW+\(exercise.displayWeightString(fromPounds: set.weight)) × \(set.reps)" }
            if set.weight < 0 { return "BW\(exercise.displayWeightString(fromPounds: set.weight)) × \(set.reps)" }
            return "BW × \(set.reps)"
        case .durationAndReps:
            return "\((set.durationSeconds ?? 0).clockString) × \(set.reps)"
        case .durationOnly:
            return (set.durationSeconds ?? 0).clockString
        case .timeAndDistance:
            return "\(Int(set.distanceMeters ?? 0)) m in \((set.durationSeconds ?? 0).clockString)"
        case .customMetric:
            return "\(set.weight.cleanWeight) \(exercise.customMetricUnit ?? "") × \(set.reps)"
        }
    }

    private func primaryValue(from set: ExerciseSet) -> Double {
        switch exercise.trackingType {
        case .durationAndReps, .durationOnly, .timeAndDistance: return set.durationSeconds ?? 0
        case .weightAndReps, .bodyweightAndReps: return exercise.weightUnit.fromPounds(set.weight)
        case .customMetric: return set.weight
        }
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
        persistPlan()
        Haptics.shared.tick()
    }

    private func deleteSet(at index: Int) {
        guard canDeleteRows, drafts.indices.contains(index), !drafts[index].isLogged else { return }
        _ = withAnimation(.snappy) { drafts.remove(at: index) }
        persistPlan()
        Haptics.shared.tick()
    }

    private func logNextSet() {
        guard let index = nextPendingIndex else { return }
        let draft = drafts[index]

        switch exercise.trackingType {
        case .weightAndReps, .bodyweightAndReps:
            workout.logSet(exercise: exercise, weight: exercise.weightUnit.toPounds(draft.primary), reps: draft.reps, isWarmup: isWarmup)
        case .customMetric:
            workout.logSet(exercise: exercise, weight: draft.primary, reps: draft.reps, isWarmup: isWarmup)
        case .durationAndReps:
            workout.logSet(exercise: exercise, weight: 0, reps: draft.reps, durationSeconds: draft.primary, isWarmup: isWarmup)
        case .durationOnly:
            workout.logSet(exercise: exercise, weight: 0, reps: 1, durationSeconds: draft.primary, isWarmup: isWarmup)
        case .timeAndDistance:
            workout.logSet(exercise: exercise, weight: 0, reps: 1, durationSeconds: draft.primary, distanceMeters: draft.distance, isWarmup: isWarmup)
        }

        drafts[index].loggedSet = workout.lastSet(for: exercise)
        persistPlan()
        let wasWarmup = isWarmup
        isWarmup = false

        // Warmups don't rotate the superset — they're ramp-up on the same lift.
        if !wasWarmup, !workout.supersetPartners(for: exercise).isEmpty {
            onLoggedInSuperset()
        }
    }

    private func undoSet(at index: Int) {
        guard drafts.indices.contains(index), let set = drafts[index].loggedSet else { return }
        workout.undoSet(set)
        withAnimation(.snappy) { drafts[index].loggedSet = nil }
        persistPlan()
    }

    /// Fully removes a logged set from the session and drops its row, rather
    /// than reverting it to an editable pending row the way `undoSet` does.
    private func deleteLoggedSet(at index: Int) {
        guard drafts.indices.contains(index), let set = drafts[index].loggedSet else { return }
        workout.undoSet(set)
        _ = withAnimation(.snappy) { drafts.remove(at: index) }
        persistPlan()
        Haptics.shared.tick()
    }

    /// Records the seconds measured by the hold timer as the next pending set.
    private func logHold(seconds: Double) {
        guard let index = nextPendingIndex else { return }
        drafts[index].primary = max(1, seconds.rounded())
        logNextSet()
    }

    // MARK: - Prefill

    private var initialPrimary: Double {
        switch exercise.trackingType {
        case .weightAndReps: return exercise.isAssisted ? 0 : exercise.weightUnit.fromPounds(45)
        case .durationAndReps, .durationOnly: return 30
        case .timeAndDistance: return 300
        default: return 0
        }
    }

    private func initialSetup() {
        guard !didPrefill else { return }
        didPrefill = true
        target = workout.progressionTarget(for: exercise)
        // Restore the plan the lifter already laid out for this movement this
        // session (surviving exercise switches); only seed a fresh plan from
        // history/target the first time the sheet is opened for it.
        if let saved = workout.plannedSets(for: exercise) {
            restorePlan(saved)
        } else {
            prefillFromHistory()
            adoptLoggedSets()
            persistPlan()
        }
        repsInReserve = workout.repsInReserve(for: exercise)
    }

    /// Rebuilds the set rows from the persisted plan: the sets already logged
    /// this session (authoritative, rebuilt from the manager) followed by the
    /// pending planned sets the lifter set up earlier.
    private func restorePlan(_ saved: [WorkoutManager.PlannedSet]) {
        let loggedDrafts = workout.sets(for: exercise).map(makeLoggedDraft)
        let pending = saved.map { plan -> SetDraft in
            var draft = SetDraft(primary: plan.primary, reps: plan.reps)
            draft.distance = plan.distance
            return draft
        }
        drafts = loggedDrafts + pending
    }

    private func makeLoggedDraft(_ set: ExerciseSet) -> SetDraft {
        var draft = SetDraft(primary: primaryValue(from: set), reps: max(1, set.reps))
        draft.distance = set.distanceMeters ?? 1600
        draft.loggedSet = set
        return draft
    }

    /// Saves the current pending (not-yet-logged) rows to the manager so the
    /// plan — count and values — persists across exercise switches.
    private func persistPlan() {
        let pending = drafts.filter { !$0.isLogged }.map {
            WorkoutManager.PlannedSet(primary: $0.primary, reps: $0.reps, distance: $0.distance)
        }
        workout.updatePlannedSets(pending, for: exercise)
    }

    private var plannedPrimary: Double? {
        switch exercise.trackingType {
        case .weightAndReps, .bodyweightAndReps:
            guard let pounds = workout.plannedWeight(for: exercise) else { return nil }
            return exercise.weightUnit.fromPounds(pounds)
        case .customMetric:
            return workout.plannedWeight(for: exercise)
        case .durationAndReps, .durationOnly, .timeAndDistance:
            return nil
        }
    }

    private func targetPrimary(_ target: ProgressionTarget) -> Double {
        switch exercise.trackingType {
        case .weightAndReps, .bodyweightAndReps:
            if let pounds = target.targetWeightPounds {
                return exercise.weightUnit.fromPounds(pounds)
            }
        case .customMetric:
            if let value = target.targetWeightPounds { return value }
        default:
            break
        }
        if let last = exercise.sets.filter({ !$0.isWarmup }).max(by: { $0.timestamp < $1.timestamp }) {
            return primaryValue(from: last)
        }
        return initialPrimary
    }

    private func prefillFromHistory() {
        let plannedReps = workout.plannedReps(for: exercise)
        if plannedReps != nil || plannedPrimary != nil {
            let count = max(1, workout.targetSets(for: exercise))
            drafts = (0..<count).map { _ in
                SetDraft(primary: plannedPrimary ?? initialPrimary, reps: plannedReps ?? 8)
            }
            return
        }
        if let target {
            let count = max(1, target.sets)
            let primary = targetPrimary(target)
            drafts = (0..<count).map { _ in SetDraft(primary: primary, reps: target.targetReps) }
            return
        }
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
}

// MARK: - Big value field

/// A large, tappable value field for a set: type directly, or scrub horizontally
/// to step the value with a haptic tick per increment.
struct BigValueField: View {
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
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Theme.surfaceRaised.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.white.opacity(isEditing ? 0.45 : 0.22), lineWidth: 1.5)
            )
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { gesture in
                        guard abs(gesture.translation.width) > abs(gesture.translation.height) else {
                            dragAccumulator = gesture.translation.width
                            return
                        }
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
