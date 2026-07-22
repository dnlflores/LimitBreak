import SwiftUI
import SwiftData

/// The training archive: a scrollable, month-grouped timeline of every workout
/// ever logged. This is the single place to browse, edit, and delete sessions.
struct WorkoutHistoryView: View {
    @Environment(WorkoutManager.self) private var workout
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var allSessions: [WorkoutSession]

    @State private var searchText = ""
    @State private var sessionToEdit: WorkoutSession?
    @State private var sessionToDelete: WorkoutSession?
    @State private var sessionToSaveAsRoutine: WorkoutSession?
    @State private var expandedSessions: Set<UUID> = []

    // MARK: - Derived data

    private var filteredSessions: [WorkoutSession] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return allSessions }
        return allSessions.filter { session in
            session.name.localizedCaseInsensitiveContains(trimmed)
                || session.sets.contains {
                    $0.exercise?.name.localizedCaseInsensitiveContains(trimmed) ?? false
                }
        }
    }

    /// Sessions bucketed into month sections, newest month first.
    private var monthGroups: [(id: Date, label: String, sessions: [WorkoutSession])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [WorkoutSession]] = [:]
        for session in filteredSessions {
            let monthStart = calendar.date(
                from: calendar.dateComponents([.year, .month], from: session.startDate)
            ) ?? session.startDate
            if buckets[monthStart] == nil { order.append(monthStart) }
            buckets[monthStart, default: []].append(session)
        }
        return order.map { month in
            (month, month.formatted(.dateTime.month(.wide).year()), buckets[month] ?? [])
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                    titleHeader

                    if allSessions.isEmpty {
                        emptyState
                    } else {
                        searchField

                        summaryHeader

                        ForEach(monthGroups, id: \.id) { group in
                            Section {
                                ForEach(group.sessions, id: \.id) { session in
                                    sessionCard(session)
                                }
                            } header: {
                                monthHeader(group.label, count: group.sessions.count)
                            }
                        }

                        if filteredSessions.isEmpty {
                            Text("No workouts match \u{201C}\(searchText)\u{201D}.")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textDim)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .cardStyle()
                        }
                    }
                }
                .padding()
            }
            .obsidianBackground()
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $sessionToEdit) { session in
                EditWorkoutView(session: session)
            }
            .sheet(item: $sessionToSaveAsRoutine) { session in
                RoutineEditorView(
                    seedName: session.name,
                    seedItems: session.setsByExercise.map { group in
                        (exercise: group.exercise, targetSets: max(1, group.sets.filter { !$0.isWarmup }.count))
                    }
                )
            }
            .alert("Delete Workout?", isPresented: deleteAlertBinding, presenting: sessionToDelete) { session in
                Button("Delete", role: .destructive) {
                    workout.deleteSession(session)
                }
                Button("Cancel", role: .cancel) {}
            } message: { session in
                Text("\u{201C}\(session.name)\u{201D} and all its sets will be permanently removed. Records will be recalculated.")
            }
        }
    }

    /// Bridges the `presenting:` alert to the optional session state.
    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { sessionToDelete != nil },
            set: { if !$0 { sessionToDelete = nil } }
        )
    }

    // MARK: - Title & search

    private var titleHeader: some View {
        HStack(alignment: .center) {
            Text("History")
                .font(.largeTitle.bold())
            Spacer()
        }
        .padding(.bottom, 8)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textDim)
            TextField("Search by name or exercise", text: $searchText)
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

    // MARK: - Summary

    private var summaryHeader: some View {
        let volume = allSessions.reduce(0) { $0 + $1.totalVolume }
        let prCount = allSessions.reduce(0) { $0 + $1.prCount }

        return HStack(spacing: 12) {
            summaryTile(value: "\(allSessions.count)", label: "workouts", color: Theme.teal)
            summaryTile(value: Int(volume).formatted(.number.notation(.compactName)), label: "lbs shifted", color: Theme.emerald)
            summaryTile(value: "\(prCount)", label: "LimitBreaks", color: Theme.gold)
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

    // MARK: - Month header

    private func monthHeader(_ label: String, count: Int) -> some View {
        HStack {
            Text(label.uppercased())
                .font(.caption.weight(.bold))
                .kerning(1.5)
                .foregroundStyle(Theme.textDim)
            Spacer()
            Text("\(count)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Theme.textDim)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Theme.surfaceRaised, in: Capsule())
        }
        .padding(.vertical, 6)
        .background(Theme.canvas.opacity(0.01))
    }

    // MARK: - Session card

    private func sessionCard(_ session: WorkoutSession) -> some View {
        let isExpanded = expandedSessions.contains(session.id)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.name)
                        .font(.headline)
                    Text("\(session.startDate.formatted(date: .abbreviated, time: .shortened)) \u{00B7} \(session.duration.clockString)")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                }
                Spacer()
                Text("\(Int(session.totalVolume).formatted()) lbs")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.emerald)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textDim)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }

            if isExpanded {
                ForEach(session.setsByExercise, id: \.exercise.id) { group in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(group.exercise.name)
                            .font(.subheadline.weight(.semibold))

                        ForEach(group.sets, id: \.id) { set in
                            setLine(set, exercise: group.exercise)
                        }
                    }
                    .padding(10)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                }

                if session.sets.isEmpty {
                    Text("No sets logged.")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                }
            }
        }
        .cardStyle()
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isExpanded {
                    expandedSessions.remove(session.id)
                } else {
                    expandedSessions.insert(session.id)
                }
            }
        }
        .contextMenu {
            Button {
                sessionToEdit = session
            } label: {
                Label("Edit Workout", systemImage: "pencil")
            }
            Button {
                sessionToSaveAsRoutine = session
            } label: {
                Label("Save as Routine", systemImage: "square.stack.3d.up")
            }
            Button(role: .destructive) {
                sessionToDelete = session
            } label: {
                Label("Delete Workout", systemImage: "trash")
            }
        }
    }

    private func setLine(_ set: ExerciseSet, exercise: Exercise) -> some View {
        HStack(spacing: 6) {
            Text(setDescription(set, exercise: exercise))
                .font(.caption)
                .monospacedDigit()
            if set.isWarmup {
                Text("WARMUP")
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Theme.surface, in: Capsule())
                    .foregroundStyle(Theme.textDim)
            }
            if set.isPR {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.gold)
            }
            Spacer()
        }
    }

    private func setDescription(_ set: ExerciseSet, exercise: Exercise) -> String {
        switch exercise.trackingType {
        case .durationAndReps:
            if let duration = set.durationSeconds { return "\(duration.clockString)" }
        case .timeAndDistance:
            if let distance = set.distanceMeters { return "\(Int(distance)) m" }
        case .customMetric:
            return "\(set.weight.cleanWeight) \(exercise.customMetricUnit ?? "")"
        case .weightAndReps, .bodyweightAndReps:
            break
        }
        return set.weight > 0
            ? "\(set.weight.cleanWeight) lbs \u{00D7} \(set.reps)"
            : "\(set.reps) reps"
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 56))
                .foregroundStyle(Theme.limitBreakGradient)
            Text("No workouts yet")
                .font(.title3.weight(.bold))
            Text("Finish a session on the Train tab and it will appear here, ready to review or edit.")
                .font(.subheadline)
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }
}
