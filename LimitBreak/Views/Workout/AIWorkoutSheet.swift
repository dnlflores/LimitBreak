import SwiftUI
import SwiftData

/// Asks the user what to focus on and how much to do, then generates a
/// tappable workout on-device and hands it back to start a session.
struct AIWorkoutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkoutManager.self) private var workout
    @Query(sort: \Exercise.name) private var exercises: [Exercise]

    /// Called with the generated session title and the ordered exercises to load.
    let onStart: (String, [Exercise]) -> Void

    @State private var focus: WorkoutFocus = .fullBody
    @State private var exerciseCount = 5
    @State private var duration: WorkoutLength = .any
    @State private var plan: WorkoutPlan?
    @State private var isGenerating = false
    @State private var didSaveRoutine = false
    @State private var inspectedExercise: PlannedExerciseDetail?

    /// Sheet payload for one tapped plan row: the matched catalog movement
    /// plus how many sets the plan calls for.
    struct PlannedExerciseDetail: Identifiable {
        let exercise: Exercise
        let sets: Int
        var id: UUID { exercise.id }
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
                PlannedExerciseSheet(exercise: detail.exercise, plannedSets: detail.sets)
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

            ForEach(Array(plan.exercises.enumerated()), id: \.element.id) { index, planned in
                Button {
                    guard let exercise = catalogExercise(for: planned.name) else { return }
                    Haptics.shared.tick()
                    inspectedExercise = PlannedExerciseDetail(exercise: exercise, sets: planned.sets)
                } label: {
                    HStack(spacing: 14) {
                        Text("\(index + 1)")
                            .font(.system(.headline, design: .rounded, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.emerald)
                            .frame(width: 28)
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
                        Spacer()
                        Text("\(planned.sets) sets")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textDim)
                        Image(systemName: "info.circle")
                            .font(.subheadline)
                            .foregroundStyle(Theme.emerald)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .cardStyle()

            Text("Tap a movement to see how to perform it and the load to aim for.")
                .font(.caption2)
                .foregroundStyle(Theme.textDim)
                .frame(maxWidth: .infinity, alignment: .center)
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
            catalog: catalog
        )
        isGenerating = false
        withAnimation(.spring(duration: 0.35)) { plan = result }
        Haptics.shared.success()
    }

    private func startWorkout() {
        guard let plan else { return }
        let byName = Dictionary(exercises.map { ($0.name.lowercased(), $0) }) { first, _ in first }
        let matched = plan.exercises.compactMap { byName[$0.name.lowercased()] }
        guard !matched.isEmpty else { return }
        onStart(plan.title, matched)
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
        catalogExercise(for: name)?.muscleGroupRaw
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
                Text("\(exercise.muscleGroupRaw) \u{00B7} \(exercise.equipmentType)")
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

    private var recommendationText: String {
        switch exercise.trackingType {
        case .weightAndReps, .bodyweightAndReps, .customMetric:
            if let last = lastWorkingSet, last.weight != 0 {
                return "\(plannedSets) sets \u{00D7} \(last.weight.cleanWeight) lbs \u{00D7} \(last.reps)"
            }
            let ceiling = exercise.ceiling(for: "1RM")
            if ceiling > 0 {
                let suggested = (ceiling * 0.75 / exercise.defaultIncrement).rounded() * exercise.defaultIncrement
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
        if let last = lastWorkingSet, last.weight != 0 {
            return "Matched to your last working set \u{2014} beat it and the ceiling moves."
        }
        if exercise.ceiling(for: "1RM") > 0 {
            return "About 75% of your recorded ceiling \u{2014} room to push."
        }
        return "No history yet \u{2014} start light and find your groove."
    }
}
