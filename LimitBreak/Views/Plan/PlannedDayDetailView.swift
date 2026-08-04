import SwiftUI
import SwiftData

/// One plan day: its workout, with actions to start a session, edit the
/// exercises (full routine editor), or regenerate the day with AI.
struct PlannedDayDetailView: View {
    @Environment(WorkoutManager.self) private var workout
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var sessions: [WorkoutSession]
    @Query private var profiles: [TrainingProfile]

    let day: PlannedDay

    @State private var showEditor = false
    @State private var isRegenerating = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let routine = day.routine, !routine.orderedItems.isEmpty {
                    exerciseList(routine)
                } else {
                    Text("This day has no exercises yet. Edit it to add some or regenerate with AI.")
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
        .sheet(isPresented: $showEditor) {
            if let routine = day.routine {
                RoutineEditorView(routine: routine)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(day.focus.label)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Theme.limitBreakGradient)
            if let routine = day.routine {
                Text("\(routine.exerciseCount) movement\(routine.exerciseCount == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Exercises

    private func exerciseList(_ routine: Routine) -> some View {
        VStack(spacing: 10) {
            ForEach(routine.orderedItems, id: \.id) { item in
                if let exercise = item.exercise {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(exercise.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(exercise.muscleGroup.displayName)
                                .font(.caption2)
                                .foregroundStyle(Theme.textDim)
                        }
                        Spacer(minLength: 4)
                        Text(targetText(item))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.emerald)
                    }
                    .padding(12)
                    .glassControl(cornerRadius: 14)
                }
            }
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
                actionLabel("START SESSION", icon: "play.fill", filled: true)
            }
            .buttonStyle(.plain)
            .disabled(day.routine?.orderedItems.isEmpty ?? true)

            Button {
                Haptics.shared.tick()
                showEditor = true
            } label: {
                actionLabel("EDIT EXERCISES", icon: "slider.horizontal.3", filled: false)
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
