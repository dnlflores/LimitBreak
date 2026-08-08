import SwiftUI
import SwiftData

/// Rich, day-view-parity editor for a single saved routine. Image-forward
/// exercise cards, tap-to-edit sets / reps / weight (or AI-swap), drag-to-reorder,
/// add-exercise, whole-routine AI generation, inline rename, and a Start button.
/// Every edit persists in place through `WorkoutManager`.
///
/// Note: the exercise card and per-exercise editor here mirror
/// `PlannedDayDetailView`'s `PlanExerciseCard` / `PlanExerciseEditorSheet`. They're
/// intentionally duplicated rather than shared, to keep this view decoupled from
/// the actively-evolving Plan tab; a future cleanup could extract one shared card.
struct RoutineDetailView: View {
    @Environment(WorkoutManager.self) private var workout
    @Query(sort: \Exercise.name) private var exercises: [Exercise]

    let routine: Routine

    @State private var name: String
    @State private var editing: EditTarget?
    @State private var showPicker = false
    @State private var showAIGenerator = false
    /// Stable in-memory mirror of the slots that the reorder stack reads and
    /// writes. The native drag container can't resolve item identities against a
    /// freshly-recomputed collection (`routine.orderedItems` re-sorts the live
    /// SwiftData relationship on every access) — that traps at drag lift. Seeded
    /// from the routine and reseeded when the set of slots changes.
    @State private var rows: [RoutineItem] = []

    init(routine: Routine) {
        self.routine = routine
        _name = State(initialValue: routine.name)
    }

    /// Identifiable wrapper so a tapped slot can drive `.sheet(item:)`.
    private struct EditTarget: Identifiable {
        let id: UUID
        let item: RoutineItem
    }

    /// The current set of slot ids — drives reseeding when membership changes.
    private var membership: Set<UUID> { Set(routine.items.map(\.id)) }

    /// Rebuilds the stable mirror from the routine's persisted order, dropping any
    /// slot whose exercise was deleted so every reorder row renders a real card.
    private func reseed() {
        rows = routine.orderedItems.filter { $0.exercise != nil }
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if !routine.orderedItems.isEmpty {
                    exerciseList
                } else {
                    Text("This routine has no exercises yet. Add some, or generate one with AI.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textDim)
                }

                actions
            }
            .padding()
        }
        .obsidianBackground()
        .navigationTitle("Routine")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reseed)
        .onChange(of: membership) { _, _ in reseed() }
        .onDisappear(perform: commitName)
        .sheet(item: $editing) { target in
            RoutineItemEditorSheet(item: target.item, catalog: exercises)
        }
        .sheet(isPresented: $showPicker) {
            ExercisePickerSheet { exercise in
                workout.addExercise(exercise, to: routine)
            }
        }
        .sheet(isPresented: $showAIGenerator) {
            RoutineAIGeneratorSheet(catalog: exercises) { title, focus, generated in
                applyAI(title: title, focus: focus, generated: generated)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Routine name", text: $name)
                .font(.largeTitle.weight(.bold))
                .tint(Theme.emerald)
                .submitLabel(.done)
                .onSubmit(commitName)

            HStack(spacing: 8) {
                Text("\(routine.exerciseCount) movement\(routine.exerciseCount == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textDim)
                if routine.isAIGenerated {
                    Label("AI", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.violet)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Persists the edited name (falling back to "Routine" when blank).
    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let resolved = trimmed.isEmpty ? "Routine" : trimmed
        if resolved != routine.name {
            workout.renameRoutine(routine, to: resolved)
        }
        if name != resolved { name = resolved }
    }

    // MARK: Exercises

    private var exerciseList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ReorderableVStack(itemsBinding, spacing: 14) { $item, grip in
                reorderableCard(item, grip: grip)
            }

            Text("Drag \u{2261} to reorder \u{00B7} tap an exercise to edit")
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
            RoutineExerciseCard(exercise: exercise, target: targetText(item))
        } else {
            Color.clear.frame(height: 1)
        }
    }

    private func targetText(_ item: RoutineItem) -> String {
        var text = "\(item.targetSets) \u{00D7} \(item.targetReps.map(String.init) ?? "\u{2014}")"
        if let weight = item.targetWeight, weight > 0 {
            text += "  \u{00B7}  \(Int(weight)) lb"
        }
        return text
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                Haptics.shared.tick()
                workout.startSession(from: routine)
            } label: {
                actionLabel("START SESSION", icon: "play.fill", filled: true)
            }
            .buttonStyle(.plain)
            .disabled(routine.orderedItems.isEmpty)

            Button {
                Haptics.shared.tick()
                showPicker = true
            } label: {
                actionLabel("ADD EXERCISE", icon: "plus.circle.fill", filled: false)
            }
            .buttonStyle(.plain)

            Button {
                Haptics.shared.tick()
                showAIGenerator = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text("GENERATE WITH AI")
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

    // MARK: AI generation

    /// Replaces the routine's contents with an AI-generated plan, mapping planned
    /// exercise names back to real catalog entries (unknown names are dropped).
    private func applyAI(title: String, focus: WorkoutFocus, generated: [PlannedExercise]) {
        let byName = Dictionary(exercises.map { ($0.name.lowercased(), $0) }) { first, _ in first }
        let items: [WorkoutManager.RoutineDraftItem] = generated.compactMap { planned in
            guard let exercise = byName[planned.name.lowercased()] else { return nil }
            let weight: Double? = {
                guard let load = planned.prescription?.targetLoadPounds, load > 0 else { return nil }
                return load
            }()
            return (exercise, planned.sets, planned.targetReps, weight, planned.supersetGroup)
        }
        guard !items.isEmpty else { return }
        let resolvedName = name.trimmingCharacters(in: .whitespaces).isEmpty ? title : name
        workout.updateRoutine(routine, name: resolvedName, items: items)
        name = routine.name
        Haptics.shared.success()
    }
}

// MARK: - Exercise card

/// Image-forward card for one routine exercise: a full-width illustration, muscle
/// badge, name, and the set/rep/weight target. Tapping it opens the per-exercise
/// editor. Mirrors the Plan tab's `PlanExerciseCard`.
private struct RoutineExerciseCard: View {
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

/// Edits a single routine slot: its set count, target reps, and working weight,
/// with an option to swap the movement for an AI-picked alternative. Writes back
/// to the routine item in place on save. Mirrors the Plan tab's
/// `PlanExerciseEditorSheet`.
private struct RoutineItemEditorSheet: View {
    @Environment(WorkoutManager.self) private var workout
    @Environment(\.dismiss) private var dismiss

    let item: RoutineItem
    let catalog: [Exercise]

    @State private var sets: Int
    @State private var reps: Int
    @State private var weight: Double
    @State private var isSwapping = false
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

            Text(weight > 0 ? "\(Int(weight)) lb" : "\u{2014}")
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
                Text(isSwapping ? "SWAPPING\u{2026}" : "SWAP WITH AI")
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
            ExerciseBrief(name: $0.name, muscleGroups: $0.allMuscleGroups.map(\.rawValue), equipment: $0.equipmentType)
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
