import SwiftUI
import SwiftData

/// Browsable exercise catalog with per-movement record ledgers.
struct ExerciseLibraryView: View {
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @State private var searchText = ""
    @State private var muscleFilter: MuscleGroup?
    @State private var showCreator = false

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
            List {
                ForEach(filtered, id: \.id) { exercise in
                    NavigationLink {
                        ExerciseDetailView(exercise: exercise)
                    } label: {
                        exerciseRow(exercise)
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                topBar
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showCreator) {
                ExerciseEditorView()
            }
        }
    }

    /// Title, search, and filter pills as one pinned unit. The list scrolls
    /// beneath it, so its translucent material only reveals a blur once rows
    /// pass under while scrolling.
    private var topBar: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center) {
                Text("Library")
                    .font(.largeTitle.bold())
                Spacer()
                Button {
                    showCreator = true
                } label: {
                    Image(systemName: "plus")
                        .font(.title2)
                        .glassCircle()
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)

            searchField
                .padding(.horizontal)

            filterBar
        }
        .padding(.top, 16)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
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

    /// Horizontal muscle-group filter, part of the pinned top bar. Scrolls
    /// edge-to-edge while its chips stay inset.
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(nil)
                ForEach(MuscleGroup.allCases) { muscle in
                    filterChip(muscle)
                }
            }
            .padding(.horizontal)
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
        .background(isSelected ? Theme.emerald : Theme.surfaceRaised, in: Capsule())
        .foregroundStyle(isSelected ? .black : .primary)
    }

    private func exerciseRow(_ exercise: Exercise) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(exercise.name)
                    .font(.subheadline.weight(.semibold))
                if exercise.isCustom {
                    Text("CUSTOM")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Theme.violet.opacity(0.25), in: Capsule())
                        .foregroundStyle(Theme.violet)
                }
            }
            HStack(spacing: 4) {
                Text("\(exercise.muscleGroupRaw) · \(exercise.equipmentType)")
                let ceiling = exercise.ceiling(for: "1RM")
                if ceiling > 0 {
                    Text("· 1RM \(ceiling.cleanWeight)")
                        .foregroundStyle(Theme.gold)
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.textDim)
        }
    }
}

// MARK: - Detail

struct ExerciseDetailView: View {
    let exercise: Exercise

    private var records: [PRRecord] {
        exercise.prRecords.sorted { $0.dateAchieved > $1.dateAchieved }
    }

    var body: some View {
        List {
            Section("Configuration") {
                LabeledContent("Primary", value: exercise.muscleGroupRaw)
                if !exercise.secondaryMuscles.isEmpty {
                    LabeledContent("Secondary", value: exercise.secondaryMuscles.joined(separator: ", "))
                }
                LabeledContent("Tracking", value: exercise.trackingType.rawValue)
                LabeledContent("Equipment", value: exercise.equipmentType)
                LabeledContent("Increment", value: "\(exercise.defaultIncrement.cleanWeight) lbs")
                LabeledContent("Rest Timer", value: "\(exercise.defaultRestSeconds)s")
                LabeledContent("1RM Formula", value: exercise.formulaRaw)
            }

            Section("Record Ledger") {
                if records.isEmpty {
                    Text("No records yet. Every LimitBreak lands here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(records, id: \.id) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.recordType)
                                .font(.subheadline.weight(.semibold))
                            Text(record.dateAchieved.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(record.numericValue.cleanWeight)
                            .font(.headline)
                            .monospacedDigit()
                            .foregroundStyle(Theme.gold)
                    }
                }
            }
        }
        .navigationTitle(exercise.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
