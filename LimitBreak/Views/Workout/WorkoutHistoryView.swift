import SwiftUI
import SwiftData
import MapKit
import CoreLocation

/// The training archive: a scrollable, month-grouped timeline of every workout
/// and walk ever logged. This is the single place to browse, edit, and delete
/// sessions and walks.
struct WorkoutHistoryView: View {
    @Environment(WorkoutManager.self) private var workout
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var allSessions: [WorkoutSession]
    @Query(sort: \Walk.date, order: .reverse) private var allWalks: [Walk]

    @State private var searchText = ""
    @State private var sessionToEdit: WorkoutSession?
    @State private var sessionToDelete: WorkoutSession?
    @State private var sessionToSaveAsRoutine: WorkoutSession?
    @State private var walkToEdit: Walk?
    @State private var walkToDelete: Walk?
    // Debug/UI-test hook: launch with "-open-first-workout" to push the newest
    // workout's detail view.
    @State private var debugOpenFirst = ProcessInfo.processInfo.arguments.contains("-open-first-workout")

    // MARK: - Timeline item

    /// A single entry in the unified history timeline: either a logged workout
    /// or a logged walk. Lets both appear interleaved by date.
    private enum TimelineItem: Identifiable {
        case session(WorkoutSession)
        case walk(Walk)

        var id: String {
            switch self {
            case .session(let session): return "session-\(session.id)"
            case .walk(let walk): return "walk-\(walk.id)"
            }
        }

        var date: Date {
            switch self {
            case .session(let session): return session.startDate
            case .walk(let walk): return walk.date
            }
        }
    }

    // MARK: - Derived data

    private var isEmpty: Bool { allSessions.isEmpty && allWalks.isEmpty }

    /// Sessions and walks, filtered by the search term and sorted newest first.
    /// Walks match only the term "walk" since they have no name or exercises.
    private var filteredItems: [TimelineItem] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        let sessionItems: [TimelineItem]
        let walkItems: [TimelineItem]

        if trimmed.isEmpty {
            sessionItems = allSessions.map(TimelineItem.session)
            walkItems = allWalks.map(TimelineItem.walk)
        } else {
            sessionItems = allSessions.filter { session in
                session.name.localizedCaseInsensitiveContains(trimmed)
                    || session.sets.contains {
                        $0.exercise?.name.localizedCaseInsensitiveContains(trimmed) ?? false
                    }
            }.map(TimelineItem.session)
            walkItems = "walk".localizedCaseInsensitiveContains(trimmed)
                ? allWalks.map(TimelineItem.walk)
                : []
        }

        return (sessionItems + walkItems).sorted { $0.date > $1.date }
    }

    /// Timeline items bucketed into month sections, newest month first.
    private var monthGroups: [(id: Date, label: String, items: [TimelineItem])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [TimelineItem]] = [:]
        for item in filteredItems {
            let monthStart = calendar.date(
                from: calendar.dateComponents([.year, .month], from: item.date)
            ) ?? item.date
            if buckets[monthStart] == nil { order.append(monthStart) }
            buckets[monthStart, default: []].append(item)
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

                    if isEmpty {
                        emptyState
                    } else {
                        searchField

                        summaryHeader

                        ForEach(monthGroups, id: \.id) { group in
                            Section {
                                ForEach(group.items) { item in
                                    timelineCard(item)
                                }
                            } header: {
                                monthHeader(group.label, count: group.items.count)
                            }
                        }

                        if filteredItems.isEmpty {
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
            .scrollDismissesKeyboard(.interactively)
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
            .sheet(item: $walkToEdit) { walk in
                EditWalkSheet(walk: walk)
            }
            .alert("Delete Walk?", isPresented: deleteWalkAlertBinding, presenting: walkToDelete) { walk in
                Button("Delete", role: .destructive) {
                    modelContext.delete(walk)
                    try? modelContext.save()
                }
                Button("Cancel", role: .cancel) {}
            } message: { walk in
                Text("This \(String(format: "%.2f mi", walk.distanceMiles)) walk will be permanently removed.")
            }
            .navigationDestination(isPresented: $debugOpenFirst) {
                if let first = allSessions.first {
                    WorkoutDetailView(session: first)
                }
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

    /// Bridges the `presenting:` alert to the optional walk state.
    private var deleteWalkAlertBinding: Binding<Bool> {
        Binding(
            get: { walkToDelete != nil },
            set: { if !$0 { walkToDelete = nil } }
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

    // MARK: - Timeline card

    @ViewBuilder
    private func timelineCard(_ item: TimelineItem) -> some View {
        switch item {
        case .session(let session): sessionCard(session)
        case .walk(let walk): walkCard(walk)
        }
    }

    // MARK: - Session card

    private func sessionCard(_ session: WorkoutSession) -> some View {
        NavigationLink {
            WorkoutDetailView(session: session)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
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
            }
            .cardStyle()
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
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

    // MARK: - Walk card

    private func walkCard(_ walk: Walk) -> some View {
        NavigationLink {
            WalkDetailView(walk: walk)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Walk")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(walk.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(Theme.textDim)
                        }
                    } icon: {
                        Image(systemName: "figure.walk")
                            .foregroundStyle(Theme.teal)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.2f mi", walk.distanceMiles))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.teal)
                        if walk.durationSeconds > 0 {
                            Text(walk.durationSeconds.clockString)
                                .font(.caption)
                                .foregroundStyle(Theme.textDim)
                        }
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textDim)
                }

                if walk.routePoints.count >= 2 {
                    routePreview(walk)
                }
            }
            .cardStyle()
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                walkToEdit = walk
            } label: {
                Label("Edit Walk", systemImage: "pencil")
            }
            Button(role: .destructive) {
                walkToDelete = walk
            } label: {
                Label("Delete Walk", systemImage: "trash")
            }
        }
    }

    private func routePreview(_ walk: Walk) -> some View {
        let coordinates = walk.routePoints.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        return Map(interactionModes: []) {
            MapPolyline(coordinates: coordinates)
                .stroke(Theme.teal, lineWidth: 4)
        }
        .frame(height: 130)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .allowsHitTesting(false)
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

