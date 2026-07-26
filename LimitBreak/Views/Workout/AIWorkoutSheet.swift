import SwiftUI
import SwiftData
import UIKit

/// Asks the user what to focus on and how much to do, then generates a
/// tappable workout on-device and hands it back to start a session.
struct AIWorkoutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkoutManager.self) private var workout
    @Query(sort: \Exercise.name) private var exercises: [Exercise]

    /// Called with the generated session title, the ordered exercises to load,
    /// and whether the session is being trained with a partner.
    let onStart: (String, [Exercise], Bool) -> Void

    @State private var focus: WorkoutFocus = .fullBody
    @State private var exerciseCount = 5
    @State private var duration: WorkoutLength = .any
    @State private var withPartner = false
    @State private var plan: WorkoutPlan?
    @State private var isGenerating = false
    @State private var didSaveRoutine = false
    @State private var inspectedExercise: PlannedExerciseDetail?
    @State private var manualReplaceTarget: ReplaceTarget?
    @State private var swappingIndex: Int?

    /// Sheet payload for one tapped plan row: the matched catalog movement
    /// plus how many sets the plan calls for.
    struct PlannedExerciseDetail: Identifiable {
        let exercise: Exercise
        let sets: Int
        var id: UUID { exercise.id }
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
            .sheet(item: $inspectedExercise) { detail in
                PlannedExerciseSheet(
                    exercise: detail.exercise,
                    plannedSets: detail.sets,
                    withPartner: withPartner
                )
            }
            .sheet(item: $manualReplaceTarget) { target in
                ExercisePickerSheet { picked in
                    replaceManually(at: target.index, with: picked)
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                    ForEach(WorkoutFocus.allCases) { preset in
                        focusChip(preset)
                    }
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

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textDim)
                .kerning(1)
            content()
        }
    }

    private func focusChip(_ preset: WorkoutFocus) -> some View {
        let selected = focus == preset
        return Button {
            focus = preset
            Haptics.shared.tick()
        } label: {
            Label(preset.label, systemImage: preset.icon)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(selected ? .black : .white)
                .background(
                    selected ? AnyShapeStyle(Theme.emerald) : AnyShapeStyle(Theme.surfaceRaised),
                    in: RoundedRectangle(cornerRadius: 14)
                )
        }
        .buttonStyle(.plain)
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
                inspectedExercise = PlannedExerciseDetail(exercise: exercise, sets: planned.sets)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(planned.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    if let muscle = muscleGroup(for: planned.name) {
                        Text(muscle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("\(planned.sets) sets")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textDim)

            swapControl(index: index, planned: planned)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
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
                        inspectedExercise = PlannedExerciseDetail(exercise: exercise, sets: planned.sets)
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
        let result = await WorkoutAI.generatePlan(
            focusLabel: focus.label,
            targetMuscleGroups: focus.targetMuscleGroups,
            exerciseCount: exerciseCount,
            durationMinutes: duration.minutes,
            withPartner: withPartner,
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
        swappingIndex = nil
        guard let replacement,
              var updated = plan,
              updated.exercises.indices.contains(index) else { return }
        // Keep the same row id so the swiped row stays put and animates in place
        // instead of being torn down and reinserted (which kills the slide).
        updated.exercises[index] = PlannedExercise(id: outgoing.id, name: replacement, sets: outgoing.sets)
        didSaveRoutine = false
        withAnimation(.spring(duration: 0.3)) { plan = updated }
        Haptics.shared.success()
    }

    /// Swaps in a movement the user hand-picked, preserving the slot's set count.
    private func replaceManually(at index: Int, with exercise: Exercise) {
        guard var updated = plan, updated.exercises.indices.contains(index) else { return }
        let outgoing = updated.exercises[index]
        // Preserve the row id (see swapWithAI) so the update animates in place.
        updated.exercises[index] = PlannedExercise(id: outgoing.id, name: exercise.name, sets: outgoing.sets)
        didSaveRoutine = false
        withAnimation(.spring(duration: 0.3)) { plan = updated }
    }

    private func startWorkout() {
        guard let plan else { return }
        let byName = Dictionary(exercises.map { ($0.name.lowercased(), $0) }) { first, _ in first }
        let matched = plan.exercises.compactMap { byName[$0.name.lowercased()] }
        guard !matched.isEmpty else { return }
        onStart(plan.title, matched, withPartner)
        dismiss()
    }

    /// Keeps the plan for later instead of starting it now: lands on the Train
    /// launcher's routine shelf as an AI-tagged quick-start card.
    private func saveAsRoutine() {
        guard let plan, !didSaveRoutine else { return }
        let byName = Dictionary(exercises.map { ($0.name.lowercased(), $0) }) { first, _ in first }
        let items = plan.exercises.compactMap { planned -> (exercise: Exercise, targetSets: Int)? in
            guard let exercise = byName[planned.name.lowercased()] else { return nil }
            return (exercise, max(1, planned.sets))
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

    private func muscleGroup(for name: String) -> String? {
        catalogExercise(for: name)?.muscleGroupDisplay
    }

    private func catalogExercise(for name: String) -> Exercise? {
        exercises.first { $0.name.lowercased() == name.lowercased() }
    }
}

// MARK: - Planned exercise detail

/// What one plan entry actually asks of you: the movement's guide plus the
/// load to aim for, drawn from your own history.
struct PlannedExerciseSheet: View {
    @Environment(\.dismiss) private var dismiss

    let exercise: Exercise
    let plannedSets: Int
    /// Whether a spotter is on hand — licenses a heavier prescription on the
    /// free-weight lifts where a spot actually changes what's safe to attempt.
    var withPartner = false

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

    /// The plan's prescription: sets, and a load drawn from what you actually
    /// lifted last time (or a conservative fraction of your ceiling).
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

            Text(recommendationText)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .monospacedDigit()

            Text(recommendationHint)
                .font(.caption)
                .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Theme.limitBreakGradient, lineWidth: 1)
                .opacity(0.4)
        )
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
                // simultaneousGesture (not .gesture) so the swipe is recognized
                // alongside the row's own tap Button/Menu and the ScrollView's
                // vertical pan, instead of being swallowed by them.
                .simultaneousGesture(swipeGesture, including: isEnabled ? .all : .subviews)
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

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                // Let mostly-vertical drags scroll the list instead.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                offset = rubberBanded(value.translation.width)
                let nowArmed = abs(offset) >= triggerDistance
                if nowArmed != armed {
                    armed = nowArmed
                    Haptics.shared.tick()
                }
            }
            .onEnded { value in
                let horizontal = abs(value.translation.width) > abs(value.translation.height)
                let fired = horizontal && abs(value.translation.width) >= triggerDistance
                let goRight = value.translation.width > 0
                armed = false
                withAnimation(.spring(duration: 0.35)) { offset = 0 }
                if fired {
                    Haptics.shared.logSet()
                    if goRight { onReplaceAI() } else { onReplaceManual() }
                }
            }
    }

    /// Eases resistance past `maxReveal` so the row can't be dragged off the card.
    private func rubberBanded(_ x: CGFloat) -> CGFloat {
        guard abs(x) > maxReveal else { return x }
        let sign: CGFloat = x < 0 ? -1 : 1
        return sign * (maxReveal + (abs(x) - maxReveal) * 0.25)
    }
}

// MARK: - Swipe-back disabler

/// Disables the enclosing navigation controller's left-edge back-swipe so that
/// custom rightward swipe gestures (swipe-right-to-replace) aren't swallowed by
/// the system before our `DragGesture` can see them.
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
