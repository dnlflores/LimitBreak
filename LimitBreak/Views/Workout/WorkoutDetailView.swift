import SwiftUI
import SwiftData

/// Full-screen battle report for one logged workout: summary tiles, every
/// exercise with its sets, and the same edit/save/delete powers as History.
struct WorkoutDetailView: View {
    @Environment(WorkoutManager.self) private var workout
    @Environment(\.dismiss) private var dismiss

    let session: WorkoutSession

    @State private var showEdit = false
    @State private var showSaveAsRoutine = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                xpPill

                summaryTiles

                if let notes = session.notes, !notes.isEmpty {
                    sectionLabel("NOTES")
                    Text(notes)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardStyle()
                }

                sectionLabel("EXERCISES")

                if session.setsByExercise.isEmpty {
                    Text("No sets were logged in this session.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .cardStyle()
                } else {
                    ForEach(session.setsByExercise, id: \.exercise.id) { group in
                        exerciseCard(group.exercise, sets: group.sets)
                    }
                }
            }
            .padding()
        }
        .obsidianBackground()
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showEdit) {
            EditWorkoutView(session: session)
        }
        .sheet(isPresented: $showSaveAsRoutine) {
            RoutineEditorView(
                seedName: session.name,
                seedItems: session.setsByExercise.map { group in
                    (exercise: group.exercise, targetSets: max(1, group.sets.filter { !$0.isWarmup }.count))
                }
            )
        }
        .confirmationDialog("Delete Workout?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Workout", role: .destructive) {
                workout.deleteSession(session)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\u{201C}\(session.name)\u{201D} and all its sets will be permanently removed. Records will be recalculated.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .glassCircle()
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(.title2.bold())
                    .lineLimit(2)
                Text("\(session.startDate.formatted(date: .abbreviated, time: .shortened)) \u{00B7} \(session.duration.clockString)")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }

            Spacer()

            Menu {
                Button {
                    showEdit = true
                } label: {
                    Label("Edit Workout", systemImage: "pencil")
                }
                Button {
                    showSaveAsRoutine = true
                } label: {
                    Label("Save as Routine", systemImage: "square.stack.3d.up")
                }
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete Workout", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline)
                    .glassCircle()
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 8)
    }

    private var xpPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "star.circle.fill")
                .font(.caption)
            Text("+\(XPEngine.xp(for: session)) XP earned")
                .font(.caption.weight(.black))
                .monospacedDigit()
        }
        .foregroundStyle(Theme.gold)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.gold.opacity(0.1), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.limitBreakGradient, lineWidth: 1).opacity(0.4))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .kerning(1.5)
            .foregroundStyle(Theme.textDim)
            .padding(.top, 6)
    }

    // MARK: - Summary

    private var summaryTiles: some View {
        let workingSets = session.sets.filter { !$0.isWarmup }.count

        return HStack(spacing: 12) {
            summaryTile(value: Int(session.totalVolume).formatted(.number.notation(.compactName)), label: "lbs shifted", color: Theme.emerald)
            summaryTile(value: "\(workingSets)", label: "working sets", color: Theme.teal)
            summaryTile(value: "\(session.prCount)", label: "LimitBreaks", color: Theme.gold)
        }
    }

    private func summaryTile(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .statNumberStyle()
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    // MARK: - Exercises

    private func exerciseCard(_ exercise: Exercise, sets: [ExerciseSet]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: exercise.muscleGroup.iconName)
                    .font(.title3)
                    .foregroundStyle(Theme.teal)
                    .frame(width: 40, height: 40)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise.name)
                        .font(.subheadline.weight(.semibold))
                    Text("\(exercise.muscleGroupRaw) \u{00B7} \(exercise.equipmentType)")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                }

                Spacer()

                let best = sets.filter(\.isPR).count
                if best > 0 {
                    Label("\(best)", systemImage: "crown.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.gold)
                }
            }

            VStack(spacing: 6) {
                ForEach(Array(sets.enumerated()), id: \.element.id) { index, set in
                    setRow(index: index, set: set, exercise: exercise)
                }
            }
        }
        .cardStyle()
    }

    private func setRow(index: Int, set: ExerciseSet, exercise: Exercise) -> some View {
        HStack(spacing: 10) {
            Text("SET \(index + 1)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(set.isPR ? Theme.gold : Theme.textDim)
                .frame(width: 44, alignment: .leading)

            Text(set.displayText(for: exercise))
                .font(.subheadline)
                .monospacedDigit()

            Spacer()

            if set.isPR {
                Label("PR", systemImage: "crown.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.gold)
            } else if set.isWarmup {
                Text("warmup")
                    .font(.caption2)
                    .foregroundStyle(Theme.textDim)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background(
            set.isPR ? Theme.gold.opacity(0.08) : Color.white.opacity(0.03),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }
}

// MARK: - Shared set display text

extension ExerciseSet {
    /// One-line summary of a stored set, respecting the exercise's tracking type.
    func displayText(for exercise: Exercise) -> String {
        switch exercise.trackingType {
        case .durationAndReps:
            if let duration = durationSeconds { return "\(duration.clockString) \u{00D7} \(reps)" }
        case .timeAndDistance:
            if let distance = distanceMeters {
                return "\(Int(distance)) m in \((durationSeconds ?? 0).clockString)"
            }
        case .customMetric:
            return "\(weight.cleanWeight) \(exercise.customMetricUnit ?? "") \u{00D7} \(reps)"
        case .weightAndReps, .bodyweightAndReps:
            break
        }
        if weight > 0 { return "\(weight.cleanWeight) lbs \u{00D7} \(reps)" }
        if weight < 0 { return "BW\(weight.cleanWeight) \u{00D7} \(reps)" }
        return "\(reps) reps"
    }
}
