import SwiftUI
import SwiftData

/// The Library tab on iPad: filters on the left, a gallery on the right.
///
/// On the phone the catalog is a list of 40pt thumbnails behind a chip bar.
/// The iPad has room to actually *show* the movements, so the exercises become
/// an artwork gallery and the muscle filters get a permanent sidebar with live
/// counts — you can see the shape of your catalog, not just scroll it.
struct LibraryPadView: View {
    @Environment(WorkoutManager.self) private var workout

    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @Query(filter: #Predicate<Routine> { !$0.isPlanDay },
           sort: \Routine.createdAt, order: .reverse) private var routines: [Routine]

    @State private var section: PadLibrarySection = .exercises
    @State private var searchText = ""
    @State private var muscleFilter: MuscleGroup?
    @State private var showExerciseCreator = ProcessInfo.processInfo.arguments.contains("-open-forge")
    @State private var newRoutine: Routine?
    @State private var routineToDelete: Routine?

    enum PadLibrarySection: String, CaseIterable, Identifiable {
        case exercises = "Exercises"
        case routines = "Routines"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .exercises: "dumbbell.fill"
            case .routines: "square.stack.3d.up.fill"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 340)
        } detail: {
            NavigationStack {
                gallery
            }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(Theme.emerald)
        .sheet(isPresented: $showExerciseCreator) { ExerciseEditorView() }
        .alert("Delete Routine?", isPresented: deleteAlertBinding, presenting: routineToDelete) { routine in
            Button("Delete", role: .destructive) { workout.deleteRoutine(routine) }
            Button("Cancel", role: .cancel) {}
        } message: { routine in
            Text("\u{201C}\(routine.name)\u{201D} will be removed. Your logged workouts are not affected.")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                PadScreenHeader(title: "Library", subtitle: nil) {
                    PadIconButton(
                        systemName: "plus",
                        tint: Theme.emerald,
                        accessibilityName: section == .routines ? "New routine" : "New exercise"
                    ) { addTapped() }
                }

                VStack(spacing: 8) {
                    ForEach(PadLibrarySection.allCases) { candidate in
                        sectionButton(candidate)
                    }
                }

                PadSearchField(
                    prompt: section == .routines ? "Search routines" : "Search movements",
                    text: $searchText
                )

                if section == .exercises {
                    muscleFilterList
                } else {
                    routineStats
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, PadLayout.scrollBottomInset)
        }
        .obsidianBackground()
        .toolbar(.hidden, for: .navigationBar)
        .scrollDismissesKeyboard(.interactively)
    }

    private func sectionButton(_ candidate: PadLibrarySection) -> some View {
        let isSelected = section == candidate
        let count = candidate == .exercises ? exercises.count : routines.count
        return Button {
            Haptics.shared.tick()
            withAnimation(.snappy) {
                section = candidate
                searchText = ""
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: candidate.icon)
                    .font(.subheadline)
                    .frame(width: 26)
                Text(candidate.rawValue)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(count)")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .opacity(0.7)
            }
            .foregroundStyle(isSelected ? .black : .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                isSelected ? AnyShapeStyle(Theme.emerald) : AnyShapeStyle(Color.white.opacity(0.04)),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    /// Every muscle group with how many movements it holds — the catalog's
    /// shape at a glance, and a one-tap filter.
    private var muscleFilterList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MUSCLE GROUP")
                .font(.caption.weight(.bold))
                .kerning(1.5)
                .foregroundStyle(Theme.textDim)

            filterRow(nil, count: exercises.count)
            ForEach(MuscleGroup.allCases) { muscle in
                let count = exercises.filter { $0.muscleGroupRaw == muscle.rawValue }.count
                if count > 0 { filterRow(muscle, count: count) }
            }
        }
    }

    private func filterRow(_ muscle: MuscleGroup?, count: Int) -> some View {
        let isSelected = muscleFilter == muscle
        return Button {
            Haptics.shared.tick()
            withAnimation(.snappy) { muscleFilter = muscle }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: muscle?.iconName ?? "square.grid.2x2.fill")
                    .font(.caption)
                    .frame(width: 22)
                    .foregroundStyle(isSelected ? Theme.emerald : Theme.textDim)
                Text(muscle?.displayName ?? "All movements")
                    .font(.subheadline)
                Spacer()
                Text("\(count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textDim)
            }
            .foregroundStyle(isSelected ? Theme.emerald : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                isSelected ? AnyShapeStyle(Theme.emerald.opacity(0.14)) : AnyShapeStyle(Color.clear),
                in: RoundedRectangle(cornerRadius: 11)
            )
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
    }

    private var routineStats: some View {
        let aiCount = routines.filter(\.isAIGenerated).count
        let coached = routines.filter(\.hasPrescriptions).count
        return VStack(alignment: .leading, spacing: 8) {
            Text("ROUTINES")
                .font(.caption.weight(.bold))
                .kerning(1.5)
                .foregroundStyle(Theme.textDim)
            statLine(icon: "square.stack.3d.up.fill", tint: Theme.teal, label: "Saved", value: "\(routines.count)")
            statLine(icon: "sparkles", tint: Theme.violet, label: "AI-drafted", value: "\(aiCount)")
            statLine(icon: "target", tint: Theme.gold, label: "With targets", value: "\(coached)")
        }
    }

    private func statLine(icon: String, tint: Color, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption)
                .frame(width: 22)
                .foregroundStyle(tint)
            Text(label).font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Gallery

    @ViewBuilder
    private var gallery: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: galleryColumns, spacing: PadLayout.gutter) {
                switch section {
                case .exercises:
                    ForEach(filteredExercises, id: \.id) { exercise in
                        NavigationLink {
                            ExerciseDetailView(exercise: exercise)
                        } label: {
                            exerciseTile(exercise)
                        }
                        .buttonStyle(.plain)
                    }
                case .routines:
                    ForEach(filteredRoutines, id: \.id) { routine in
                        NavigationLink {
                            RoutineDetailView(routine: routine)
                        } label: {
                            routineTile(routine)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                routineToDelete = routine
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, PadLayout.screenPadding)
            .padding(.top, 8)
            .padding(.bottom, PadLayout.scrollBottomInset)

            if isGalleryEmpty { galleryEmptyState }
        }
        .obsidianBackground()
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $newRoutine) { RoutineDetailView(routine: $0) }
    }

    private var galleryColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 260, maximum: 380), spacing: PadLayout.gutter)]
    }

    /// A movement as a poster: its illustration on top, the numbers below.
    private func exerciseTile(_ exercise: Exercise) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if exercise.exampleImage != nil {
                    ExerciseVisual(exercise: exercise, height: 150)
                } else {
                    ZStack {
                        Theme.surfaceRaised
                        Image(systemName: exercise.muscleGroup.iconName)
                            .font(.system(size: 44))
                            .foregroundStyle(Theme.teal.opacity(0.8))
                    }
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                }

                if exercise.isCustom {
                    Text("CUSTOM")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Theme.violet.opacity(0.85), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(10)
                }
            }
            .frame(maxWidth: .infinity)
            .clipped()

            VStack(alignment: .leading, spacing: 6) {
                Text(exercise.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Text(exercise.muscleGroupDisplay)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.teal)
                    Text("\u{00B7}")
                        .foregroundStyle(Theme.textDim)
                    Text(exercise.equipmentType)
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                    Spacer(minLength: 0)

                    let ceiling = exercise.ceiling(for: "1RM")
                    if ceiling > 0 {
                        Text(exercise.usesWeightUnit
                             ? "\(exercise.displayWeightString(fromPounds: ceiling)) \(exercise.weightUnit.abbreviation)"
                             : ceiling.cleanWeight)
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.gold)
                    }
                }
            }
            .padding(14)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Theme.glassBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 7)
        .contentShape(RoundedRectangle(cornerRadius: 22))
    }

    private func routineTile(_ routine: Routine) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: routine.isAIGenerated ? "sparkles" : "square.stack.3d.up.fill")
                    .font(.title3)
                    .foregroundStyle(routine.isAIGenerated ? Theme.violet : Theme.teal)
                    .frame(width: 42, height: 42)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 3) {
                    Text(routine.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("\(routine.exerciseCount) exercise\(routine.exerciseCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                }
                Spacer(minLength: 0)
            }

            if !routine.exercises.isEmpty {
                Text(routine.exercises.map(\.name).joined(separator: " \u{00B7} "))
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if routine.hasPrescriptions {
                Label("Rep & load targets saved", systemImage: "target")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.gold)
            }

            Button {
                Haptics.shared.tick()
                workout.startSession(from: routine)
            } label: {
                Label("Start", systemImage: "play.fill")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .foregroundStyle(.white)
                    .glassCTA(tint: Theme.emerald.opacity(0.8), cornerRadius: 13)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Theme.glassBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 7)
        .contentShape(RoundedRectangle(cornerRadius: 22))
    }

    @ViewBuilder
    private var galleryEmptyState: some View {
        switch section {
        case .exercises:
            PadEmptyPane(
                icon: "dumbbell.fill",
                title: searchText.isEmpty ? "Nothing here yet" : "No matches",
                message: searchText.isEmpty
                    ? "Forge a custom movement with + to fill this shelf."
                    : "No movements match \u{201C}\(searchText)\u{201D}. Try a different filter, or forge it as a custom exercise."
            )
            .padding(.top, 60)
        case .routines:
            VStack(spacing: 14) {
                PadEmptyPane(
                    icon: "square.stack.3d.up.fill",
                    title: routines.isEmpty ? "No routines yet" : "No matches",
                    message: routines.isEmpty
                        ? "Curate a reusable workout — build it by hand or let the AI draft one. Saved routines quick-start from the Train tab."
                        : "No routines match \u{201C}\(searchText)\u{201D}."
                )
                if routines.isEmpty {
                    Button {
                        Haptics.shared.tick()
                        newRoutine = workout.createRoutine(name: "New Routine", items: [])
                    } label: {
                        Label("New Routine", systemImage: "plus")
                            .font(.headline)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 13)
                            .foregroundStyle(.white)
                            .glassCTA(tint: Theme.emerald.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 60)
        }
    }

    // MARK: - Data

    private var filteredExercises: [Exercise] {
        exercises.filter { exercise in
            FuzzySearch.matches(searchText, in: exercise.name)
                && (muscleFilter == nil || exercise.muscleGroupRaw == muscleFilter?.rawValue)
        }
    }

    private var filteredRoutines: [Routine] {
        guard !searchText.isEmpty else { return routines }
        return routines.filter { routine in
            FuzzySearch.matches(searchText, in: routine.name)
                || routine.exercises.contains { FuzzySearch.matches(searchText, in: $0.name) }
        }
    }

    private var isGalleryEmpty: Bool {
        section == .exercises ? filteredExercises.isEmpty : filteredRoutines.isEmpty
    }

    private func addTapped() {
        switch section {
        case .routines: newRoutine = workout.createRoutine(name: "New Routine", items: [])
        case .exercises: showExerciseCreator = true
        }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { routineToDelete != nil },
            set: { if !$0 { routineToDelete = nil } }
        )
    }
}
