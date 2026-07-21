import SwiftUI
import SwiftData

/// Browsable exercise catalog with per-movement record ledgers.
struct ExerciseLibraryView: View {
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @State private var searchText = ""
    @State private var muscleFilter: MuscleGroup?
    // Debug/UI-test hook: launch with "-open-forge" to present the creator sheet.
    @State private var showCreator = ProcessInfo.processInfo.arguments.contains("-open-forge")

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
            .sheet(isPresented: $showCreator) {
                ExerciseEditorView()
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
        return Button(muscle?.rawValue ?? "All") {
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
            Image(systemName: iconName(for: exercise.muscleGroup))
                .font(.title3)
                .foregroundStyle(Theme.teal)
                .frame(width: 40, height: 40)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))

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
                Text("\(exercise.muscleGroupRaw) · \(exercise.equipmentType)")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }

            Spacer()

            let ceiling = exercise.ceiling(for: "1RM")
            if ceiling > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(ceiling.cleanWeight)
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.gold)
                    Text("1RM")
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

    private func iconName(for muscle: MuscleGroup) -> String {
        switch muscle {
        case .chest: "figure.arms.open"
        case .lats: "figure.rower"
        case .quads, .hamstrings: "figure.strengthtraining.functional"
        case .deltoids: "figure.arms.open"
        case .triceps, .biceps, .forearms: "dumbbell.fill"
        case .core: "figure.core.training"
        case .calves: "figure.walk"
        case .glutes: "figure.squat"
        }
    }
}

// MARK: - Detail

struct ExerciseDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let exercise: Exercise

    private var records: [PRRecord] {
        exercise.prRecords.sorted { $0.dateAchieved > $1.dateAchieved }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                detailHeader

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
                Text("\(exercise.muscleGroupRaw) · \(exercise.equipmentType)")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }

            Spacer()
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

    // MARK: Configuration

    private var configCard: some View {
        VStack(spacing: 0) {
            configRow("Primary", exercise.muscleGroupRaw)
            if !exercise.secondaryMuscles.isEmpty {
                divider
                configRow("Secondary", exercise.secondaryMuscles.joined(separator: ", "))
            }
            divider
            configRow("Tracking", exercise.trackingType.rawValue)
            divider
            configRow("Increment", "\(exercise.defaultIncrement.cleanWeight) lbs")
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

            Text(record.numericValue.cleanWeight)
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(Theme.gold)
        }
        .cardStyle()
    }
}
