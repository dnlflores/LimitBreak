import SwiftUI
import SwiftData

/// Lightweight fuzzy matching shared by the Library's search fields. A query
/// matches when every non-space character appears, in order, somewhere in the
/// candidate (a case- and diacritic-insensitive subsequence). So "blgs" matches
/// "Barbell Glute Bridges" and "legpr" matches "Leg Press". An empty query
/// matches everything.
enum FuzzySearch {
    static func matches(_ query: String, in candidate: String) -> Bool {
        let q = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if q.isEmpty { return true }
        let c = candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var idx = c.startIndex
        for ch in q where ch != " " {
            guard let found = c[idx...].firstIndex(of: ch) else { return false }
            idx = c.index(after: found)
        }
        return true
    }
}

/// The Library tab: a segmented switch between saved **Routines** (build, edit,
/// and start reusable workouts) and the **Exercises** catalog. Routines live here
/// now — the Train tab only quick-starts them. The "+" is contextual: it drafts a
/// new routine or forges a new exercise depending on the active section.
struct LibraryView: View {
    @Environment(WorkoutManager.self) private var workout
    // Plan-owned day routines live in the Plan tab, not the Library.
    @Query(filter: #Predicate<Routine> { !$0.isPlanDay },
           sort: \Routine.createdAt, order: .reverse) private var routines: [Routine]

    @State private var section: LibrarySection = .exercises
    /// Set to a freshly created routine to push its detail editor.
    @State private var newRoutine: Routine?
    @State private var routineToDelete: Routine?
    @State private var routineSearch = ""
    // Debug/UI-test hook: launch with "-open-forge" to present the exercise creator.
    @State private var showExerciseCreator = ProcessInfo.processInfo.arguments.contains("-open-forge")

    private enum LibrarySection: String, CaseIterable, Identifiable {
        case exercises = "Exercises"
        case routines = "Routines"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    sectionPicker

                    switch section {
                    case .routines: routinesSection
                    case .exercises: ExerciseLibraryContent()
                    }
                }
                .padding()
            }
            .obsidianBackground()
            .toolbar(.hidden, for: .navigationBar)
            .scrollDismissesKeyboard(.interactively)
            .navigationDestination(item: $newRoutine) { routine in
                RoutineDetailView(routine: routine)
            }
            .sheet(isPresented: $showExerciseCreator) {
                ExerciseEditorView()
            }
            .alert("Delete Routine?", isPresented: deleteAlertBinding, presenting: routineToDelete) { routine in
                Button("Delete", role: .destructive) {
                    workout.deleteRoutine(routine)
                }
                Button("Cancel", role: .cancel) {}
            } message: { routine in
                Text("\u{201C}\(routine.name)\u{201D} will be removed. Your logged workouts are not affected.")
            }
        }
    }

    // MARK: - Header & picker

    private var header: some View {
        HStack(alignment: .center) {
            Text("Library")
                .font(.largeTitle.bold())
            Spacer()
            Button {
                Haptics.shared.tick()
                addTapped()
            } label: {
                Image(systemName: "plus")
                    .font(.title2)
                    .glassCircle()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(section == .routines ? "New routine" : "New exercise")
        }
    }

    private var sectionPicker: some View {
        Picker("Library section", selection: $section) {
            ForEach(LibrarySection.allCases) { section in
                Text(section.rawValue).tag(section)
            }
        }
        .pickerStyle(.segmented)
    }

    /// Contextual create: draft a routine (and open it) or forge an exercise.
    private func addTapped() {
        switch section {
        case .routines:
            newRoutine = workout.createRoutine(name: "New Routine", items: [])
        case .exercises:
            showExerciseCreator = true
        }
    }

    // MARK: - Routines

    /// Routines whose name — or any contained exercise's name — fuzzy-matches
    /// the search query.
    private var filteredRoutines: [Routine] {
        guard !routineSearch.isEmpty else { return routines }
        return routines.filter { routine in
            FuzzySearch.matches(routineSearch, in: routine.name)
                || routine.exercises.contains { FuzzySearch.matches(routineSearch, in: $0.name) }
        }
    }

    @ViewBuilder
    private var routinesSection: some View {
        if routines.isEmpty {
            routinesEmptyState
        } else {
            LazyVStack(spacing: 14) {
                routineSearchField

                if filteredRoutines.isEmpty {
                    Text("No routines match \u{201C}\(routineSearch)\u{201D}.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .cardStyle()
                } else {
                    ForEach(filteredRoutines, id: \.id) { routine in
                        routineCard(routine)
                    }
                }
            }
        }
    }

    private var routineSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textDim)
            TextField("Search routines & exercises", text: $routineSearch)
                .textFieldStyle(.plain)
            if !routineSearch.isEmpty {
                Button {
                    routineSearch = ""
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

    private func routineCard(_ routine: Routine) -> some View {
        NavigationLink {
            RoutineDetailView(routine: routine)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(routine.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        HStack(spacing: 6) {
                            Text("\(routine.exerciseCount) exercise\(routine.exerciseCount == 1 ? "" : "s")")
                            if routine.isAIGenerated {
                                Label("AI", systemImage: "sparkles")
                                    .foregroundStyle(Theme.violet)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                    }
                    Spacer()
                    Menu {
                        Button(role: .destructive) {
                            routineToDelete = routine
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textDim)
                    }
                }

                if !routine.exercises.isEmpty {
                    Text(routine.exercises.map(\.name).joined(separator: " \u{00B7} "))
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                if routine.hasPrescriptions {
                    Label("Rep & load targets saved", systemImage: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(Theme.violet)
                }
            }
            .cardStyle()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var routinesEmptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.limitBreakGradient)
            Text("No routines yet")
                .font(.title3.weight(.bold))
            Text("Curate a reusable workout \u{2014} build it by hand or let the AI draft one. Saved routines quick-start from the Train tab.")
                .font(.subheadline)
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                Haptics.shared.tick()
                newRoutine = workout.createRoutine(name: "New Routine", items: [])
            } label: {
                Label("New Routine", systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .foregroundStyle(.white)
                    .glassCTA(tint: Theme.emerald.opacity(0.85))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { routineToDelete != nil },
            set: { if !$0 { routineToDelete = nil } }
        )
    }
}
