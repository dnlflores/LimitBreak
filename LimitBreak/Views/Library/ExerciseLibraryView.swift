import SwiftUI
import SwiftData

/// Browsable exercise catalog with per-movement record ledgers.
struct ExerciseLibraryView: View {
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @State private var searchText = ""
    @State private var muscleFilter: MuscleGroup?
    // Debug/UI-test hook: launch with "-open-forge" to present the creator sheet.
    @State private var showCreator = ProcessInfo.processInfo.arguments.contains("-open-forge")
    // Debug/UI-test hook: launch with "-open-first-exercise" to push the first
    // movement's detail page.
    @State private var debugOpenFirst = ProcessInfo.processInfo.arguments.contains("-open-first-exercise")

    private var filtered: [Exercise] {
        exercises.filter { exercise in
            let matchesSearch = searchText.isEmpty
                || exercise.name.localizedCaseInsensitiveContains(searchText)
            let matchesMuscle = muscleFilter == nil
                || exercise.muscleGroupRaw == muscleFilter?.rawValue
            return matchesSearch && matchesMuscle
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    titleHeader

                    searchField

                    filterBar

                    summaryHeader

                    ForEach(filtered, id: \.id) { exercise in
                        NavigationLink {
                            ExerciseDetailView(exercise: exercise)
                        } label: {
                            exerciseCard(exercise)
                        }
                        .buttonStyle(.plain)
                    }

                    if filtered.isEmpty {
                        Text(emptyMessage)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textDim)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .cardStyle()
                    }
                }
                .padding()
            }
            .obsidianBackground()
            .toolbar(.hidden, for: .navigationBar)
            .scrollDismissesKeyboard(.interactively)
            .sheet(isPresented: $showCreator) {
                ExerciseEditorView()
            }
            .navigationDestination(isPresented: $debugOpenFirst) {
                if let first = exercises.first {
                    ExerciseDetailView(exercise: first)
                }
            }
        }
    }

    private var emptyMessage: String {
        searchText.isEmpty
            ? "No movements here yet. Forge a custom one with +."
            : "No movements match \u{201C}\(searchText)\u{201D}."
    }

    // MARK: - Title & search

    private var titleHeader: some View {
        HStack(alignment: .center) {
            Text("Library")
                .font(.largeTitle.bold())
            Spacer()
            Button {
                Haptics.shared.tick()
                showCreator = true
            } label: {
                Image(systemName: "plus")
                    .font(.title2)
                    .glassCircle()
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 8)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textDim)
            TextField("Search movements", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textDim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.glassBorder, lineWidth: 1))
    }

    // MARK: - Filter chips

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(nil)
                ForEach(MuscleGroup.allCases) { muscle in
                    filterChip(muscle)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    private func filterChip(_ muscle: MuscleGroup?) -> some View {
        let isSelected = muscleFilter == muscle
        return Button(muscle?.displayName ?? "All") {
            muscleFilter = muscle
            Haptics.shared.tick()
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isSelected ? AnyShapeStyle(Theme.emerald) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
        .overlay(Capsule().strokeBorder(isSelected ? AnyShapeStyle(.clear) : AnyShapeStyle(Theme.glassBorder), lineWidth: 1))
        .foregroundStyle(isSelected ? .black : .primary)
        .buttonStyle(.plain)
    }

    // MARK: - Summary

    private var summaryHeader: some View {
        let customCount = exercises.filter(\.isCustom).count
        let recordCount = exercises.reduce(0) { $0 + $1.prRecords.count }

        return HStack(spacing: 12) {
            summaryTile(value: "\(exercises.count)", label: "movements", color: Theme.teal)
            summaryTile(value: "\(customCount)", label: "custom", color: Theme.violet)
            summaryTile(value: "\(recordCount)", label: "records", color: Theme.gold)
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

    // MARK: - Exercise cards

    private func exerciseCard(_ exercise: Exercise) -> some View {
        HStack(spacing: 12) {
            exerciseThumbnail(exercise)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(exercise.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if exercise.isCustom {
                        Text("CUSTOM")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Theme.violet.opacity(0.25), in: Capsule())
                            .foregroundStyle(Theme.violet)
                    }
                }
                Text("\(exercise.muscleGroupDisplay) · \(exercise.equipmentType)")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }

            Spacer()

            let ceiling = exercise.ceiling(for: "1RM")
            if ceiling > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(exercise.usesWeightUnit ? exercise.displayWeightString(fromPounds: ceiling) : ceiling.cleanWeight)
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.gold)
                    Text(exercise.usesWeightUnit ? "1RM · \(exercise.weightUnit.abbreviation)" : "1RM")
                        .font(.caption2)
                        .foregroundStyle(Theme.textDim)
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textDim)
        }
        .cardStyle()
    }

    /// The movement's bundled illustration, cropped square, falling back to its
    /// muscle-group symbol when no art is shipped.
    @ViewBuilder
    private func exerciseThumbnail(_ exercise: Exercise) -> some View {
        if let image = exercise.exampleImage {
            image
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.glassBorder, lineWidth: 1))
        } else {
            Image(systemName: exercise.muscleGroup.iconName)
                .font(.title3)
                .foregroundStyle(Theme.teal)
                .frame(width: 44, height: 44)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
        }
    }

}

// MARK: - Detail

struct ExerciseDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var sessions: [WorkoutSession]
    let exercise: Exercise

    @State private var showEditor = false
    @State private var showDeleteConfirm = false
    @State private var showMastery = false

    private var records: [PRRecord] {
        exercise.prRecords.sorted { $0.dateAchieved > $1.dateAchieved }
    }

    /// Sessions that trained this movement with real work — one completion each,
    /// the same "showing up" rule the mastery ladder counts on.
    private var trainingSessions: [WorkoutSession] {
        sessions.filter { session in
            session.sets.contains { !$0.isWarmup && $0.exercise?.id == exercise.id }
        }
    }

    /// This movement's current mastery standing, ready to render as a rank row.
    private var rank: Mastery.Rank {
        Mastery.Rank(
            kind: .exercise,
            id: exercise.id,
            name: exercise.name,
            completions: trainingSessions.count
        )
    }

    /// The training log behind this movement's rank, newest first.
    private var masteryLog: [MasteryLogEntry] {
        trainingSessions.map { session in
            let working = session.sets.filter { !$0.isWarmup && $0.exercise?.id == exercise.id }
            let volume = working.reduce(0.0) { $0 + max(0, $1.effectiveLoad) * Double($1.reps) }
            return MasteryLogEntry(
                date: session.startDate,
                title: session.name,
                detail: "\(working.count) set\(working.count == 1 ? "" : "s") · \(Int(volume).formatted()) lbs"
            )
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                detailHeader

                if exercise.exampleImage != nil {
                    ExerciseImageBanner(exercise: exercise, height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.glassBorder, lineWidth: 1))
                }

                masterySection

                guideSection

                configCard

                sectionLabel("RECORD LEDGER")

                if records.isEmpty {
                    Text("No records yet. Every LimitBreak lands here.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .cardStyle()
                } else {
                    ForEach(records, id: \.id) { record in
                        recordCard(record)
                    }
                }
            }
            .padding()
        }
        .obsidianBackground()
        .toolbar(.hidden, for: .navigationBar)
        .enableSwipeBack()
        .sheet(isPresented: $showEditor) {
            ExerciseEditorView(exercise: exercise)
        }
        .sheet(isPresented: $showMastery) {
            MasteryDetailSheet(rank: rank, log: masteryLog)
        }
        .confirmationDialog(
            "Delete \(exercise.name)?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Exercise", role: .destructive, action: deleteExercise)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the movement and its record ledger. Routines using it will drop the slot. This can't be undone.")
        }
    }

    private func deleteExercise() {
        modelContext.delete(exercise)
        try? modelContext.save()
        Haptics.shared.success()
        dismiss()
    }

    // MARK: Header

    private var detailHeader: some View {
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
                HStack(spacing: 6) {
                    Text(exercise.name)
                        .font(.title2.bold())
                        .lineLimit(2)
                    if exercise.isCustom {
                        Text("CUSTOM")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Theme.violet.opacity(0.25), in: Capsule())
                            .foregroundStyle(Theme.violet)
                    }
                }
                Text("\(exercise.muscleGroupDisplay) · \(exercise.equipmentType)")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }

            Spacer()

            if exercise.isCustom {
                Menu {
                    Button {
                        showEditor = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.headline)
                        .glassCircle()
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 8)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .kerning(1.5)
            .foregroundStyle(Theme.textDim)
            .padding(.top, 6)
    }

    // MARK: Mastery

    /// This movement's skill level and progress toward the next rank. Every fifth
    /// session ranks it up for a bonus of `Mastery.levelUpXP`. Tapping opens the
    /// full ladder and the training log that built it.
    private var masterySection: some View {
        Button {
            Haptics.shared.tick()
            showMastery = true
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("MASTERY")
                        .font(.caption.weight(.bold))
                        .kerning(1.5)
                        .foregroundStyle(Theme.textDim)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textDim)
                }

                MasteryRankRow(rank: rank)

                if rank.completions == 0 {
                    Text("Log a working set to start ranking up this skill \u{2014} every \(Mastery.completionsPerLevel) sessions levels it up for +\(Mastery.levelUpXP) XP.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(Rectangle())
            .cardStyle()
        }
        .buttonStyle(.plain)
    }

    // MARK: Guide

    /// Description and how-to steps; movements without one get a nudge to
    /// write it (the editor's Guide section is always available later).
    @ViewBuilder
    private var guideSection: some View {
        if let about = exercise.exerciseDescription, !about.isEmpty {
            sectionLabel("ABOUT")
            Text(about)
                .font(.subheadline)
                .foregroundStyle(.primary)
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

        if exercise.exerciseDescription == nil && steps.isEmpty {
            Button {
                showEditor = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "text.badge.plus")
                        .font(.subheadline)
                        .foregroundStyle(Theme.emerald)
                    Text("No guide yet \u{2014} add a description and how-to for this movement.")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                        .multilineTextAlignment(.leading)
                    Spacer()
                }
                .padding(12)
                .glassControl(cornerRadius: 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Configuration

    private var configCard: some View {
        VStack(spacing: 0) {
            configRow("Primary", exercise.muscleGroupDisplay)
            if !exercise.secondaryMuscles.isEmpty {
                divider
                configRow("Secondary", exercise.secondaryMuscleDisplayNames.joined(separator: ", "))
            }
            divider
            configRow("Tracking", exercise.trackingType.rawValue)
            divider
            configRow("Increment", "\(exercise.defaultIncrement.cleanWeight) \(exercise.usesWeightUnit ? exercise.weightUnit.abbreviation : "lbs")")
            divider
            configRow("Rest Timer", exercise.defaultRestSeconds > 0 ? "\(exercise.defaultRestSeconds)s" : "None")
            divider
            configRow("1RM Formula", exercise.formulaRaw)
        }
        .cardStyle()
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.stroke)
            .frame(height: 1)
            .padding(.vertical, 8)
    }

    private func configRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.textDim)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: Records

    private func recordCard(_ record: PRRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "crown.fill")
                .font(.subheadline)
                .foregroundStyle(Theme.gold)
                .frame(width: 36, height: 36)
                .background(Theme.gold.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(record.recordType)
                    .font(.subheadline.weight(.semibold))
                Text(record.dateAchieved.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }

            Spacer()

            Text(recordValueText(record))
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(Theme.gold)
        }
        .cardStyle()
    }

    /// A record's value, shown in the exercise's unit for weight records (1RM).
    private func recordValueText(_ record: PRRecord) -> String {
        if record.recordType == "1RM", let ex = record.exercise, ex.usesWeightUnit {
            return "\(ex.displayWeightString(fromPounds: record.numericValue)) \(ex.weightUnit.abbreviation)"
        }
        return record.numericValue.cleanWeight
    }
}
