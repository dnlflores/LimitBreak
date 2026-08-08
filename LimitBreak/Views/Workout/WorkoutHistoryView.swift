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
    @Query(sort: \Activity.date, order: .reverse) private var allActivities: [Activity]
    @Query(sort: \PRRecord.dateAchieved, order: .reverse) private var allRecords: [PRRecord]
    @Query private var allRoutines: [Routine]

    @State private var searchText = ""
    @State private var sessionToEdit: WorkoutSession?
    @State private var sessionToDelete: WorkoutSession?
    @State private var sessionToSaveAsRoutine: WorkoutSession?
    @State private var walkToEdit: Walk?
    @State private var walkToDelete: Walk?
    @State private var activityToEdit: Activity?
    @State private var activityToDelete: Activity?
    @State private var showPastWorkout = false
    // Debug/UI-test hook: launch with "-open-first-workout" to push the newest
    // workout's detail view.
    @State private var debugOpenFirst = ProcessInfo.processInfo.arguments.contains("-open-first-workout")

    // MARK: - Timeline item

    /// A single entry in the unified history timeline: either a logged workout
    /// or a logged walk. Lets both appear interleaved by date.
    private enum TimelineItem: Identifiable {
        case session(WorkoutSession)
        case walk(Walk)
        case activity(Activity)

        var id: String {
            switch self {
            case .session(let session): return "session-\(session.id)"
            case .walk(let walk): return "walk-\(walk.id)"
            case .activity(let activity): return "activity-\(activity.id)"
            }
        }

        var date: Date {
            switch self {
            case .session(let session): return session.startDate
            case .walk(let walk): return walk.date
            case .activity(let activity): return activity.date
            }
        }
    }

    // MARK: - Derived data

    private var isEmpty: Bool { allSessions.isEmpty && allWalks.isEmpty && allActivities.isEmpty }

    /// Sessions, walks and activities, filtered by the search term and sorted
    /// newest first. Walks match only the term "walk" since they have no name or
    /// exercises; activities match their sport ("basketball") or the catch-all
    /// "activity".
    private var filteredItems: [TimelineItem] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        let sessionItems: [TimelineItem]
        let walkItems: [TimelineItem]
        let activityItems: [TimelineItem]

        if trimmed.isEmpty {
            sessionItems = allSessions.map(TimelineItem.session)
            walkItems = allWalks.map(TimelineItem.walk)
            activityItems = allActivities.map(TimelineItem.activity)
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
            let matchesAll = "activity".localizedCaseInsensitiveContains(trimmed)
            activityItems = allActivities.filter { activity in
                matchesAll || activity.sport.rawValue.localizedCaseInsensitiveContains(trimmed)
            }.map(TimelineItem.activity)
        }

        return (sessionItems + walkItems + activityItems).sorted { $0.date > $1.date }
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
                LazyVStack(alignment: .leading, spacing: 14) {
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
            .sheet(isPresented: $showPastWorkout) {
                PastWorkoutView()
            }
            .sheet(item: $sessionToEdit) { session in
                EditWorkoutView(session: session)
            }
            .sheet(item: $sessionToSaveAsRoutine) { session in
                RoutineEditorView(
                    seedName: session.name,
                    seedItems: session.setsByExercise.map { group in
                        (exercise: group.exercise,
                         targetSets: max(1, group.sets.filter { !$0.isWarmup }.count),
                         supersetGroup: group.sets.first?.supersetGroup)
                    }
                )
            }
            .sheet(item: $sessionToDelete) { session in
                SessionConfirmSheet(
                    icon: "trash",
                    tint: Theme.crimson,
                    title: "Delete Workout?",
                    message: "\u{201C}\(session.name)\u{201D} and all its sets will be permanently removed. Records will be recalculated.",
                    confirmLabel: "Delete",
                    cancelLabel: "Cancel"
                ) {
                    workout.deleteSession(session)
                }
            }
            .sheet(item: $walkToEdit) { walk in
                EditWalkSheet(walk: walk)
            }
            .sheet(item: $activityToEdit) { activity in
                ActivityLogView(activity: activity)
            }
            .sheet(item: $activityToDelete) { activity in
                SessionConfirmSheet(
                    icon: "trash",
                    tint: Theme.crimson,
                    title: "Delete Activity?",
                    message: "This \(activity.durationMinutes)-minute \(activity.sport.rawValue.lowercased()) session will be permanently removed, along with the XP it earned.",
                    confirmLabel: "Delete",
                    cancelLabel: "Cancel"
                ) {
                    modelContext.delete(activity)
                    try? modelContext.save()
                    WidgetSnapshotter.shared.refresh()
                }
            }
            .sheet(item: $walkToDelete) { walk in
                SessionConfirmSheet(
                    icon: "trash",
                    tint: Theme.crimson,
                    title: "Delete Walk?",
                    message: "This \(String(format: "%.2f mi", walk.distanceMiles)) walk will be permanently removed.",
                    confirmLabel: "Delete",
                    cancelLabel: "Cancel"
                ) {
                    modelContext.delete(walk)
                    try? modelContext.save()
                }
            }
            .navigationDestination(isPresented: $debugOpenFirst) {
                if let first = allSessions.first {
                    WorkoutDetailView(session: first)
                }
            }
        }
    }

    // MARK: - Title & search

    private var titleHeader: some View {
        HStack(alignment: .center) {
            Text("History")
                .font(.largeTitle.bold())
            Spacer()
            Button {
                Haptics.shared.tick()
                showPastWorkout = true
            } label: {
                Image(systemName: "plus")
                    .font(.headline)
                    .glassCircle()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Log a past workout")
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
        let totalXP = XPEngine.progress(
            sessions: allSessions, records: allRecords, walks: allWalks,
            activities: allActivities, routines: allRoutines,
            stepGoalDays: StepGoalStore.achievedDays()
        ).totalXP

        return VStack(alignment: .leading, spacing: 14) {
            Text("ALL-TIME STATS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textDim)
                .kerning(1.5)

            HStack(spacing: 0) {
                summaryStat(value: "\(allSessions.count)", label: "workouts", color: Theme.teal)
                statDivider
                summaryStat(value: totalXP.formatted(.number.notation(.compactName)), label: "XP earned", color: Theme.violet)
                statDivider
                summaryStat(value: Int(volume).formatted(.number.notation(.compactName)), label: "lbs shifted", color: Theme.emerald)
                statDivider
                summaryStat(value: "\(prCount)", label: "LimitBreaks", color: Theme.gold)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func summaryStat(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    /// Hairline separator between the log's stats, so the row reads as one
    /// divided panel rather than four floating tiles.
    private var statDivider: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.white.opacity(0.08))
            .frame(width: 1, height: 34)
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
        case .activity(let activity): activityCard(activity)
        }
    }

    // MARK: - Activity card

    /// A logged cross-training session — pickup basketball, a volleyball night.
    /// There's no detail screen behind these (an activity is just a sport, a
    /// duration and a date), so the row carries its own edit/delete actions.
    private func activityCard(_ activity: Activity) -> some View {
        HStack(spacing: 10) {
            Image(systemName: activity.sport.icon)
                .font(.title3)
                .foregroundStyle(Theme.coral)
                .frame(width: 40, height: 40)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text(activity.sport.rawValue)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(activity.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(activity.durationMinutes) min")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.coral)
                Text("+\(XPEngine.xp(for: activity)) XP")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.gold)
            }
        }
        .cardStyle()
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .onTapGesture {
            Haptics.shared.tick()
            activityToEdit = activity
        }
        .contextMenu {
            Button {
                activityToEdit = activity
            } label: {
                Label("Edit Activity", systemImage: "pencil")
            }
            Button(role: .destructive) {
                activityToDelete = activity
            } label: {
                Label("Delete Activity", systemImage: "trash")
            }
        }
    }

    // MARK: - Session card

    private func sessionCard(_ session: WorkoutSession) -> some View {
        NavigationLink {
            WorkoutDetailView(session: session)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        PartnerBadge(trainedWithPartner: session.trainedWithPartner, compact: true)
                    }
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

