import SwiftUI
import SwiftData
import MapKit
import CoreLocation

/// One entry in the iPad archive's browser.
enum PadHistoryEntry: Hashable {
    case session(WorkoutSession)
    case walk(Walk)
    case activity(Activity)

    var date: Date {
        switch self {
        case .session(let session): session.startDate
        case .walk(let walk): walk.date
        case .activity(let activity): activity.date
        }
    }
}

/// The History tab on iPad: a browser on the left, the full battle report on
/// the right.
///
/// The phone can only show one thing at a time, so reviewing an old workout
/// means losing your place in the timeline. Here the archive stays put while
/// reports open beside it — and the detail column doubles as an analytics
/// board whenever nothing is selected.
struct HistoryPadView: View {
    @Environment(WorkoutManager.self) private var workout
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var allSessions: [WorkoutSession]
    @Query(sort: \Walk.date, order: .reverse) private var allWalks: [Walk]
    @Query(sort: \Activity.date, order: .reverse) private var allActivities: [Activity]
    @Query(sort: \PRRecord.dateAchieved, order: .reverse) private var allRecords: [PRRecord]
    @Query private var allRoutines: [Routine]

    @State private var searchText = ""
    @State private var path: [PadHistoryEntry] = []
    @State private var showPastWorkout = false
    @State private var sessionToEdit: WorkoutSession?
    @State private var sessionToDelete: WorkoutSession?
    @State private var sessionToSaveAsRoutine: WorkoutSession?
    @State private var walkToEdit: Walk?
    @State private var walkToDelete: Walk?
    @State private var activityToEdit: Activity?
    @State private var activityToDelete: Activity?

    /// Whatever the detail column is currently showing, so the browser can mark it.
    private var selected: PadHistoryEntry? { path.last }

    var body: some View {
        NavigationSplitView {
            browser
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 460)
        } detail: {
            NavigationStack(path: $path) {
                analyticsBoard
                    .navigationDestination(for: PadHistoryEntry.self) { entry in
                        detailPane(entry)
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(Theme.emerald)
        .sheet(isPresented: $showPastWorkout) { PastWorkoutView() }
        .sheet(item: $sessionToEdit) { EditWorkoutView(session: $0) }
        .sheet(item: $walkToEdit) { EditWalkSheet(walk: $0) }
        .sheet(item: $activityToEdit) { ActivityLogView(activity: $0) }
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
                icon: "trash", tint: Theme.crimson,
                title: "Delete Workout?",
                message: "\u{201C}\(session.name)\u{201D} and all its sets will be permanently removed. Records will be recalculated.",
                confirmLabel: "Delete", cancelLabel: "Cancel"
            ) {
                if selected == .session(session) { path = [] }
                workout.deleteSession(session)
            }
        }
        .sheet(item: $walkToDelete) { walk in
            SessionConfirmSheet(
                icon: "trash", tint: Theme.crimson,
                title: "Delete Walk?",
                message: "This \(String(format: "%.2f mi", walk.distanceMiles)) walk will be permanently removed.",
                confirmLabel: "Delete", cancelLabel: "Cancel"
            ) {
                if selected == .walk(walk) { path = [] }
                modelContext.delete(walk)
                try? modelContext.save()
            }
        }
        .sheet(item: $activityToDelete) { activity in
            SessionConfirmSheet(
                icon: "trash", tint: Theme.crimson,
                title: "Delete Activity?",
                message: "This \(activity.durationMinutes)-minute \(activity.sport.rawValue.lowercased()) session will be permanently removed, along with the XP it earned.",
                confirmLabel: "Delete", cancelLabel: "Cancel"
            ) {
                if selected == .activity(activity) { path = [] }
                modelContext.delete(activity)
                try? modelContext.save()
                WidgetSnapshotter.shared.refresh()
            }
        }
    }

    // MARK: - Browser column

    private var browser: some View {
        VStack(spacing: 14) {
            PadScreenHeader(title: "History", subtitle: "\(filteredEntries.count) logged") {
                PadIconButton(systemName: "plus", accessibilityName: "Log a past workout") {
                    showPastWorkout = true
                }
            }

            PadSearchField(prompt: "Search by name or exercise", text: $searchText)

            if isEmpty {
                emptyBrowser
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                        ForEach(monthGroups, id: \.id) { group in
                            Section {
                                ForEach(group.entries, id: \.self) { entry in
                                    browserRow(entry)
                                }
                            } header: {
                                monthHeader(group.label, count: group.entries.count)
                            }
                        }

                        if filteredEntries.isEmpty {
                            Text("Nothing matches \u{201C}\(searchText)\u{201D}.")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textDim)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 40)
                        }
                    }
                    .padding(.bottom, PadLayout.scrollBottomInset)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .obsidianBackground()
        .toolbar(.hidden, for: .navigationBar)
        .scrollDismissesKeyboard(.interactively)
    }

    private var emptyBrowser: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundStyle(Theme.limitBreakGradient)
            Text("No workouts yet")
                .font(.headline)
            Text("Finish a session on the Train tab and it lands here.")
                .font(.caption)
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

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
        .padding(.vertical, 8)
        .background(Theme.background.opacity(0.92))
    }

    @ViewBuilder
    private func browserRow(_ entry: PadHistoryEntry) -> some View {
        let isSelected = selected == entry
        Button {
            Haptics.shared.tick()
            path = [entry]
        } label: {
            HStack(spacing: 12) {
                Image(systemName: entryIcon(entry))
                    .font(.subheadline)
                    .foregroundStyle(entryTint(entry))
                    .frame(width: 36, height: 36)
                    .background(entryTint(entry).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entryTitle(entry))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if case .session(let session) = entry {
                            PartnerBadge(trainedWithPartner: session.trainedWithPartner, compact: true)
                        }
                    }
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                }

                Spacer(minLength: 4)

                Text(entryMetric(entry))
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(entryTint(entry))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                isSelected ? AnyShapeStyle(Theme.emerald.opacity(0.16)) : AnyShapeStyle(Color.white.opacity(0.03)),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isSelected ? Theme.emerald.opacity(0.5) : .clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .contextMenu { rowMenu(entry) }
    }

    @ViewBuilder
    private func rowMenu(_ entry: PadHistoryEntry) -> some View {
        switch entry {
        case .session(let session):
            Button { sessionToEdit = session } label: { Label("Edit Workout", systemImage: "pencil") }
            Button { sessionToSaveAsRoutine = session } label: { Label("Save as Routine", systemImage: "square.stack.3d.up") }
            Button(role: .destructive) { sessionToDelete = session } label: { Label("Delete Workout", systemImage: "trash") }
        case .walk(let walk):
            Button { walkToEdit = walk } label: { Label("Edit Walk", systemImage: "pencil") }
            Button(role: .destructive) { walkToDelete = walk } label: { Label("Delete Walk", systemImage: "trash") }
        case .activity(let activity):
            Button { activityToEdit = activity } label: { Label("Edit Activity", systemImage: "pencil") }
            Button(role: .destructive) { activityToDelete = activity } label: { Label("Delete Activity", systemImage: "trash") }
        }
    }

    // MARK: - Detail column

    @ViewBuilder
    private func detailPane(_ entry: PadHistoryEntry) -> some View {
        switch entry {
        case .session(let session): WorkoutDetailView(session: session)
        case .walk(let walk): WalkDetailView(walk: walk)
        case .activity(let activity): activityPane(activity)
        }
    }

    /// Activities have no report screen of their own — a sport, a duration and
    /// a date is the whole record — so the pane summarises and offers the same
    /// edit/delete powers the browser row's menu has.
    private func activityPane(_ activity: Activity) -> some View {
        VStack(spacing: 20) {
            Image(systemName: activity.sport.icon)
                .font(.system(size: 64))
                .foregroundStyle(Theme.coral)
                .frame(width: 128, height: 128)
                .background(Theme.coral.opacity(0.12), in: Circle())
                .overlay(Circle().strokeBorder(Theme.coral.opacity(0.25), lineWidth: 1))

            VStack(spacing: 6) {
                Text(activity.sport.rawValue)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text(activity.date.formatted(date: .complete, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(Theme.textDim)
            }

            HStack(spacing: 14) {
                PadStatTile(icon: "clock.fill", value: "\(activity.durationMinutes)", label: "Minutes", tint: Theme.coral)
                PadStatTile(icon: "sparkles", value: "+\(XPEngine.xp(for: activity))", label: "XP earned", tint: Theme.gold)
            }
            .frame(maxWidth: 460)

            HStack(spacing: 12) {
                Button {
                    activityToEdit = activity
                } label: {
                    Label("Edit", systemImage: "pencil")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 22).padding(.vertical, 13)
                        .glassControl()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    activityToDelete = activity
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.crimson)
                        .padding(.horizontal, 22).padding(.vertical, 13)
                        .glassControl()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .obsidianBackground()
        .toolbar(.hidden, for: .navigationBar)
    }

    /// The detail column when nothing is picked: the all-time numbers, the
    /// output chart, and the record ledger — an archive front page rather than
    /// a "select an item" apology.
    private var analyticsBoard: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= 760
            ScrollView(showsIndicators: false) {
                VStack(spacing: PadLayout.gutter) {
                    PadScreenHeader(
                        title: "Training Archive",
                        subtitle: "Everything you've logged, all in one ledger."
                    ) { EmptyView() }

                    allTimeTiles

                    ProgressChartView(sessions: allSessions)

                    if wide {
                        HStack(alignment: .top, spacing: PadLayout.gutter) {
                            recordsPanel
                            breakdownPanel
                        }
                    } else {
                        recordsPanel
                        breakdownPanel
                    }
                }
                .padding(.horizontal, PadLayout.screenPadding)
                .padding(.top, 4)
                .padding(.bottom, PadLayout.scrollBottomInset)
            }
        }
        .obsidianBackground()
        .toolbar(.hidden, for: .navigationBar)
    }

    private var allTimeTiles: some View {
        let volume = allSessions.reduce(0) { $0 + $1.totalVolume }
        let prCount = allSessions.reduce(0) { $0 + $1.prCount }
        let totalXP = XPEngine.progress(
            sessions: allSessions, records: allRecords, walks: allWalks,
            activities: allActivities, routines: allRoutines,
            stepGoalDays: StepGoalStore.achievedDays()
        ).totalXP

        return HStack(spacing: 12) {
            PadStatTile(icon: "figure.strengthtraining.traditional", value: "\(allSessions.count)", label: "Workouts", tint: Theme.teal)
            PadStatTile(icon: "sparkles", value: totalXP.formatted(.number.notation(.compactName)), label: "XP earned", tint: Theme.violet)
            PadStatTile(icon: "scalemass.fill", value: Int(volume).formatted(.number.notation(.compactName)), label: "lbs shifted", tint: Theme.emerald)
            PadStatTile(icon: "crown.fill", value: "\(prCount)", label: "LimitBreaks", tint: Theme.gold)
        }
    }

    private var recordsPanel: some View {
        PadPanel("RECORD LEDGER") {
            if allRecords.isEmpty {
                Text("No records yet. Every LimitBreak lands here.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 10) {
                    ForEach(allRecords.prefix(10), id: \.id) { record in
                        HStack(spacing: 12) {
                            Image(systemName: "crown.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.gold)
                                .frame(width: 32, height: 32)
                                .background(Theme.gold.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(record.exercise?.name ?? "Movement")
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text("\(record.recordType) \u{00B7} \(record.dateAchieved.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textDim)
                            }
                            Spacer(minLength: 4)
                            Text(record.numericValue.cleanWeight)
                                .font(.subheadline.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.gold)
                        }
                    }
                }
            }
        }
    }

    private var breakdownPanel: some View {
        let walkMiles = allWalks.reduce(0) { $0 + $1.distanceMiles }
        let sportMinutes = allActivities.reduce(0) { $0 + $1.durationMinutes }
        let liftMinutes = Int(allSessions.reduce(0) { $0 + $1.duration } / 60)

        return PadPanel("WHAT YOU'VE DONE") {
            VStack(spacing: 12) {
                breakdownRow(icon: "figure.strengthtraining.traditional", tint: Theme.emerald,
                             label: "Lifting", value: "\(allSessions.count) sessions \u{00B7} \(liftMinutes.formatted()) min")
                breakdownRow(icon: "figure.walk", tint: Theme.teal,
                             label: "Walking", value: "\(allWalks.count) walks \u{00B7} \(String(format: "%.1f", walkMiles)) mi")
                breakdownRow(icon: "sportscourt.fill", tint: Theme.coral,
                             label: "Sport", value: "\(allActivities.count) sessions \u{00B7} \(sportMinutes.formatted()) min")
            }
        }
    }

    private func breakdownRow(icon: String, tint: Color, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            Text(label)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 4)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.textDim)
        }
    }

    // MARK: - Row presentation

    private func entryIcon(_ entry: PadHistoryEntry) -> String {
        switch entry {
        case .session: "figure.strengthtraining.traditional"
        case .walk: "figure.walk"
        case .activity(let activity): activity.sport.icon
        }
    }

    private func entryTint(_ entry: PadHistoryEntry) -> Color {
        switch entry {
        case .session: Theme.emerald
        case .walk: Theme.teal
        case .activity: Theme.coral
        }
    }

    private func entryTitle(_ entry: PadHistoryEntry) -> String {
        switch entry {
        case .session(let session): session.name
        case .walk: "Walk"
        case .activity(let activity): activity.sport.rawValue
        }
    }

    private func entryMetric(_ entry: PadHistoryEntry) -> String {
        switch entry {
        case .session(let session): "\(Int(session.totalVolume).formatted()) lbs"
        case .walk(let walk): String(format: "%.2f mi", walk.distanceMiles)
        case .activity(let activity): "\(activity.durationMinutes) min"
        }
    }

    // MARK: - Data

    private var isEmpty: Bool { allSessions.isEmpty && allWalks.isEmpty && allActivities.isEmpty }

    private var filteredEntries: [PadHistoryEntry] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        let sessionEntries: [PadHistoryEntry]
        let walkEntries: [PadHistoryEntry]
        let activityEntries: [PadHistoryEntry]

        if trimmed.isEmpty {
            sessionEntries = allSessions.map(PadHistoryEntry.session)
            walkEntries = allWalks.map(PadHistoryEntry.walk)
            activityEntries = allActivities.map(PadHistoryEntry.activity)
        } else {
            sessionEntries = allSessions.filter { session in
                session.name.localizedCaseInsensitiveContains(trimmed)
                    || session.sets.contains { $0.exercise?.name.localizedCaseInsensitiveContains(trimmed) ?? false }
            }.map(PadHistoryEntry.session)
            walkEntries = "walk".localizedCaseInsensitiveContains(trimmed)
                ? allWalks.map(PadHistoryEntry.walk) : []
            let matchesAll = "activity".localizedCaseInsensitiveContains(trimmed)
            activityEntries = allActivities.filter {
                matchesAll || $0.sport.rawValue.localizedCaseInsensitiveContains(trimmed)
            }.map(PadHistoryEntry.activity)
        }

        return (sessionEntries + walkEntries + activityEntries).sorted { $0.date > $1.date }
    }

    private var monthGroups: [(id: Date, label: String, entries: [PadHistoryEntry])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [PadHistoryEntry]] = [:]
        for entry in filteredEntries {
            let monthStart = calendar.date(
                from: calendar.dateComponents([.year, .month], from: entry.date)
            ) ?? entry.date
            if buckets[monthStart] == nil { order.append(monthStart) }
            buckets[monthStart, default: []].append(entry)
        }
        return order.map { ($0, $0.formatted(.dateTime.month(.wide).year()), buckets[$0] ?? []) }
    }
}
