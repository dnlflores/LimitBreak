import SwiftUI
import SwiftData

/// Asks the user what to focus on and how much to do, then generates a
/// tappable workout on-device and hands it back to start a session.
struct AIWorkoutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Exercise.name) private var exercises: [Exercise]

    /// Called with the generated session title and the ordered exercises to load.
    let onStart: (String, [Exercise]) -> Void

    @State private var focus: WorkoutFocus = .fullBody
    @State private var exerciseCount = 5
    @State private var duration: WorkoutLength = .any
    @State private var plan: WorkoutPlan?
    @State private var isGenerating = false

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
                HStack(spacing: 14) {
                    Text("\(index + 1)")
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.emerald)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(planned.name)
                            .font(.subheadline.weight(.semibold))
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
                }
                .padding(.vertical, 4)
            }
            .cardStyle()
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
                            .padding(.vertical, 14)
                            .foregroundStyle(Theme.violet)
                            .glassControl()
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isGenerating)

                    Button {
                        startWorkout()
                    } label: {
                        Text("START")
                            .font(.headline)
                            .kerning(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .foregroundStyle(.white)
                            .glassCTA(tint: Theme.emerald.opacity(0.85))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    // MARK: - Generation

    private func generate() async {
        isGenerating = true
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

    private func muscleGroup(for name: String) -> String? {
        exercises.first { $0.name.lowercased() == name.lowercased() }?.muscleGroupRaw
    }
}
