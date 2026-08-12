import SwiftUI
import SwiftData

/// One plan day: an image-forward list of its exercises. Tap any exercise to
/// edit its sets, reps, and working weight (or swap it with AI). If a workout
/// was already logged on this weekday, the session is linked at the top and the
/// day reads as completed.
struct PlannedDayDetailView: View {
    @Environment(WorkoutManager.self) private var workout
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var sessions: [WorkoutSession]
    @Query private var profiles: [TrainingProfile]

    let day: PlannedDay

    @State private var editing: EditTarget?
    @State private var showPicker = false
    @State private var isRegenerating = false
    /// Stable in-memory mirror of the slots that the reorder stack reads and
    /// writes. The native drag container can't resolve item identities against a
    /// freshly-recomputed collection (`routine.orderedItems` re-sorts the live
    /// SwiftData relationship on every access) — that traps at drag lift. Seeded
    /// from the routine and reseeded when the set of slots changes.
    @State private var rows: [RoutineItem] = []

    /// Identifiable wrapper so a tapped slot can drive `.sheet(item:)`.
    private struct EditTarget: Identifiable {
        let id: UUID
        let item: RoutineItem
    }

    /// The current set of slot ids — drives reseeding when membership changes.
    private var membership: Set<UUID> {
        Set(day.routine?.items.map(\.id) ?? [])
    }

    /// Rebuilds the stable mirror from the routine's persisted order, dropping any
    /// slot whose exercise was deleted so every reorder row renders a real card.
    private func reseed() {
        rows = (day.routine?.orderedItems ?? []).filter { $0.exercise != nil }
    }

    /// Binding the reorder stack reads and writes; each drop persists the new
    /// order. Backed by the stable `rows` mirror (not a recomputed collection) so
    /// the native drag container can resolve identities at lift.
    private var itemsBinding: Binding<[RoutineItem]> {
        Binding(
            get: { rows },
            set: { newRows in
                rows = newRows
                workout.reorderRoutineItems(newRows)
            }
        )
    }

    /// The workout logged on this weekday this week, if any.
    private var loggedSession: WorkoutSession? {
        PlanCompletion.sessionsByWeekday(from: sessions)[day.weekday]
    }

    private var isDone: Bool { loggedSession != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let session = loggedSession {
                    loggedWorkoutCard(session)
                }

                if let routine = day.routine, !routine.orderedItems.isEmpty {
                    exerciseList(routine)
                } else {
                    Text("This day has no exercises yet. Add some, or regenerate with AI.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textDim)
                }

                actions
            }
            .padding()
        }
        .obsidianBackground()
        .navigationTitle(PlanWeekday.name(day.weekday))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reseed)
        .onChange(of: membership) { _, _ in reseed() }
        .sheet(item: $editing) { target in
            PlanExerciseEditorSheet(item: target.item, catalog: exercises)
        }
        .sheet(isPresented: $showPicker) {
            ExercisePickerSheet { exercise in
                if let routine = day.routine {
                    workout.addExercise(exercise, to: routine)
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(day.focus.label)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Theme.limitBreakGradient)
            if isDone {
                Label("Completed this week", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.emerald)
            } else if let routine = day.routine {
                Text("\(routine.exerciseCount) movement\(routine.exerciseCount == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Logged workout link

    private func loggedWorkoutCard(_ session: WorkoutSession) -> some View {
        NavigationLink(value: session) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.emerald)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.name)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("Trained \(session.startDate.formatted(date: .abbreviated, time: .shortened)) · view report")
                        .font(.caption2)
                        .foregroundStyle(Theme.textDim)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.emerald.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.emerald.opacity(0.3), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    // MARK: Exercises

    private func exerciseList(_ routine: Routine) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ReorderableVStack(itemsBinding, spacing: 14) { $item, grip in
                reorderableCard(item, grip: grip)
            }

            Text("Drag \u{2261} to reorder · tap an exercise to edit")
                .font(.caption2)
                .foregroundStyle(Theme.textDim)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// Each reorderable row must be an UNCONDITIONAL view. A top-level `if let`
    /// here makes the `ForEach` child a conditional view, which breaks the native
    /// drag container's payload identity mapping and traps at lift ("Unexpected
    /// identifier type"). So the row is always a `Button`; the exercise lookup is
    /// nested inside the label (and exercise-less slots are filtered out upstream).
    private func reorderableCard(_ item: RoutineItem, grip: ReorderGrip) -> some View {
        Button {
            guard item.exercise != nil else { return }
            Haptics.shared.tick()
            editing = EditTarget(id: item.id, item: item)
        } label: {
            cardLabel(item)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            grip
                .background(.ultraThinMaterial, in: Circle())
                .padding(8)
        }
    }

    @ViewBuilder
    private func cardLabel(_ item: RoutineItem) -> some View {
        if let exercise = item.exercise {
            PlanExerciseCard(exercise: exercise, target: targetText(item))
        } else {
            Color.clear.frame(height: 1)
        }
    }

    private func targetText(_ item: RoutineItem) -> String {
        var text = "\(item.targetSets) × \(item.targetReps.map(String.init) ?? "—")"
        if let weight = item.targetWeight, weight > 0 {
            text += "  ·  \(Int(weight)) lb"
        }
        return text
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                guard let routine = day.routine else { return }
                Haptics.shared.tick()
                workout.startSession(from: routine, withPartner: day.plan?.withPartner ?? false)
            } label: {
                actionLabel(isDone ? "TRAIN AGAIN" : "START SESSION",
                            icon: isDone ? "arrow.clockwise" : "play.fill",
                            filled: true)
            }
            .buttonStyle(.plain)
            .disabled(day.routine?.orderedItems.isEmpty ?? true)

            Button {
                Haptics.shared.tick()
                showPicker = true
            } label: {
                actionLabel("ADD EXERCISE", icon: "plus.circle.fill", filled: false)
            }
            .buttonStyle(.plain)

            Button {
                Task { await regenerate() }
            } label: {
                HStack(spacing: 8) {
                    if isRegenerating {
                        ProgressView().tint(Theme.violet)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(isRegenerating ? "REGENERATING…" : "REGENERATE WITH AI")
                        .font(.subheadline.weight(.semibold))
                        .kerning(0.8)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(Theme.violet)
                .glassControl()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isRegenerating)
        }
    }

    private func actionLabel(_ title: String, icon: String, filled: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(title).font(.headline).kerning(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .foregroundStyle(filled ? .white : Theme.emerald)
        .modifier(FilledOrGlass(filled: filled))
        .contentShape(Rectangle())
    }

    private struct FilledOrGlass: ViewModifier {
        let filled: Bool
        func body(content: Content) -> some View {
            if filled {
                content.glassCTA(tint: Theme.emerald.opacity(0.85))
            } else {
                content.glassControl()
            }
        }
    }

    // MARK: Regenerate

    private func regenerate() async {
        isRegenerating = true
        Haptics.shared.tick()
        let plan = day.plan
        let generated = await PlanBuilding.generateDay(
            focus: day.focus,
            exercisesPerDay: plan?.exercisesPerDay ?? 5,
            duration: plan?.duration ?? .any,
            withPartner: plan?.withPartner ?? false,
            allowSupersets: plan?.allowSupersets ?? true,
            exercises: exercises,
            sessions: sessions,
            profile: profiles.first
        )
        isRegenerating = false
        guard let generated, !generated.items.isEmpty else { return }
        workout.replacePlanDayRoutine(day, title: generated.title, items: generated.items)
        Haptics.shared.success()
    }
}

// MARK: - Exercise card

/// Image-forward card for one planned exercise, matching the history detail
/// look: a full-width illustration, muscle badge, name, and the set/rep/weight
/// target. Tapping it opens the per-exercise editor.
private struct PlanExerciseCard: View {
    let exercise: Exercise
    let target: String

    var body: some View {
        VStack(spacing: 0) {
            ExerciseImageBanner(exercise: exercise, height: 140)
            infoSection
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.glassBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .overlay(alignment: .topLeading) {
            MuscleBadge(exercise: exercise)
                .padding(10)
        }
    }

    private var infoSection: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(exercise.name)
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                Text(target)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.emerald)
            }
            Spacer(minLength: 4)
            Image(systemName: "slider.horizontal.3")
                .font(.subheadline)
                .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }
}

// MARK: - Per-exercise editor

/// Edits a single planned slot: its set count, target reps, and working weight,
/// with an option to swap the movement for an AI-picked alternative. Writes back
/// to the routine item in place on save.
private struct PlanExerciseEditorSheet: View {
    @Environment(WorkoutManager.self) private var workout
    @Environment(\.dismiss) private var dismiss

    let item: RoutineItem
    let catalog: [Exercise]

    @State private var sets: Int
    @State private var reps: Int
    @State private var weight: Double
    @State private var isSwapping = false
    @State private var showManualPicker = false
    @State private var showHowTo = false

    init(item: RoutineItem, catalog: [Exercise]) {
        self.item = item
        self.catalog = catalog
        _sets = State(initialValue: max(1, item.targetSets))
        _reps = State(initialValue: item.targetReps ?? 8)
        _weight = State(initialValue: item.targetWeight ?? 0)
    }

    private var exercise: Exercise? { item.exercise }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    if let exercise {
                        ExerciseImageBanner(exercise: exercise, height: 200, blendsIntoBackground: true)
                            .overlay(alignment: .bottomLeading) {
                                MuscleBadge(exercise: exercise)
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 12)
                            }
                    }

                    VStack(alignment: .leading, spacing: 20) {
                        Text(exercise?.name ?? "Exercise")
                            .font(.title2.weight(.bold))

                        howToPerform

                        stepperRow("Sets", value: $sets, range: 1...12)
                        stepperRow("Target reps", value: $reps, range: 1...30)

                        if exercise?.usesWeightUnit ?? false {
                            weightRow
                        }

                        swapButton
                        manualReplaceButton
                        removeButton
                    }
                    .padding()
                }
            }
            .obsidianBackground()
            .navigationTitle("Edit Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showManualPicker) {
                ExercisePickerSheet { replacement in
                    Task {
                        await workout.setRoutineItemExercise(item, to: replacement)
                        dismiss()
                    }
                }
            }
        }
    }

    /// Collapsible how-to for the slotted movement, mirroring the exercise history
    /// sheet: the movement's guide description followed by numbered steps.
    @ViewBuilder
    private var howToPerform: some View {
        if let exercise {
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
    }

    private func stepperRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text("\(value.wrappedValue)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(Theme.emerald)
                .frame(minWidth: 40, alignment: .trailing)
            Stepper(title, value: value, in: range)
                .labelsHidden()
                .tint(Theme.emerald)
        }
        .padding(14)
        .glassControl(cornerRadius: 16)
    }

    private var weightRow: some View {
        let increment = exercise?.defaultIncrement ?? 5
        return HStack {
            Text("Working weight")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button {
                weight = max(0, weight - increment)
                Haptics.shared.tick()
            } label: {
                Image(systemName: "minus.circle.fill").font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textDim)

            Text(weight > 0 ? "\(Int(weight)) lb" : "—")
                .font(.headline.monospacedDigit())
                .foregroundStyle(Theme.emerald)
                .frame(minWidth: 68)

            Button {
                weight += increment
                Haptics.shared.tick()
            } label: {
                Image(systemName: "plus.circle.fill").font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.emerald)
        }
        .padding(14)
        .glassControl(cornerRadius: 16)
    }

    private var swapButton: some View {
        Button {
            Task { await swapWithAI() }
        } label: {
            HStack(spacing: 8) {
                if isSwapping {
                    ProgressView().tint(Theme.violet)
                } else {
                    Image(systemName: "sparkles")
                }
                Text(isSwapping ? "SWAPPING…" : "SWAP WITH AI")
                    .font(.subheadline.weight(.semibold))
                    .kerning(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(Theme.violet)
            .glassControl()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSwapping)
    }

    /// Manual counterpart to the AI swap: pick any movement from the catalog to
    /// slot in, keeping the AI out of the loop.
    private var manualReplaceButton: some View {
        Button {
            Haptics.shared.tick()
            showManualPicker = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("REPLACE MANUALLY")
                    .font(.subheadline.weight(.semibold))
                    .kerning(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(Theme.emerald)
            .glassControl()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSwapping)
    }

    private var removeButton: some View {
        Button(role: .destructive) {
            workout.removeRoutineItem(item)
            dismiss()
        } label: {
            Label("Remove Exercise", systemImage: "trash")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(Theme.crimson)
                .glassControl()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func save() {
        workout.updateRoutineItem(
            item,
            targetSets: sets,
            targetReps: reps,
            targetWeight: weight > 0 ? weight : nil
        )
        dismiss()
    }

    /// Asks the AI for one on-muscle replacement from the catalog and swaps it in.
    private func swapWithAI() async {
        guard let outgoing = exercise else { return }
        isSwapping = true
        Haptics.shared.tick()
        let briefs = catalog.map {
            ExerciseBrief(name: $0.name, muscleGroups: $0.allMuscleGroups.map(\.rawValue), equipment: $0.equipmentType, isPerHand: $0.isPerHand)
        }
        let replacementName = await WorkoutAI.replaceExercise(
            focusLabel: item.routine?.focusLabel ?? "",
            targetMuscleGroups: outgoing.allMuscleGroups.map(\.rawValue),
            replacing: outgoing.name,
            excluding: [outgoing.name.lowercased()],
            catalog: briefs
        )
        guard let replacementName,
              let replacement = catalog.first(where: { $0.name.lowercased() == replacementName.lowercased() })
        else { isSwapping = false; return }
        await workout.setRoutineItemExercise(item, to: replacement)
        isSwapping = false
        dismiss()
    }
}
