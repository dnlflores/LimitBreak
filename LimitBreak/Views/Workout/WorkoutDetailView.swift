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
    /// The movement whose review/edit sheet is open, if any.
    @State private var selectedExercise: Exercise?

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
                    let groups = session.exerciseGroups
                    ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                        if group.count > 1 {
                            supersetGroupCard(letter: supersetLetter(for: index, in: groups), group: group)
                        } else if let entry = group.first {
                            ExerciseHistoryCard(exercise: entry.exercise, sets: entry.sets) {
                                selectedExercise = entry.exercise
                            }
                        }
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
                    (exercise: group.exercise,
                     targetSets: max(1, group.sets.filter { !$0.isWarmup }.count),
                     supersetGroup: group.sets.first?.supersetGroup)
                }
            )
        }
        .sheet(item: $selectedExercise) { exercise in
            ExerciseHistorySheet(session: session, exercise: exercise)
        }
        .sheet(isPresented: $showDeleteConfirmation) {
            SessionConfirmSheet(
                icon: "trash",
                tint: Theme.crimson,
                title: "Delete Workout?",
                message: "\u{201C}\(session.name)\u{201D} and all its sets will be permanently removed. Records will be recalculated.",
                confirmLabel: "Delete",
                cancelLabel: "Cancel"
            ) {
                workout.deleteSession(session)
                dismiss()
            }
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

            VStack(alignment: .leading, spacing: 4) {
                Text(session.name)
                    .font(.title2.bold())
                    .lineLimit(2)
                Text("\(session.startDate.formatted(date: .abbreviated, time: .shortened)) \u{00B7} \(session.duration.clockString)")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
                PartnerBadge(trainedWithPartner: session.trainedWithPartner)
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
        let calories = session.estimatedActiveCalories(
            bodyWeightLbs: HealthKitManager.shared.currentBodyWeightLbs
        )

        return VStack(alignment: .leading, spacing: 14) {
            Text("BATTLE REPORT")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textDim)
                .kerning(1.5)

            HStack(spacing: 0) {
                summaryStat(value: Int(session.totalVolume).formatted(.number.notation(.compactName)), label: "lbs shifted", color: Theme.emerald)
                statDivider
                summaryStat(value: "\(Int(calories.rounded()))", label: "kcal burned", color: Theme.crimson)
                statDivider
                summaryStat(value: "\(workingSets)", label: "working sets", color: Theme.teal)
                statDivider
                summaryStat(value: "\(session.prCount)", label: "LimitBreaks", color: Theme.gold)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func summaryStat(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    /// Hairline separator between the report's stats, so the row reads as one
    /// divided panel rather than four floating tiles.
    private var statDivider: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.white.opacity(0.08))
            .frame(width: 1, height: 34)
    }

    // MARK: - Exercises

    /// Wraps the movements of one superset in a tinted, labeled container so a
    /// paired set reads as a unit in history, matching the live-session badge.
    private func supersetGroupCard(
        letter: String,
        group: [(exercise: Exercise, sets: [ExerciseSet])]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("SUPERSET \(letter)", systemImage: "link")
                .font(.caption.weight(.bold))
                .kerning(0.5)
                .foregroundStyle(Theme.teal)
            ForEach(group, id: \.exercise.id) { entry in
                ExerciseHistoryCard(exercise: entry.exercise, sets: entry.sets) {
                    selectedExercise = entry.exercise
                }
            }
        }
        .padding(10)
        .background(Theme.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Theme.teal.opacity(0.28), lineWidth: 1)
        )
    }

    /// Letter for a superset run: counts multi-member runs up to this position so
    /// the first superset is "A", the next "B", regardless of standalone slots.
    private func supersetLetter(
        for index: Int,
        in groups: [[(exercise: Exercise, sets: [ExerciseSet])]]
    ) -> String {
        let count = groups.prefix(index).filter { $0.count > 1 }.count
        return String(UnicodeScalar(UInt8(65 + min(count, 25))))
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
        if weight > 0 { return "\(exercise.displayWeightString(fromPounds: weight)) \(exercise.weightUnit.abbreviation) \u{00D7} \(reps)" }
        if weight < 0 { return "BW\(exercise.displayWeightString(fromPounds: weight)) \u{00D7} \(reps)" }
        return "\(reps) reps"
    }
}
