import SwiftUI

// MARK: - History card

/// Image-forward card for one movement inside a logged workout, mirroring the
/// live-session `ExerciseLogCard`: a full-width example image with the targeted
/// muscle badged in the corner, the name, and a summary of what was done.
/// Tapping opens `ExerciseHistorySheet` to review and edit that movement's sets.
struct ExerciseHistoryCard: View {
    let exercise: Exercise
    let sets: [ExerciseSet]
    var onOpen: () -> Void

    var body: some View {
        Button {
            Haptics.shared.tick()
            onOpen()
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
        .overlay(alignment: .topLeading) {
            MuscleBadge(exercise: exercise)
                .padding(10)
        }
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(exercise.name)
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                Spacer(minLength: 4)
                let prs = sets.filter(\.isPR).count
                if prs > 0 {
                    Label("\(prs)", systemImage: "crown.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.gold)
                }
            }
            Text(summaryLine)
                .font(.caption)
                .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    /// "3 sets · top 135 lb × 8" — the count of working sets and the heaviest one.
    private var summaryLine: String {
        let working = sets.filter { !$0.isWarmup }
        let count = working.isEmpty ? sets.count : working.count
        let setsText = "\(count) set\(count == 1 ? "" : "s")"
        let pool = working.isEmpty ? sets : working
        guard let top = pool.max(by: { $0.estimatedOneRepMax < $1.estimatedOneRepMax })
                ?? pool.first else {
            return setsText
        }
        return "\(setsText) · top \(top.displayText(for: exercise))"
    }
}

// MARK: - History sheet

/// Review-and-edit surface for one movement inside a logged workout, styled to
/// match the live-session `ExerciseLogSheet`: a full-bleed image banner blending
/// into the background, a "how to perform" guide, and the movement's sets as
/// editable rows. Saving rewrites just this movement within the session (other
/// movements are preserved) and re-checks records.
struct ExerciseHistorySheet: View {
    @Environment(WorkoutManager.self) private var workout
    @Environment(\.dismiss) private var dismiss

    let session: WorkoutSession
    let exercise: Exercise

    @State private var drafts: [HistorySetDraft] = []
    @State private var original: [HistorySetDraft] = []
    @State private var showHowTo = false
    @State private var didLoad = false

    /// One editable set. `primary` is weight (in the movement's display unit) for
    /// weight-based types, seconds for duration types, or the custom value.
    struct HistorySetDraft: Identifiable {
        let id = UUID()
        var primary: Double
        var reps: Int
        var isWarmup: Bool
        var distance: Double = 1600
        var durationSeconds: Double?
        var wasPR: Bool = false
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ExerciseImageBanner(exercise: exercise, height: 220, blendsIntoBackground: true)
                    .overlay(alignment: .bottomLeading) {
                        MuscleBadge(exercise: exercise)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 6)
                    }

                VStack(alignment: .leading, spacing: 16) {
                    titleBlock
                    howToPerform
                    setList
                    addSetButton
                }
                .padding()
                .padding(.bottom, 8)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .obsidianBackground()
        .safeAreaInset(edge: .bottom) { saveBar }
        .presentationDragIndicator(.visible)
        .onAppear(perform: load)
    }

    // MARK: Title

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(exercise.name)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.leading)
            Text("\(exercise.muscleGroupDisplay) · \(exercise.equipmentType)")
                .font(.caption)
                .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: How to perform

    @ViewBuilder
    private var howToPerform: some View {
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

    // MARK: Set list

    private var setList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SETS")
                    .font(.caption.weight(.bold))
                    .kerning(1)
                    .foregroundStyle(Theme.textDim)
                Spacer()
                if exercise.usesWeightUnit {
                    Text(exercise.weightUnit.abbreviation)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textDim)
                }
            }
            ForEach(Array(drafts.enumerated()), id: \.element.id) { index, _ in
                setRow(index)
            }
        }
    }

    private func setRow(_ index: Int) -> some View {
        let draft = drafts[index]
        return HStack(spacing: 10) {
            Text("SET \(index + 1)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(draft.isWarmup ? Theme.gold : .primary)
                .frame(width: 54, alignment: .leading)

            rowInputs(index)

            Spacer(minLength: 4)

            if draft.isWarmup {
                Text("warmup")
                    .font(.caption2)
                    .foregroundStyle(Theme.gold)
            }

            if canDelete {
                Button {
                    deleteSet(at: index)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.crimson.opacity(0.8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete set \(index + 1)")
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            (draft.isWarmup ? Theme.gold.opacity(0.06) : Color.white.opacity(0.02)),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke, lineWidth: 1))
        .contextMenu {
            Button {
                drafts[index].isWarmup.toggle()
                Haptics.shared.tick()
            } label: {
                Label(draft.isWarmup ? "Mark as working set" : "Mark as warmup",
                      systemImage: draft.isWarmup ? "flame.slash" : "flame")
            }
            if canDelete {
                Button(role: .destructive) {
                    deleteSet(at: index)
                } label: {
                    Label("Delete Set", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func rowInputs(_ index: Int) -> some View {
        switch exercise.trackingType {
        case .weightAndReps, .bodyweightAndReps, .customMetric:
            BigValueField(
                value: $drafts[index].primary,
                step: exercise.defaultIncrement,
                allowsNegative: exercise.isAssisted
            )
            separator("x")
            BigValueField(value: repsBinding(index), step: 1, allowsNegative: false, minimum: 1)
                .frame(maxWidth: 96)
        case .durationAndReps:
            BigValueField(value: $drafts[index].primary, step: 5, allowsNegative: false)
            separator("x")
            BigValueField(value: repsBinding(index), step: 1, allowsNegative: false, minimum: 1)
                .frame(maxWidth: 96)
        case .durationOnly:
            BigValueField(value: $drafts[index].primary, step: 5, allowsNegative: false, minimum: 1)
            Text("sec")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textDim)
        case .timeAndDistance:
            BigValueField(value: $drafts[index].primary, step: 15, allowsNegative: false)
            separator("·")
            BigValueField(value: $drafts[index].distance, step: 100, allowsNegative: false)
        }
    }

    private func separator(_ symbol: String) -> some View {
        Text(symbol)
            .font(.headline)
            .foregroundStyle(Theme.textDim)
    }

    private func repsBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { Double(drafts[index].reps) },
            set: { drafts[index].reps = max(1, Int($0)) }
        )
    }

    private var addSetButton: some View {
        Button {
            addSet()
        } label: {
            Label("Add Set", systemImage: "plus.circle.fill")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(Theme.emerald)
                .glassControl(cornerRadius: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Save bar

    @ViewBuilder
    private var saveBar: some View {
        if isDirty {
            Button {
                save()
            } label: {
                Text("SAVE CHANGES")
                    .font(.headline)
                    .kerning(1.5)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .foregroundStyle(.white)
                    .glassCTA(tint: Theme.emerald.opacity(0.85))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.bottom, 10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Derived

    private var canDelete: Bool { drafts.count > 1 }

    /// True once any value, warmup flag, or the set count differs from what was
    /// loaded — gates the Save bar so pure viewing never rewrites the session.
    private var isDirty: Bool {
        guard drafts.count == original.count else { return true }
        for (a, b) in zip(drafts, original) {
            if a.primary != b.primary || a.reps != b.reps
                || a.isWarmup != b.isWarmup || a.distance != b.distance {
                return true
            }
        }
        return false
    }

    // MARK: Mutations

    private func addSet() {
        let template = drafts.last
        var draft = HistorySetDraft(
            primary: template?.primary ?? 0,
            reps: template?.reps ?? 8,
            isWarmup: false
        )
        if let template {
            draft.distance = template.distance
            draft.durationSeconds = template.durationSeconds
        }
        withAnimation(.snappy) { drafts.append(draft) }
        Haptics.shared.tick()
    }

    private func deleteSet(at index: Int) {
        guard canDelete, drafts.indices.contains(index) else { return }
        _ = withAnimation(.snappy) { drafts.remove(at: index) }
        Haptics.shared.tick()
    }

    // MARK: Load & save

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        let sets = session.setsByExercise
            .first { $0.exercise.id == exercise.id }?.sets ?? []
        drafts = sets.map { set in
            HistorySetDraft(
                primary: primaryValue(from: set),
                reps: max(1, set.reps),
                isWarmup: set.isWarmup,
                distance: set.distanceMeters ?? 1600,
                durationSeconds: set.durationSeconds,
                wasPR: set.isPR
            )
        }
        if drafts.isEmpty {
            drafts = [HistorySetDraft(primary: 0, reps: 8, isWarmup: false)]
        }
        original = drafts
    }

    private func primaryValue(from set: ExerciseSet) -> Double {
        switch exercise.trackingType {
        case .durationAndReps, .durationOnly, .timeAndDistance: return set.durationSeconds ?? 0
        case .weightAndReps, .bodyweightAndReps: return exercise.weightUnit.fromPounds(set.weight)
        case .customMetric: return set.weight
        }
    }

    /// Rewrites just this movement within the session, preserving every other
    /// movement's sets and superset tags, then persists via the manager.
    private func save() {
        let entries: [(exercise: Exercise, supersetGroup: Int?, sets: [PastSetEntry])] =
            session.setsByExercise.map { group in
                let tag = group.sets.first?.supersetGroup
                if group.exercise.id == exercise.id {
                    return (exercise, tag, drafts.map { pastEntry(from: $0) })
                }
                return (group.exercise, tag, group.sets.map { set in
                    PastSetEntry(
                        weight: set.weight,
                        reps: set.reps,
                        isWarmup: set.isWarmup,
                        durationSeconds: set.durationSeconds,
                        distanceMeters: set.distanceMeters
                    )
                })
            }
        workout.updateSession(
            session,
            name: session.name,
            date: session.startDate,
            withPartner: session.trainedWithPartner,
            entries: entries
        )
        dismiss()
    }

    private func pastEntry(from draft: HistorySetDraft) -> PastSetEntry {
        switch exercise.trackingType {
        case .weightAndReps, .bodyweightAndReps:
            return PastSetEntry(weight: exercise.weightUnit.toPounds(draft.primary), reps: draft.reps, isWarmup: draft.isWarmup)
        case .customMetric:
            return PastSetEntry(weight: draft.primary, reps: draft.reps, isWarmup: draft.isWarmup)
        case .durationAndReps:
            return PastSetEntry(weight: 0, reps: draft.reps, isWarmup: draft.isWarmup, durationSeconds: draft.primary)
        case .durationOnly:
            return PastSetEntry(weight: 0, reps: 1, isWarmup: draft.isWarmup, durationSeconds: draft.primary)
        case .timeAndDistance:
            return PastSetEntry(weight: 0, reps: 1, isWarmup: draft.isWarmup, durationSeconds: draft.primary, distanceMeters: draft.distance)
        }
    }
}
