import SwiftUI
import SwiftData
import UIKit

/// Asks the user what to focus on and how much to do, then generates a
/// tappable workout on-device and hands it back to start a session.
struct AIWorkoutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkoutManager.self) private var workout
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var sessions: [WorkoutSession]
    @Query private var profiles: [TrainingProfile]

    /// The focus the sheet opens on. Defaults to full body; callers can point the
    /// generator at specific work so the lifter doesn't have to re-pick it.
    var initialFocus: WorkoutFocus = .fullBody

    /// Called with the generated session title, the ordered exercises to load,
    /// the coached set/rep/weight targets keyed by exercise id, the superset
    /// grouping (exercise id → tag) the coach recommended, and whether the
    /// session is being trained with a partner.
    let onStart: (String, [Exercise], [UUID: Int], [UUID: Int], [UUID: Double], [UUID: Int], Bool) -> Void

    @State private var focus: WorkoutFocus = .fullBody
    @State private var exerciseCount = 5
    @State private var duration: WorkoutLength = .any
    @State private var withPartner = false
    /// Whether the coach may bundle some movements into supersets. On by default
    /// so plans arrive with a couple of pairings; the lifter can opt out.
    @State private var allowSupersets = true
    @State private var plan: WorkoutPlan?
    @State private var isGenerating = false
    @State private var didSaveRoutine = false
    @State private var inspectedExercise: PlannedExerciseDetail?
    @State private var manualReplaceTarget: ReplaceTarget?
    @State private var swappingIndex: Int?

    /// Sheet payload for one tapped plan row: the matched catalog movement, how
    /// many sets the plan calls for, the coached prescription (when any), and the
    /// slot's currently-resolved rep target so the detail slider opens in sync.
    struct PlannedExerciseDetail: Identifiable {
        /// The `PlannedExercise.id` of the tapped slot, so a resolved rep target
        /// can be written back to the right row.
        let slotID: UUID
        let exercise: Exercise
        let sets: Int
        let prescription: Prescription?
        let selectedReps: Int?
        var id: UUID { slotID }
    }

    /// Which plan slot the manual exercise picker is replacing.
    struct ReplaceTarget: Identifiable {
        let index: Int
        var id: Int { index }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let plan {
                        planPreview(plan)
                    } else {
                        configForm
                    }
                }
                .padding()
            }
            .background(SwipeBackDisabler())
            .obsidianBackground()
            .navigationTitle("AI Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { actionBar }
            // `focus` is @State so the lifter can change it; `initialFocus` only
            // seeds where the picker opens.
            .onAppear { focus = initialFocus }
            .sheet(item: $inspectedExercise) { detail in
                PlannedExerciseSheet(
                    exercise: detail.exercise,
                    plannedSets: detail.sets,
                    prescription: detail.prescription,
                    selectedReps: detail.selectedReps,
                    withPartner: withPartner,
                    onChooseReps: { reps in chooseReps(slotID: detail.slotID, reps: reps) }
                )
            }
            .sheet(item: $manualReplaceTarget) { target in
                ExercisePickerSheet { picked in
                    Task { await replaceManually(at: target.index, with: picked) }
                }
            }
        }
    }

    // MARK: - Config

    private var configForm: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(Theme.limitBreakGradient)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

            section("WHAT'S THE FOCUS?") {
                let recommended = recommendedFocuses
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                    ForEach(WorkoutFocus.allCases) { preset in
                        FocusChip(
                            preset: preset,
                            isSelected: focus == preset,
                            isRecommended: focus != preset && recommended.contains(preset)
                        ) {
                            focus = preset
                            Haptics.shared.tick()
                        }
                    }
                }
                if !recommended.isEmpty {
                    Label("Freshest picks — \(recommendedLabel(recommended)). Based on your recent training.",
                          systemImage: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(Theme.violet)
                }
            }

            section("HOW MANY EXERCISES?") {
                HStack(spacing: 12) {
                    ForEach([3, 5, 7], id: \.self) { count in
                        countChip(count)
                    }
                    Spacer()
                    Stepper("", value: $exerciseCount, in: 3...8)
                        .labelsHidden()
                        .tint(Theme.emerald)
                }
                Text("\(exerciseCount) exercise\(exerciseCount == 1 ? "" : "s")")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.emerald)

                supersetToggle
            }

            section("HOW LONG?") {
                Picker("Duration", selection: $duration) {
                    ForEach(WorkoutLength.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }

            section("TRAINING WITH A PARTNER?") {
                PartnerToggle(isOn: $withPartner)
                Text(withPartner
                     ? "Got a spotter \u{2014} I\u{2019}ll favor free-weight lifts and push the loads up."
                     : "Flying solo \u{2014} I\u{2019}ll keep the loads to what you can rack on your own.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textDim)
            }
        }
    }

    /// Checkbox that lets the coach add supersets alongside the chosen movements.
    private var supersetToggle: some View {
        Button {
            Haptics.shared.tick()
            allowSupersets.toggle()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: allowSupersets ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(allowSupersets ? Theme.teal : Theme.textDim)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include supersets")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Let the coach pair some movements back-to-back — it picks which, and may add one or two extra to complete a good superset.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textDim)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textDim)
                .kerning(1)
            content()
        }
    }

    private func countChip(_ count: Int) -> some View {
        let selected = exerciseCount == count
        return Button {
            exerciseCount = count
            Haptics.shared.tick()
        } label: {
            Text("\(count)")
                .font(.headline)
                .monospacedDigit()
                .frame(width: 46, height: 40)
                .foregroundStyle(selected ? .black : .white)
                .background(
                    selected ? AnyShapeStyle(Theme.emerald) : AnyShapeStyle(Theme.surfaceRaised),
                    in: RoundedRectangle(cornerRadius: 12)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Preview

    private func planPreview(_ plan: WorkoutPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("YOUR QUEST")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textDim)
                    .kerning(1)
                Text(plan.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.limitBreakGradient)
            }

            sourceBadge(plan)

            if let rationale = plan.rationale, !rationale.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "quote.opening")
                        .font(.caption2)
                        .foregroundStyle(Theme.violet)
                    Text(rationale)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(Theme.violet.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }

            if let cloudError = plan.cloudError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                    Text("Coaching unavailable — built this on device instead. \(cloudError)")
                        .font(.caption2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(Theme.coral)
                .padding(10)
                .background(Theme.coral.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }

            // Still flippable after generating: the answer drives the load each
            // movement's detail sheet recommends, so a partner turning up late
            // shouldn't mean regenerating the whole plan.
            PartnerToggle(isOn: $withPartner)

            ReorderableVStack(plannedExercisesBinding, spacing: 10) { $planned, grip in
                let index = plan.exercises.firstIndex { $0.id == planned.id } ?? 0
                SwipeablePlanRow(
                    isEnabled: !isGenerating && swappingIndex == nil,
                    onReplaceAI: { Task { await swapWithAI(at: index) } },
                    onReplaceManual: {
                        Haptics.shared.tick()
                        manualReplaceTarget = ReplaceTarget(index: index)
                    }
                ) {
                    planRowContent(index: index, planned: planned, grip: grip)
                }
            }

            Text("Drag \u{2261} to reorder. Tap a movement for how to perform it. Swipe right to replace with AI, left to pick manually \u{2014} or tap \u{22EF}.")
                .font(.caption2)
                .foregroundStyle(Theme.textDim)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// Which tier built this plan. Shown so a device-generated plan is never
    /// mistaken for a fatigue-aware coached one.
    private func sourceBadge(_ plan: WorkoutPlan) -> some View {
        Label(plan.source.label, systemImage: plan.source == .cloud ? "sparkles" : "iphone")
            .font(.caption2.weight(.bold))
            .foregroundStyle(plan.source == .cloud ? Theme.violet : Theme.textDim)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                (plan.source == .cloud ? Theme.violet : Theme.textDim).opacity(0.12),
                in: Capsule()
            )
    }

    /// Binding into the generated plan's exercise list, so the reorder stack can
    /// rewrite the order without the sheet handing out its whole `plan` state.
    private var plannedExercisesBinding: Binding<[PlannedExercise]> {
        Binding(
            get: { plan?.exercises ?? [] },
            set: { reordered in
                guard var updated = plan else { return }
                updated.exercises = reordered
                plan = updated
                // The saved routine would no longer match what's on screen.
                didSaveRoutine = false
            }
        )
    }

    /// One plan row's visible content: grip, number, tappable movement, set count
    /// and the swap menu. Lives inside a `SwipeablePlanRow` that adds
    /// swipe-to-replace.
    private func planRowContent(index: Int, planned: PlannedExercise, grip: ReorderGrip) -> some View {
        HStack(spacing: 8) {
            grip

            Text("\(index + 1)")
                .font(.system(.headline, design: .rounded, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Theme.emerald)
                .frame(width: 20)

            Button {
                guard let exercise = catalogExercise(for: planned.name) else { return }
                Haptics.shared.tick()
                inspectedExercise = detailPayload(for: planned, exercise: exercise)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    if let letter = supersetLetter(for: planned) {
                        Label("SUPERSET \(letter)", systemImage: "link")
                            .font(.caption2.weight(.bold))
                            .kerning(0.5)
                            .foregroundStyle(Theme.teal)
                    }
                    Text(planned.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    if let muscle = muscleGroup(for: planned.name) {
                        Text(muscle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let note = planned.prescription?.note, !note.isEmpty {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(Theme.textDim)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .trailing, spacing: 2) {
                if let rx = planned.prescription {
                    Text("\(planned.sets) \u{00D7} \(planned.targetReps ?? rx.repRangeHigh)")
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.emerald)
                    if rx.targetLoadPounds > 0 {
                        Text("\(rx.targetLoadPounds.cleanWeight) lbs")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(Theme.textDim)
                    }
                } else {
                    Text("\(planned.sets) sets")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textDim)
                }
            }

            swapControl(index: index, planned: planned)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
    }

    /// Letter label ("A", "B", …) for a planned row that sits inside a coached
    /// superset run, so the preview reads the same as the routine editor.
    private func supersetLetter(for planned: PlannedExercise) -> String? {
        guard planned.supersetGroup != nil, let plan else { return nil }
        let runs = supersetRuns(plan.exercises.map(\.id)) { id in
            plan.exercises.first(where: { $0.id == id })?.supersetGroup
        }
        var letter = 0
        for run in runs where run.count > 1 {
            if run.contains(planned.id) {
                return String(UnicodeScalar(UInt8(65 + min(letter, 25))))
            }
            letter += 1
        }
        return nil
    }

    /// Trailing per-row control: a spinner while an AI swap is in flight,
    /// otherwise a menu to swap this one movement (AI or manual) or view details.
    @ViewBuilder
    private func swapControl(index: Int, planned: PlannedExercise) -> some View {
        if swappingIndex == index {
            ProgressView()
                .tint(Theme.emerald)
                .frame(width: 30, height: 30)
        } else {
            Menu {
                Button {
                    Task { await swapWithAI(at: index) }
                } label: {
                    Label("Swap with AI", systemImage: "sparkles")
                }
                Button {
                    Haptics.shared.tick()
                    manualReplaceTarget = ReplaceTarget(index: index)
                } label: {
                    Label("Choose Manually", systemImage: "hand.tap")
                }
                if catalogExercise(for: planned.name) != nil {
                    Divider()
                    Button {
                        guard let exercise = catalogExercise(for: planned.name) else { return }
                        inspectedExercise = detailPayload(for: planned, exercise: exercise)
                    } label: {
                        Label("View Details", systemImage: "info.circle")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(Theme.emerald)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .disabled(isGenerating || swappingIndex != nil)
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        VStack(spacing: 10) {
            if plan == nil {
                Button {
                    Task { await generate() }
                } label: {
                    HStack(spacing: 8) {
                        if isGenerating {
                            ProgressView().tint(.white)
                            Text("GENERATING…")
                        } else {
                            Image(systemName: "sparkles")
                            Text("GENERATE WORKOUT")
                        }
                    }
                    .font(.headline)
                    .kerning(1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .foregroundStyle(.white)
                    .glassCTA(tint: Theme.violet.opacity(0.85))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isGenerating)
            } else {
                HStack(spacing: 12) {
                    Button {
                        Task { await generate() }
                    } label: {
                        Label("Regenerate", systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundStyle(Theme.violet)
                            .glassControl()
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isGenerating)

                    Button {
                        saveAsRoutine()
                    } label: {
                        Label(
                            didSaveRoutine ? "Saved" : "Save Routine",
                            systemImage: didSaveRoutine ? "checkmark.seal.fill" : "square.stack.3d.up"
                        )
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(didSaveRoutine ? Theme.textDim : Theme.emerald)
                        .glassControl()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(didSaveRoutine || isGenerating)

                    Button {
                        startWorkout()
                    } label: {
                        Text("START")
                            .font(.headline)
                            .kerning(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundStyle(.white)
                            .glassCTA(tint: Theme.emerald.opacity(0.85))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if didSaveRoutine {
                    Text("Saved \u{2014} it's on the Train tab whenever you're ready.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textDim)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    // MARK: - Generation

    private func generate() async {
        isGenerating = true
        didSaveRoutine = false
        Haptics.shared.tick()
        let catalog = exercises.map {
            ExerciseBrief(name: $0.name, muscleGroups: $0.allMuscleGroups.map(\.rawValue), equipment: $0.equipmentType)
        }
        // Only assemble the training context when the lifter has opted in —
        // without it `generatePlan` never reaches for the network.
        var context: TrainingContext?
        if let profile = profiles.first, profile.cloudAIEnabled {
            context = TrainingContext.build(
                profile: profile,
                sessions: sessions,
                exercises: exercises,
                withPartner: withPartner
            )
        }

        let result = await WorkoutAI.generatePlan(
            focusLabel: focus.label,
            targetMuscleGroups: focus.targetMuscleGroups,
            exerciseCount: exerciseCount,
            durationMinutes: duration.minutes,
            withPartner: withPartner,
            allowSupersets: allowSupersets,
            context: context,
            catalog: catalog
        )
        isGenerating = false
        withAnimation(.spring(duration: 0.35)) { plan = result }
        Haptics.shared.success()
    }

    /// Asks the AI for a single replacement movement for one slot, keeping the
    /// rest of the plan intact and avoiding anything already in the list.
    private func swapWithAI(at index: Int) async {
        guard let current = plan, current.exercises.indices.contains(index) else { return }
        let outgoing = current.exercises[index]
        swappingIndex = index
        Haptics.shared.tick()
        let catalog = exercises.map {
            ExerciseBrief(name: $0.name, muscleGroups: $0.allMuscleGroups.map(\.rawValue), equipment: $0.equipmentType)
        }
        let existing = Set(current.exercises.map { $0.name.lowercased() })
        let replacement = await WorkoutAI.replaceExercise(
            focusLabel: focus.label,
            targetMuscleGroups: focus.targetMuscleGroups,
            replacing: outgoing.name,
            excluding: existing,
            catalog: catalog
        )
        guard let replacement else { swappingIndex = nil; return }
        // Regenerate the incoming movement's sets/reps/load from its own history
        // so the swapped-in slot carries informed numbers rather than inheriting
        // the outgoing movement's set count with no prescription.
        let regenerated = await regeneratedTargets(forExerciseNamed: replacement)
        swappingIndex = nil
        guard var updated = plan, updated.exercises.indices.contains(index) else { return }
        // Keep the same row id so the swiped row stays put and animates in place
        // instead of being torn down and reinserted (which kills the slide).
        updated.exercises[index] = PlannedExercise(
            id: outgoing.id,
            name: replacement,
            sets: regenerated?.sets ?? outgoing.sets,
            prescription: regenerated?.prescription,
            supersetGroup: outgoing.supersetGroup
        )
        didSaveRoutine = false
        withAnimation(.spring(duration: 0.3)) { plan = updated }
        Haptics.shared.success()
    }

    /// Swaps in a movement the user hand-picked, regenerating its sets/reps/load
    /// from its own history (deterministic fallback) just like the AI swap.
    private func replaceManually(at index: Int, with exercise: Exercise) async {
        let regenerated = await regeneratedTargets(forExerciseNamed: exercise.name)
        guard var updated = plan, updated.exercises.indices.contains(index) else { return }
        let outgoing = updated.exercises[index]
        // Preserve the row id (see swapWithAI) so the update animates in place.
        updated.exercises[index] = PlannedExercise(
            id: outgoing.id,
            name: exercise.name,
            sets: regenerated?.sets ?? outgoing.sets,
            prescription: regenerated?.prescription,
            supersetGroup: outgoing.supersetGroup
        )
        didSaveRoutine = false
        withAnimation(.spring(duration: 0.3)) { plan = updated }
    }

    /// Regenerated set count plus a single-target prescription for a swapped-in
    /// movement, drawn from its own history via AI (deterministic fallback), so a
    /// replaced slot opens on informed reps/load. Nil when the movement isn't in
    /// the catalog or its tracking type has no progression to model.
    private func regeneratedTargets(forExerciseNamed name: String) async -> (sets: Int, prescription: Prescription)? {
        guard let exercise = exercises.first(where: { $0.name.lowercased() == name.lowercased() }),
              let rx = await workout.aiTargets(for: exercise) else { return nil }
        return (
            max(1, rx.sets),
            Prescription(
                repRangeLow: rx.targetReps,
                repRangeHigh: rx.targetReps,
                targetLoadPounds: rx.targetWeightPounds ?? 0,
                restSeconds: 90,
                note: ""
            )
        )
    }

    private func startWorkout() {
        guard let plan else { return }
        let byName = Dictionary(exercises.map { ($0.name.lowercased(), $0) }) { first, _ in first }
        var matched: [Exercise] = []
        var setTargets: [UUID: Int] = [:]
        var repTargets: [UUID: Int] = [:]
        var weightTargets: [UUID: Double] = [:]
        var supersets: [UUID: Int] = [:]
        for planned in plan.exercises {
            guard let exercise = byName[planned.name.lowercased()] else { continue }
            matched.append(exercise)
            setTargets[exercise.id] = max(1, planned.sets)
            if let reps = planned.targetReps { repTargets[exercise.id] = reps }
            if let load = planned.prescription?.targetLoadPounds, load > 0 {
                weightTargets[exercise.id] = load
            }
            if let tag = planned.supersetGroup { supersets[exercise.id] = tag }
        }
        guard !matched.isEmpty else { return }
        onStart(plan.title, matched, setTargets, repTargets, weightTargets, supersets, withPartner)
        dismiss()
    }

    /// Keeps the plan for later instead of starting it now: lands on the Train
    /// launcher's routine shelf as an AI-tagged quick-start card.
    private func saveAsRoutine() {
        guard let plan, !didSaveRoutine else { return }
        let byName = Dictionary(exercises.map { ($0.name.lowercased(), $0) }) { first, _ in first }
        let items = plan.exercises.compactMap { planned -> WorkoutManager.RoutineDraftItem? in
            guard let exercise = byName[planned.name.lowercased()] else { return nil }
            let weight: Double? = {
                guard let load = planned.prescription?.targetLoadPounds, load > 0 else { return nil }
                return load
            }()
            return (exercise, max(1, planned.sets), planned.targetReps, weight, planned.supersetGroup)
        }
        guard !items.isEmpty else { return }
        workout.createRoutine(
            name: plan.title,
            isAIGenerated: true,
            focusLabel: focus.label,
            items: items
        )
        withAnimation(.snappy) { didSaveRoutine = true }
    }

    /// Builds the detail-sheet payload for a plan slot, carrying its slot id,
    /// coached prescription, and resolved rep target so the slider opens in sync.
    private func detailPayload(for planned: PlannedExercise, exercise: Exercise) -> PlannedExerciseDetail {
        PlannedExerciseDetail(
            slotID: planned.id,
            exercise: exercise,
            sets: planned.sets,
            prescription: planned.prescription,
            selectedReps: planned.targetReps
        )
    }

    /// Writes the rep target the lifter picked with the detail-sheet slider back
    /// into the matching plan slot, so the preview and any saved routine agree.
    private func chooseReps(slotID: UUID, reps: Int) {
        guard var updated = plan,
              let idx = updated.exercises.firstIndex(where: { $0.id == slotID }),
              updated.exercises[idx].targetReps != reps else { return }
        updated.exercises[idx].targetReps = reps
        plan = updated
        // A saved routine would no longer match the resolved target on screen.
        didSaveRoutine = false
    }

    /// The splits we nudge the lifter toward: the 2–3 whose target muscles are
    /// the most recovered right now, given the last week of training. Full Body
    /// is excluded so each hint is pointed, a split only qualifies if its muscles
    /// are genuinely fresh, and once one split is picked any later split whose
    /// muscles it already covers is skipped — so we never glow both "Push" and
    /// "Chest". If everything's been trained hard lately, nothing glows.
    private var recommendedFocuses: Set<WorkoutFocus> {
        let statuses = MuscleRecovery.statuses(sessions: sessions)
        // Freshness scores per state: rested/untouched muscles score high, ones
        // still recovering score low, and a muscle that needs rest drags a split
        // down so we never point at something the lifter should let heal.
        func freshness(_ group: MuscleGroup) -> Double {
            switch statuses[group]?.state() ?? .dormant {
            case .dormant:    return 1.0
            case .ready:      return 0.9
            case .recovering: return 0.3
            case .needsRest:  return 0.0
            }
        }

        let scored = WorkoutFocus.allCases
            .filter { $0 != .fullBody }
            .compactMap { focus -> (focus: WorkoutFocus, groups: [MuscleGroup], score: Double)? in
                let groups = focus.targetMuscleGroups.compactMap { MuscleGroup(rawValue: $0) }
                guard !groups.isEmpty else { return nil }
                let score = groups.reduce(0) { $0 + freshness($1) } / Double(groups.count)
                return (focus, groups, score)
            }
            .filter { $0.score >= 0.75 }
            .sorted { $0.score > $1.score }

        var picked: [WorkoutFocus] = []
        var covered: Set<MuscleGroup> = []
        for entry in scored where picked.count < 3 {
            // Skip a split whose muscles a stronger pick already covers.
            guard !Set(entry.groups).isSubset(of: covered) else { continue }
            picked.append(entry.focus)
            covered.formUnion(entry.groups)
        }
        return Set(picked)
    }

    /// The recommended splits' labels in the grid's own order, for the caption.
    private func recommendedLabel(_ focuses: Set<WorkoutFocus>) -> String {
        WorkoutFocus.allCases
            .filter { focuses.contains($0) }
            .map(\.label)
            .joined(separator: " · ")
    }

    private func muscleGroup(for name: String) -> String? {
        catalogExercise(for: name)?.muscleGroupDisplay
    }

    private func catalogExercise(for name: String) -> Exercise? {
        exercises.first { $0.name.lowercased() == name.lowercased() }
    }
}

// MARK: - Focus chip

/// One focus option in the grid. A recommended chip breathes a violet glow —
/// dimming and brightening on a forever loop — to flag it as a fatigue-aware
/// pick. It owns its own animation state so the pulse survives the LazyVGrid's
/// lazy layout, where a sheet-level `@State` toggled in `onAppear` would not.
private struct FocusChip: View {
    let preset: WorkoutFocus
    let isSelected: Bool
    let isRecommended: Bool
    let onTap: () -> Void

    /// Ping-pongs between dim and bright while the chip is recommended.
    @State private var glow = false

    var body: some View {
        Button(action: onTap) {
            Label(preset.label, systemImage: preset.icon)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(isSelected ? .black : .white)
                .background(
                    isSelected ? AnyShapeStyle(Theme.emerald) : AnyShapeStyle(Theme.surfaceRaised),
                    in: RoundedRectangle(cornerRadius: 14)
                )
                .overlay {
                    if isRecommended {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Theme.limitBreakGradient, lineWidth: 2)
                            .opacity(glow ? 1 : 0.35)
                    }
                }
                // A violet bloom that grows from dim to bright and back, so the
                // pick pulses without shouting over the rest of the grid.
                .shadow(
                    color: isRecommended ? Theme.violet.opacity(glow ? 0.95 : 0.15) : .clear,
                    radius: isRecommended ? (glow ? 18 : 3) : 0
                )
        }
        .buttonStyle(.plain)
        .onAppear { updateGlow() }
        .onChange(of: isRecommended) { _, _ in updateGlow() }
    }

    /// Starts or stops the forever-looping pulse to match the chip's state.
    private func updateGlow() {
        if isRecommended {
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) {
                glow = true
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { glow = false }
        }
    }
}

// MARK: - Planned exercise detail

/// What one plan entry actually asks of you: the movement's guide plus the
/// load to aim for. When the coach handed down a prescription we show that
/// exactly — with a slider to resolve its rep range — so this matches the plan
/// row and the saved routine. Without one, we fall back to your own history.
struct PlannedExerciseSheet: View {
    @Environment(\.dismiss) private var dismiss

    let exercise: Exercise
    let plannedSets: Int
    /// The coach's prescription for this slot, or nil for on-device/library picks.
    let prescription: Prescription?
    /// Whether a spotter is on hand — licenses a heavier prescription on the
    /// free-weight lifts where a spot actually changes what's safe to attempt.
    var withPartner = false
    /// Called as the lifter drags the rep slider, so the plan row and any saved
    /// routine can track the resolved target.
    var onChooseReps: (Int) -> Void = { _ in }

    /// The rep target the slider currently sits on, within the range.
    @State private var chosenReps: Int

    init(
        exercise: Exercise,
        plannedSets: Int,
        prescription: Prescription? = nil,
        selectedReps: Int? = nil,
        withPartner: Bool = false,
        onChooseReps: @escaping (Int) -> Void = { _ in }
    ) {
        self.exercise = exercise
        self.plannedSets = plannedSets
        self.prescription = prescription
        self.withPartner = withPartner
        self.onChooseReps = onChooseReps
        _chosenReps = State(initialValue: selectedReps ?? prescription?.repRangeHigh ?? 0)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                recommendationCard

                if let about = exercise.exerciseDescription, !about.isEmpty {
                    sectionLabel("ABOUT")
                    Text(about)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardStyle()
                }

                let steps = exercise.instructionSteps
                if !steps.isEmpty {
                    sectionLabel("HOW TO PERFORM")
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.system(.caption, design: .rounded, weight: .black))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.emerald)
                                    .frame(width: 22, height: 22)
                                    .background(Theme.emerald.opacity(0.12), in: Circle())
                                Text(step)
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardStyle()
                }
            }
            .padding()
        }
        .obsidianBackground()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: exercise.muscleGroup.iconName)
                .font(.title3)
                .foregroundStyle(Theme.teal)
                .frame(width: 44, height: 44)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.name)
                    .font(.title3.bold())
                Text("\(exercise.muscleGroupDisplay) \u{00B7} \(exercise.equipmentType)")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .glassCircle()
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .kerning(1.5)
            .foregroundStyle(Theme.textDim)
            .padding(.top, 6)
    }

    // MARK: Recommendation

    /// The plan's prescription. With a coached prescription we show its exact
    /// sets/reps/load and let the lifter resolve the rep range on a slider;
    /// otherwise we fall back to a load drawn from their own history.
    private var recommendationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption)
                Text("THE PLAN WANTS")
                    .font(.caption.weight(.bold))
                    .kerning(1.5)
            }
            .foregroundStyle(Theme.violet)

            if let rx = prescription {
                prescriptionContent(rx)
            } else {
                Text(recommendationText)
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .monospacedDigit()

                Text(recommendationHint)
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Theme.limitBreakGradient, lineWidth: 1)
                .opacity(0.4)
        )
    }

    /// The coach's exact prescription, with a rep slider when the range spans
    /// more than a single value.
    @ViewBuilder
    private func prescriptionContent(_ rx: Prescription) -> some View {
        Text(prescriptionHeadline(rx))
            .font(.system(.title3, design: .rounded, weight: .bold))
            .monospacedDigit()

        if rx.repRangeLow < rx.repRangeHigh {
            repSlider(rx)
        }

        if !rx.note.isEmpty {
            Text(rx.note)
                .font(.caption)
                .foregroundStyle(Theme.textDim)
        }
    }

    /// "3 sets × 8 reps × 185 lbs" — the resolved target, load included when loaded.
    private func prescriptionHeadline(_ rx: Prescription) -> String {
        var text = "\(plannedSets) sets \u{00D7} \(chosenReps) rep\(chosenReps == 1 ? "" : "s")"
        if rx.targetLoadPounds > 0 {
            text += " \u{00D7} \(rx.targetLoadPounds.cleanWeight) lbs"
        }
        return text
    }

    /// Themed slider that resolves the coach's rep range to a single target.
    private func repSlider(_ rx: Prescription) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TARGET REPS")
                    .font(.caption2.weight(.bold))
                    .kerning(1)
                    .foregroundStyle(Theme.textDim)
                Spacer()
                Text("\(chosenReps)")
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.emerald)
            }
            Slider(
                value: Binding(
                    get: { Double(chosenReps) },
                    set: { newValue in
                        let resolved = Int(newValue.rounded())
                        guard resolved != chosenReps else { return }
                        chosenReps = resolved
                        Haptics.shared.tick()
                        onChooseReps(resolved)
                    }
                ),
                in: Double(rx.repRangeLow)...Double(rx.repRangeHigh),
                step: 1
            )
            .tint(Theme.emerald)
            HStack {
                Text("\(rx.repRangeLow)")
                Spacer()
                Text("\(rx.repRangeHigh)")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(Theme.textDim)
        }
        .padding(.top, 4)
    }

    /// Most recent non-warmup set, from any session.
    private var lastWorkingSet: ExerciseSet? {
        exercise.sets
            .filter { !$0.isWarmup }
            .max(by: { $0.timestamp < $1.timestamp })
    }

    /// Whether the spotter bump is actually in play here: a partner was declared
    /// AND this is a movement a spot changes the math on.
    private var spotterApplies: Bool {
        withPartner && exercise.benefitsFromSpotter
    }

    private var recommendationText: String {
        switch exercise.trackingType {
        case .weightAndReps, .bodyweightAndReps, .customMetric:
            if let last = lastWorkingSet, last.weight != 0 {
                let load = spotterApplies ? exercise.spottedLoad(fromPounds: last.weight) : last.weight
                return "\(plannedSets) sets \u{00D7} \(load.cleanWeight) lbs \u{00D7} \(last.reps)"
            }
            let ceiling = exercise.ceiling(for: "1RM")
            if ceiling > 0 {
                // A spotter buys a working set closer to the ceiling: 82% vs 75%.
                let fraction = spotterApplies ? 0.82 : 0.75
                let suggested = (ceiling * fraction / exercise.defaultIncrement).rounded() * exercise.defaultIncrement
                return "\(plannedSets) sets \u{00D7} \(suggested.cleanWeight) lbs \u{00D7} 8"
            }
            return "\(plannedSets) sets \u{00D7} 8 reps"
        case .durationAndReps:
            let seconds = lastWorkingSet?.durationSeconds ?? 30
            return "\(plannedSets) sets \u{00D7} \(seconds.clockString)"
        case .durationOnly:
            let seconds = lastWorkingSet?.durationSeconds ?? 30
            return "\(plannedSets) sets \u{00D7} \(seconds.clockString) hold"
        case .timeAndDistance:
            return "\(plannedSets) round\(plannedSets == 1 ? "" : "s")"
        }
    }

    private var recommendationHint: String {
        if spotterApplies {
            if let last = lastWorkingSet, last.weight != 0 {
                return "Bumped above your last working set \u{2014} your partner\u{2019}s spotting, so chase the extra plate."
            }
            if exercise.ceiling(for: "1RM") > 0 {
                return "About 82% of your ceiling \u{2014} heavier than solo, because you\u{2019}ve got a spotter."
            }
        }
        if withPartner && !exercise.benefitsFromSpotter {
            return "A spot doesn\u{2019}t change this one \u{2014} same load as solo."
        }
        if let last = lastWorkingSet, last.weight != 0 {
            return "Matched to your last working set \u{2014} beat it and the ceiling moves."
        }
        if exercise.ceiling(for: "1RM") > 0 {
            return "About 75% of your recorded ceiling \u{2014} room to push."
        }
        return "No history yet \u{2014} start light and find your groove."
    }
}

// MARK: - Swipeable plan row

/// A single AI-plan row that slides horizontally to reveal a replace action:
/// swipe right for "Replace with AI", swipe left for "Replace Manually". Taps
/// and the row's own buttons still work; vertical drags pass through to scroll.
private struct SwipeablePlanRow<Content: View>: View {
    let isEnabled: Bool
    let onReplaceAI: () -> Void
    let onReplaceManual: () -> Void
    @ViewBuilder var content: Content

    /// How far the finger must travel before a release fires the action.
    private let triggerDistance: CGFloat = 96
    /// Where the slide starts rubber-banding, so it never runs off the card.
    private let maxReveal: CGFloat = 150

    @State private var offset: CGFloat = 0
    @State private var armed = false

    var body: some View {
        ZStack {
            actionsLayer
            content
                // Opaque surface so the reveal panel behind it never bleeds
                // through the row while it's resting.
                .background(Theme.surface)
                .contentShape(Rectangle())
                .offset(x: offset)
                // A UIKit pan recognizer that *fails* the instant a drag is
                // vertical-dominant, handing the touch back to the enclosing
                // ScrollView so the list scrolls no matter where the finger
                // lands. A SwiftUI DragGesture (even a simultaneous one) can't
                // bow out of a vertical pan on demand, so it kept swallowing
                // scrolls that started on a card; this recognizer only ever
                // claims horizontal swipes. Taps still reach the row's own
                // Button/Menu untouched.
                .gesture(horizontalSwipe)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.glassBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
    }

    // MARK: Reveal

    private var swipingRight: Bool { offset > 0 }
    private var progress: CGFloat { min(1, abs(offset) / triggerDistance) }

    private var actionsLayer: some View {
        // Accent gradient panel that deepens as you pull further, so the reveal
        // reads clearly against the obsidian background. Violet→gold = AI (swipe
        // right), teal→emerald = manual (swipe left); each flows toward the edge
        // it reveals.
        return ZStack {
            revealGradient
                .opacity(0.55 + 0.45 * progress)

            HStack {
                if swipingRight {
                    actionLabel("Replace with AI", systemImage: "sparkles")
                    Spacer()
                } else {
                    Spacer()
                    actionLabel("Replace Manually", systemImage: "hand.tap")
                }
            }
            .padding(.horizontal, 20)
        }
        .opacity(offset == 0 ? 0 : 1)
    }

    /// Direction-aware accent gradient: brightest at the edge being revealed,
    /// fading toward the row's center.
    private var revealGradient: LinearGradient {
        LinearGradient(
            colors: swipingRight
                ? [Theme.violet, Theme.gold]
                : [Theme.emerald, Theme.teal],
            startPoint: swipingRight ? .leading : .trailing,
            endPoint: swipingRight ? .trailing : .leading
        )
    }

    private func actionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .opacity(0.6 + 0.4 * progress)
            .scaleEffect(armed ? 1.08 : 1)
            .animation(.snappy(duration: 0.2), value: armed)
    }

    // MARK: Gesture

    /// The horizontal swipe, backed by a directional UIKit pan recognizer. The
    /// recognizer guarantees these callbacks only fire for horizontal-dominant
    /// drags — a vertical drag fails the recognizer before it reaches us and
    /// scrolls the list instead — so no directional guard is needed here.
    private var horizontalSwipe: HorizontalSwipeGesture {
        HorizontalSwipeGesture(
            isEnabled: isEnabled,
            onChanged: { translationX in
                offset = rubberBanded(translationX)
                let nowArmed = abs(offset) >= triggerDistance
                if nowArmed != armed {
                    armed = nowArmed
                    Haptics.shared.tick()
                }
            },
            onEnded: { translationX in
                let fired = abs(translationX) >= triggerDistance
                let goRight = translationX > 0
                armed = false
                withAnimation(.spring(duration: 0.35)) { offset = 0 }
                if fired {
                    Haptics.shared.logSet()
                    if goRight { onReplaceAI() } else { onReplaceManual() }
                }
            }
        )
    }

    /// Eases resistance past `maxReveal` so the row can't be dragged off the card.
    private func rubberBanded(_ x: CGFloat) -> CGFloat {
        guard abs(x) > maxReveal else { return x }
        let sign: CGFloat = x < 0 ? -1 : 1
        return sign * (maxReveal + (abs(x) - maxReveal) * 0.25)
    }
}

// MARK: - Directional swipe gesture

/// A `UIPanGestureRecognizer` that only survives for horizontal-dominant drags.
/// The first time a touch travels far enough to judge its direction, a
/// mostly-vertical drag fails the recognizer, which lets the enclosing
/// `ScrollView` take over and scroll — so a swipe row never traps a vertical
/// pan the way a SwiftUI `DragGesture` would.
private final class HorizontalPanGestureRecognizer: UIPanGestureRecognizer {
    /// The touch's starting point, cleared once direction has been decided.
    private var startLocation: CGPoint?

    override func reset() {
        super.reset()
        startLocation = nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        startLocation = touches.first?.location(in: view)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let start = startLocation,
              let current = touches.first?.location(in: view) else { return }
        let dx = current.x - start.x
        let dy = current.y - start.y
        // Wait for enough travel to reliably tell horizontal from vertical.
        guard abs(dx) + abs(dy) >= 8 else { return }
        startLocation = nil // decided — don't re-evaluate for this touch
        if abs(dy) > abs(dx) {
            state = .failed
        }
    }
}

/// Bridges `HorizontalPanGestureRecognizer` into SwiftUI, reporting the running
/// horizontal translation as the finger moves and the final translation on
/// release. Attached with `.gesture(_:)`.
private struct HorizontalSwipeGesture: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> HorizontalPanGestureRecognizer {
        HorizontalPanGestureRecognizer()
    }

    func updateUIGestureRecognizer(_ recognizer: HorizontalPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: HorizontalPanGestureRecognizer, context: Context) {
        let translationX = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed:
            onChanged(translationX)
        case .ended, .cancelled, .failed:
            onEnded(translationX)
        default:
            break
        }
    }
}

// MARK: - Swipe-back disabler

/// Disables the enclosing navigation controller's left-edge back-swipe so that
/// custom rightward swipe gestures (swipe-right-to-replace) aren't swallowed by
/// the system before our swipe recognizer can see them.
private struct SwipeBackDisabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.disableSwipeBack()
    }

    final class Controller: UIViewController {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            disableSwipeBack()
        }

        func disableSwipeBack() {
            // Walk up to the nearest navigation controller and switch off its
            // interactive pop recognizer.
            var responder: UIViewController? = navigationController ?? parent
            while let current = responder {
                if let nav = current as? UINavigationController {
                    nav.interactivePopGestureRecognizer?.isEnabled = false
                    return
                }
                responder = current.parent ?? current.navigationController
            }
        }
    }
}
