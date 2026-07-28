import SwiftUI

/// Compact, image-forward session card for one movement.
///
/// Shows the movement's example image with the targeted muscle badged in the
/// corner, its name, a "sets × reps × weight" summary, and a progress strip
/// counting off the planned sets. Tapping the card opens the full logging sheet
/// (`ExerciseLogSheet`), which is where sets are edited and recorded. During
/// superset-building the whole surface becomes a selection checkbox instead.
struct ExerciseLogCard: View {
    @Environment(WorkoutManager.self) private var workout
    let exercise: Exercise
    /// Drag handle for reordering the session's exercises, supplied by the
    /// enclosing `ReorderableVStack`.
    var grip: ReorderGrip?

    /// When the session is in superset-building mode the card turns into a
    /// checkbox: the tap-to-open action is inert and a tap toggles selection.
    var isSelecting: Bool = false
    var isSelected: Bool = false
    /// Already part of an existing superset: shown pre-filled but not tappable, so
    /// a new superset can't be built over movements already grouped in another.
    var isLocked: Bool = false
    var onToggleSelect: (() -> Void)?
    /// Opens the logging sheet for this movement.
    var onOpen: (() -> Void)?

    @State private var showReplacePicker = false
    @State private var showRemoveConfirmation = false
    /// The progressive-overload target for this movement, resolved once when the
    /// card appears — drives the summary's rep range and working weight.
    @State private var target: ProgressionTarget?

    var body: some View {
        cardButton
            // The muscle target and drag grip float over the image banner.
            .overlay(alignment: .topLeading) {
                MuscleBadge(exercise: exercise)
                    .padding(10)
            }
            .overlay(alignment: .topTrailing) {
                if let grip, !isSelecting {
                    // Backed so the drag handle reads clearly over the image
                    // banner instead of vanishing against a busy photo — the
                    // same glass treatment as the muscle badge opposite it.
                    grip
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.glassBorder, lineWidth: 1))
                        .padding(10)
                }
            }
            .disabled(isSelecting)
            // The selection checkbox layers above everything and stays live even
            // while the card beneath is disabled during superset building.
            .overlay {
                if isSelecting { selectionOverlay }
            }
            .onAppear { if target == nil { target = workout.progressionTarget(for: exercise) } }
        .sheet(isPresented: $showReplacePicker) {
            ExercisePickerSheet { replacement in
                workout.replaceExercise(exercise, with: replacement)
            }
        }
        .confirmationDialog(
            "Remove \(exercise.name)?",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Exercise", role: .destructive) {
                workout.removeExercise(exercise)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let logged = loggedCount
            Text(logged > 0
                ? "This also deletes the \(logged) set\(logged == 1 ? "" : "s") you logged for it in this session."
                : "Removes this movement from the session.")
        }
    }

    // MARK: - Card

    private var cardButton: some View {
        Button {
            Haptics.shared.tick()
            onOpen?()
        } label: {
            VStack(spacing: 0) {
                ExerciseImageBanner(exercise: exercise, height: 150)
                infoSection
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.glassBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Haptics.shared.tick()
                showReplacePicker = true
            } label: {
                Label("Replace", systemImage: "arrow.triangle.2.circlepath")
            }
            if workout.supersetTag(for: exercise) != nil {
                Button {
                    workout.ungroupSuperset(exercise)
                } label: {
                    Label("Ungroup Superset", systemImage: "rectangle.split.1x2")
                }
            }
            Button(role: .destructive) {
                Haptics.shared.tick()
                showRemoveConfirmation = true
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    /// The text block beneath the image: name + progress count, the plan
    /// summary, and the per-set progress strip.
    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let letter = workout.supersetLabel(for: exercise) {
                Label("SUPERSET \(letter)", systemImage: "link")
                    .font(.caption2.weight(.bold))
                    .kerning(0.5)
                    .foregroundStyle(Theme.teal)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(exercise.name)
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Text("\(loggedCount)/\(plannedCount)")
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(isComplete ? Theme.emerald : Theme.textDim)
            }
            Text(summaryLine)
                .font(.caption)
                .foregroundStyle(Theme.textDim)
            progressStrip
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    // MARK: - Selection

    /// Tappable checkbox surface laid over the card while building a superset.
    /// Locked cards (already in a superset) read as filled but ignore taps.
    private var selectionOverlay: some View {
        Button {
            Haptics.shared.tick()
            onToggleSelect?()
        } label: {
            RoundedRectangle(cornerRadius: 20)
                .fill(isSelected ? Theme.teal.opacity(isLocked ? 0.08 : 0.14) : Color.black.opacity(0.001))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(isSelected ? Theme.teal.opacity(isLocked ? 0.5 : 1) : Color.white.opacity(0.14),
                                      lineWidth: isSelected ? 2 : 1)
                )
                .overlay(alignment: .topTrailing) {
                    Image(systemName: isLocked ? "link.circle.fill" : (isSelected ? "checkmark.circle.fill" : "circle"))
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isSelected ? Theme.teal.opacity(isLocked ? 0.6 : 1) : Theme.textDim)
                        .padding(12)
                }
                .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
        .accessibilityLabel(exercise.name)
        .accessibilityValue(isLocked ? "Already in a superset" : (isSelected ? "Selected" : "Not selected"))
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Progress strip

    /// One segment per planned set, filled as each is logged (gold for a PR).
    private var progressStrip: some View {
        let sets = workout.sets(for: exercise)
        let total = max(plannedCount, 1)
        return HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { index in
                Capsule()
                    .fill(segmentColor(index: index, sets: sets))
                    .frame(height: 6)
                    .overlay(
                        Capsule().strokeBorder(
                            index < sets.count ? Color.clear : Theme.stroke,
                            lineWidth: 1
                        )
                    )
            }
        }
    }

    private func segmentColor(index: Int, sets: [ExerciseSet]) -> Color {
        guard index < sets.count else { return Color.white.opacity(0.05) }
        return sets[index].isPR ? Theme.gold : Theme.emerald
    }

    // MARK: - Derived state

    private var loggedCount: Int { workout.sets(for: exercise).count }

    private var plannedCount: Int { workout.targetSets(for: exercise) }

    private var isComplete: Bool { plannedCount > 0 && loggedCount >= plannedCount }

    /// "3 sets × 8–10 × 30 lb" — the plan at a glance. Reps come as a range when
    /// the progression target frames one; weight from the coached plan, the
    /// target, or the last logged working set.
    private var summaryLine: String {
        let sets = plannedCount
        let setsText = "\(sets) set\(sets == 1 ? "" : "s")"
        switch exercise.trackingType {
        case .weightAndReps, .bodyweightAndReps:
            var parts = [setsText, repsText]
            if let weight = weightText { parts.append(weight) }
            return parts.joined(separator: " × ")
        case .customMetric, .durationAndReps:
            return "\(setsText) × \(repsText)"
        case .timeAndDistance:
            return setsText
        }
    }

    private var repsText: String {
        if let target {
            if target.repRangeLow != target.repRangeHigh {
                return "\(target.repRangeLow)–\(target.repRangeHigh) reps"
            }
            return "\(target.targetReps) reps"
        }
        if let planned = workout.plannedReps(for: exercise) { return "\(planned) reps" }
        if let last = lastWorkingSet { return "\(last.reps) reps" }
        return "8 reps"
    }

    private var weightText: String? {
        let pounds: Double?
        if let planned = workout.plannedWeight(for: exercise) {
            pounds = planned
        } else if let weight = target?.targetWeightPounds {
            pounds = weight
        } else if let last = lastWorkingSet {
            pounds = last.weight
        } else {
            pounds = nil
        }
        guard let pounds, pounds != 0 else {
            return exercise.trackingType == .bodyweightAndReps ? "BW" : nil
        }
        if exercise.trackingType == .bodyweightAndReps {
            let sign = pounds > 0 ? "+" : ""
            return "BW\(sign)\(exercise.displayWeightString(fromPounds: pounds))"
        }
        return "\(exercise.displayWeightString(fromPounds: pounds)) \(exercise.weightUnit.abbreviation)"
    }

    private var lastWorkingSet: ExerciseSet? {
        exercise.sets.filter { !$0.isWarmup }.max(by: { $0.timestamp < $1.timestamp })
    }
}
