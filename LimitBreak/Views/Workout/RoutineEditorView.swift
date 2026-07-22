import SwiftUI
import SwiftData

/// Creates or edits a saved routine (curation): a name, optional notes, and an
/// ordered list of exercises with a target set count each. Exercises can be
/// added by hand or the whole list generated on-device by the workout AI.
struct RoutineEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkoutManager.self) private var workout
    @Query(sort: \Exercise.name) private var allExercises: [Exercise]

    /// One editable slot in the routine being built.
    private struct DraftItem: Identifiable {
        let id = UUID()
        var exercise: Exercise
        var targetSets: Int
    }

    /// The routine being edited, or `nil` when creating a new one.
    private let existing: Routine?

    @State private var name: String
    @State private var notes: String
    @State private var items: [DraftItem]
    @State private var isAIGenerated: Bool
    @State private var focusLabel: String?

    @State private var showPicker = false
    @State private var showAIGenerator = false

    /// New routine, optionally seeded (e.g. from a past session).
    init(seedName: String = "", seedItems: [(exercise: Exercise, targetSets: Int)] = []) {
        self.existing = nil
        _name = State(initialValue: seedName)
        _notes = State(initialValue: "")
        _items = State(initialValue: seedItems.map { DraftItem(exercise: $0.exercise, targetSets: $0.targetSets) })
        _isAIGenerated = State(initialValue: false)
        _focusLabel = State(initialValue: nil)
    }

    /// Edit an existing routine.
    init(routine: Routine) {
        self.existing = routine
        _name = State(initialValue: routine.name)
        _notes = State(initialValue: routine.notes ?? "")
        _items = State(initialValue: routine.orderedItems.compactMap { item in
            item.exercise.map { DraftItem(exercise: $0, targetSets: item.targetSets) }
        })
        _isAIGenerated = State(initialValue: routine.isAIGenerated)
        _focusLabel = State(initialValue: routine.focusLabel)
    }

    private var canSave: Bool {
        !items.isEmpty && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                detailsSection
                exercisesSection
            }
            .scrollContentBackground(.hidden)
            .obsidianBackground()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(existing == nil ? "New Routine" : "Edit Routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .sheet(isPresented: $showPicker) {
                ExercisePickerSheet { exercise in
                    addExercise(exercise)
                }
            }
            .sheet(isPresented: $showAIGenerator) {
                RoutineAIGeneratorSheet(catalog: allExercises) { title, focus, generated in
                    apply(title: title, focus: focus, generated: generated)
                }
            }
        }
    }

    // MARK: - Details

    private var detailsSection: some View {
        Section {
            TextField("Routine name", text: $name)
            TextField("Notes (optional)", text: $notes, axis: .vertical)
                .lineLimit(1...4)
        } header: {
            Text("Details")
        } footer: {
            if isAIGenerated, let focusLabel {
                Label("AI-generated · \(focusLabel) focus", systemImage: "sparkles")
                    .foregroundStyle(Theme.violet)
            }
        }
        .listRowBackground(Theme.surfaceRaised)
    }

    // MARK: - Exercises

    private var exercisesSection: some View {
        Section {
            if items.isEmpty {
                Text("No exercises yet. Add some, or generate a routine with AI.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textDim)
                    .listRowBackground(Theme.surfaceRaised)
            } else {
                ForEach($items) { $item in
                    exerciseRow($item)
                }
                .onMove { items.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { items.remove(atOffsets: $0) }
            }

            Button {
                Haptics.shared.tick()
                showPicker = true
            } label: {
                Label("Add Exercise", systemImage: "plus.circle.fill")
                    .foregroundStyle(Theme.emerald)
            }
            .listRowBackground(Theme.surfaceRaised)

            Button {
                Haptics.shared.tick()
                showAIGenerator = true
            } label: {
                Label("Generate with AI", systemImage: "sparkles")
                    .foregroundStyle(Theme.violet)
            }
            .listRowBackground(Theme.surfaceRaised)
        } header: {
            HStack {
                Text("Exercises")
                Spacer()
                if !items.isEmpty {
                    Text("\(items.count)")
                        .foregroundStyle(Theme.textDim)
                }
            }
        }
    }

    private func exerciseRow(_ item: Binding<DraftItem>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.wrappedValue.exercise.name)
                    .font(.subheadline.weight(.semibold))
                Text(item.wrappedValue.exercise.muscleGroupRaw)
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }
            Spacer()
            Stepper(
                value: item.targetSets,
                in: 1...12
            ) {
                Text("\(item.wrappedValue.targetSets) set\(item.wrappedValue.targetSets == 1 ? "" : "s")")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.emerald)
            }
            .labelsHidden()
            .fixedSize()
        }
        .listRowBackground(Theme.surfaceRaised)
    }

    // MARK: - Mutations

    private func addExercise(_ exercise: Exercise) {
        guard !items.contains(where: { $0.exercise.id == exercise.id }) else { return }
        items.append(DraftItem(exercise: exercise, targetSets: 3))
    }

    /// Replaces the current draft with an AI-generated plan, mapping planned
    /// exercise names back to real catalog entries (unknown names are dropped).
    private func apply(title: String, focus: WorkoutFocus, generated: [PlannedExercise]) {
        let byName = Dictionary(allExercises.map { ($0.name.lowercased(), $0) }) { first, _ in first }
        let mapped = generated.compactMap { planned -> DraftItem? in
            guard let exercise = byName[planned.name.lowercased()] else { return nil }
            return DraftItem(exercise: exercise, targetSets: planned.sets)
        }
        guard !mapped.isEmpty else { return }
        withAnimation(.spring(duration: 0.3)) {
            items = mapped
            if name.trimmingCharacters(in: .whitespaces).isEmpty { name = title }
            isAIGenerated = true
            focusLabel = focus.label
        }
        Haptics.shared.success()
    }

    private func save() {
        let pairs = items.map { (exercise: $0.exercise, targetSets: $0.targetSets) }
        if let existing {
            workout.updateRoutine(existing, name: name, notes: notes, items: pairs)
        } else {
            workout.createRoutine(
                name: name,
                notes: notes,
                isAIGenerated: isAIGenerated,
                focusLabel: focusLabel,
                items: pairs
            )
        }
        dismiss()
    }
}

// MARK: - AI generator sheet

/// Compact focus/length picker that runs the on-device workout AI and hands the
/// resulting plan back to the routine editor.
private struct RoutineAIGeneratorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let catalog: [Exercise]
    let onGenerate: (String, WorkoutFocus, [PlannedExercise]) -> Void

    @State private var focus: WorkoutFocus = .fullBody
    @State private var exerciseCount = 5
    @State private var length: WorkoutLength = .any
    @State private var isGenerating = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 40))
                        .foregroundStyle(Theme.limitBreakGradient)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)

                    section("FOCUS") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                            ForEach(WorkoutFocus.allCases) { preset in
                                chip(preset.label, selected: focus == preset) {
                                    focus = preset
                                    Haptics.shared.tick()
                                }
                            }
                        }
                    }

                    section("EXERCISES") {
                        HStack {
                            Text("\(exerciseCount)")
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(Theme.emerald)
                            Spacer()
                            Stepper("", value: $exerciseCount, in: 3...8)
                                .labelsHidden()
                                .tint(Theme.emerald)
                        }
                    }

                    section("LENGTH") {
                        Picker("Length", selection: $length) {
                            ForEach(WorkoutLength.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .padding()
            }
            .obsidianBackground()
            .navigationTitle("Generate Routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task { await generate() }
                } label: {
                    HStack(spacing: 8) {
                        if isGenerating {
                            ProgressView().tint(.white)
                            Text("GENERATING…")
                        } else {
                            Image(systemName: "sparkles")
                            Text("GENERATE")
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
                .padding()
                .background(.ultraThinMaterial)
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

    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
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

    private func generate() async {
        isGenerating = true
        Haptics.shared.tick()
        let briefs = catalog.map {
            ExerciseBrief(name: $0.name, muscleGroups: $0.allMuscleGroups.map(\.rawValue), equipment: $0.equipmentType)
        }
        let plan = await WorkoutAI.generatePlan(
            focusLabel: focus.label,
            targetMuscleGroups: focus.targetMuscleGroups,
            exerciseCount: exerciseCount,
            durationMinutes: length.minutes,
            catalog: briefs
        )
        isGenerating = false
        onGenerate(plan.title, focus, plan.exercises)
        dismiss()
    }
}
