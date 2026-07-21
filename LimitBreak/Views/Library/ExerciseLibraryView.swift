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
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            filterChip(nil)
                            ForEach(MuscleGroup.allCases) { muscle in
                                filterChip(muscle)
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                ForEach(filtered, id: \.id) { exercise in
                    NavigationLink {
                        ExerciseDetailView(exercise: exercise)
                    } label: {
                        exerciseRow(exercise)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search movements")
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCreator = true
                    } label: {
                        Label("New Exercise", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showCreator) {
                ExerciseEditorView()
            }
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
