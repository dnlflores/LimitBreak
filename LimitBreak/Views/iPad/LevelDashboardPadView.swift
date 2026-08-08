import SwiftUI
import SwiftData

/// The Level tab on iPad: the Skill Matrix rebuilt as a true command dashboard.
///
/// The phone stacks nine sections into one long scroll. Here the same data is
/// laid out as a headline band (level, rank, and the four numbers that matter)
/// over two independently scrolling columns — analytics on the left, the live
/// feed of what you've earned on the right.
struct LevelDashboardPadView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var sessions: [WorkoutSession]
    @Query(sort: \Walk.date, order: .reverse) private var walks: [Walk]
    @Query(sort: \PRRecord.dateAchieved, order: .reverse) private var records: [PRRecord]
    @Query(sort: \Activity.date, order: .reverse) private var activities: [Activity]
    @Query private var routines: [Routine]

    @State private var selectedDay: Date?
    @State private var selectedStat: PadStatDetail?
    @State private var showHealthSheet = false
    @State private var showSettings = false
    @State private var showLevelSheet = ProcessInfo.processInfo.arguments.contains("-open-level")
    @State private var showTimeline = ProcessInfo.processInfo.arguments.contains("-open-timeline")

    /// The iPad shows five months of activity nodes where the phone shows five
    /// weeks at a time behind a horizontal scroll.
    private let weeksShown = 26

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let wide = proxy.size.width >= PadLayout.twoColumnMinWidth
                VStack(spacing: PadLayout.gutter) {
                    header
                    heroBand(wide: wide)

                    if wide {
                        HStack(alignment: .top, spacing: PadLayout.gutter) {
                            column { analyticsStack }
                            column { feedStack }
                                .frame(width: PadLayout.railWidth)
                        }
                    } else {
                        column {
                            VStack(spacing: PadLayout.gutter) {
                                analyticsStack
                                feedStack
                            }
                        }
                    }
                }
                .padding(.horizontal, PadLayout.screenPadding)
                .padding(.top, 4)
            }
            .obsidianBackground()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showTimeline) {
                RewardsTimelineView()
            }
            .sheet(item: $selectedDay) { day in
                DayDetailSheet(day: day)
            }
            .sheet(item: $selectedStat) { detail in
                PadStatDetailSheet(detail: detail)
            }
            .sheet(isPresented: $showHealthSheet) { HealthKitSheet() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showLevelSheet) { LevelDetailSheet(info: levelInfo) }
            .task { await HealthKitManager.shared.refreshTodayStats() }
        }
    }

    /// A dashboard column: its own scroll view so the analytics and the feed
    /// move independently, the way two panes of a workspace should.
    private func column<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(showsIndicators: false) {
            content()
                .padding(.bottom, PadLayout.scrollBottomInset)
        }
    }

    // MARK: - Header

    private var header: some View {
        PadScreenHeader(title: "Level Up", subtitle: heroSubtitle) {
            HStack(spacing: 12) {
                PadIconButton(
                    systemName: HealthKitManager.shared.isConnected ? "heart.fill" : "heart",
                    tint: Theme.crimson,
                    accessibilityName: "Apple Health"
                ) { showHealthSheet = true }

                PadIconButton(systemName: "gearshape.fill", accessibilityName: "Settings") {
                    showSettings = true
                }
            }
        }
    }

    private var heroSubtitle: String {
        let progress = xpProgress
        if progress.currentStreak == 0 {
            return "Train today to start a streak."
        }
        let days = "\(progress.currentStreak) day\(progress.currentStreak == 1 ? "" : "s") active"
        return progress.currentMultiplier > 1
            ? "\(days) · \u{00D7}\(progress.currentMultiplier) XP multiplier running"
            : days
    }

    // MARK: - Hero band

    /// Level, rank and the four headline numbers, spanning the full width.
    /// Beside the level card the tiles pair up two-by-two so their labels stay
    /// readable; stacked below it they spread across one row.
    @ViewBuilder
    private func heroBand(wide: Bool) -> some View {
        if wide {
            HStack(spacing: PadLayout.gutter) {
                // Fills the band so the seal sits level with the tile grid
                // beside it rather than leaving a gap underneath.
                levelCard
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2),
                    spacing: 12
                ) {
                    statTiles
                }
                .frame(maxWidth: .infinity)
            }
            // The level card asks to fill the band's height; without this the
            // band itself would turn greedy and squeeze the columns below it.
            .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: PadLayout.gutter) {
                levelCard
                HStack(spacing: 12) { statTiles }
            }
        }
    }

    private var levelCard: some View {
        Button {
            Haptics.shared.tick()
            showLevelSheet = true
        } label: {
            let info = levelInfo
            HStack(spacing: 20) {
                LevelSealBadge(level: info.level, size: 88)

                VStack(alignment: .leading, spacing: 8) {
                    Text(XPEngine.rankTitle(for: info.level).uppercased())
                        .font(.title3.weight(.black))
                        .kerning(2)
                        .foregroundStyle(Theme.limitBreakGradient)

                    XPProgressBar(progress: info.progress)

                    Text("\(info.xpIntoLevel.formatted()) / \(info.xpForNext.formatted()) XP to LV \(info.level + 1)")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textDim)
                }

                Image(systemName: "chevron.right")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.textDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Theme.glassBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            .contentShape(RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statTiles: some View {
        let progress = xpProgress
        let steps = HealthKitManager.shared.todaySteps
        let hitGoal = (steps ?? 0) >= Double(StepGoals.dailyGoal)
        let limitBreaks = sessions.reduce(0) { $0 + $1.prCount }

        Group {
            PadStatTile(
                icon: "flame.fill",
                value: "\(progress.currentStreak)",
                label: "Day Streak",
                tint: Theme.emerald
            ) {
                selectedStat = PadStatDetail(
                    icon: "flame.fill", tint: Theme.emerald, title: "Day Streak",
                    value: "\(progress.currentStreak) day\(progress.currentStreak == 1 ? "" : "s")",
                    detail: "Consecutive days you've stayed active — a finished session, a sport, or a walk of at least a mile keeps it alive. Every full 7-day run adds a +1\u{00D7} multiplier to all the XP you earn."
                )
            }
            .overlay(alignment: .topTrailing) {
                if progress.currentMultiplier > 1 {
                    PadMultiplierSeal(multiplier: progress.currentMultiplier)
                        .offset(x: 10, y: -10)
                }
            }

            PadStatTile(
                icon: "shoeprints.fill",
                value: steps.map { StepFormat.compact($0) } ?? "\u{2014}",
                label: "Steps Today",
                tint: hitGoal ? Theme.emerald : Theme.teal
            ) {
                selectedStat = PadStatDetail(
                    icon: "shoeprints.fill", tint: hitGoal ? Theme.emerald : Theme.teal,
                    title: "Steps Today",
                    value: steps.map { Int($0).formatted() } ?? "\u{2014}",
                    detail: stepsDetail(steps: steps, hitGoal: hitGoal)
                )
            }

            PadStatTile(
                icon: "crown.fill",
                value: "\(limitBreaks)",
                label: "LimitBreaks",
                tint: Theme.gold
            ) {
                selectedStat = PadStatDetail(
                    icon: "crown.fill", tint: Theme.gold, title: "LimitBreaks",
                    value: "\(limitBreaks)",
                    detail: "Personal records you've shattered. Every time you beat a previous best on a lift, that's a LimitBreak — worth +\(XPEngine.limitBreakXP) XP each."
                )
            }

            PadStatTile(
                icon: "scalemass.fill",
                value: Int(weeklyVolume).formatted(.number.notation(.compactName)),
                label: "Week Volume",
                tint: Theme.violet
            ) {
                selectedStat = PadStatDetail(
                    icon: "scalemass.fill", tint: Theme.violet, title: "Week Volume",
                    value: "\(Int(weeklyVolume).formatted()) lbs",
                    detail: "Everything you've moved in the last seven days — every working set's weight multiplied by its reps, added up."
                )
            }
        }
    }

    private func stepsDetail(steps: Double?, hitGoal: Bool) -> String {
        let base = "Steps counted by Apple Health today. Reach \(StepGoals.dailyGoal.formatted()) to bank +\(StepGoals.bonusXP) XP and a little fanfare."
        guard let steps else {
            return base + " Connect Apple Health from the heart icon to start tracking."
        }
        if hitGoal { return base + " Goal smashed — nice work." }
        return base + " You're \(max(0, StepGoals.dailyGoal - Int(steps)).formatted()) steps away."
    }

    // MARK: - Analytics column

    private var analyticsStack: some View {
        VStack(spacing: PadLayout.gutter) {
            StatDialsView(sessions: sessions)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: PadLayout.gutter) {
                    BodyDiagramView(sessions: sessions)
                        .frame(minWidth: 320)
                    ProgressChartView(sessions: sessions)
                        .frame(minWidth: 380)
                }
                VStack(spacing: PadLayout.gutter) {
                    BodyDiagramView(sessions: sessions)
                    ProgressChartView(sessions: sessions)
                }
            }

            activityNodesPanel
        }
    }

    /// Half a year of activity nodes, laid out flat — no horizontal scroll to
    /// hunt through, which is the whole point of the extra width.
    private var activityNodesPanel: some View {
        PadPanel("ACTIVITY NODES \u{2014} \(weeksShown) WEEKS") {
            VStack(alignment: .leading, spacing: 14) {
                PadActivityGrid(weeksShown: weeksShown, statsByDay: statsByDay) { day in
                    selectedDay = day
                }

                HStack(spacing: 18) {
                    legendDot(color: Theme.cobalt.opacity(0.35), label: "Dormant")
                    legendDot(color: Theme.emerald, label: "Active")
                    legendDot(color: Theme.coral, label: "Sport")
                    legendDot(color: Theme.teal, label: "Walk")
                    legendDot(color: Theme.gold, label: "LimitBreak")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(Theme.textDim)
            }
        }
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 11, height: 11)
            Text(label)
        }
    }

    // MARK: - Feed column

    private var feedStack: some View {
        VStack(spacing: PadLayout.gutter) {
            rewardsPanel
            masteryPanel
            battleLogPanel
        }
    }

    @ViewBuilder
    private var rewardsPanel: some View {
        let rewards = XPEngine.recentRewards(
            sessions: sessions, records: records, walks: walks,
            activities: activities, routines: routines,
            stepGoalDays: StepGoalStore.achievedDays(),
            multipliers: xpProgress.multipliers,
            limit: 8
        )
        if !rewards.isEmpty {
            PadPanel("RECENT REWARDS") {
                VStack(spacing: 10) {
                    ForEach(rewards) { reward in
                        HStack(spacing: 12) {
                            Image(systemName: reward.icon)
                                .font(.subheadline)
                                .foregroundStyle(reward.tint)
                                .frame(width: 34, height: 34)
                                .background(reward.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(reward.title)
                                    .font(.subheadline.weight(.bold))
                                Text(reward.detail)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textDim)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 4)

                            Text("+\(reward.xp) XP")
                                .font(.subheadline.weight(.black))
                                .monospacedDigit()
                                .foregroundStyle(reward.tint)
                        }
                    }
                }
            } accessory: {
                NavigationLink { RewardsTimelineView() } label: {
                    HStack(spacing: 3) {
                        Text("Timeline")
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.emerald)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var masteryPanel: some View {
        let ranks = Mastery.routineRanks(in: sessions, routines: routines)
            + Mastery.exerciseRanks(in: sessions)
        let top = Array(ranks.sorted(by: masteryDisplayOrder).prefix(5))
        if !top.isEmpty {
            PadPanel("WORKOUT MASTERY") {
                VStack(spacing: 12) {
                    ForEach(top) { rank in
                        MasteryRankRow(rank: rank)
                    }
                }
            } accessory: {
                NavigationLink { MasteryView() } label: {
                    HStack(spacing: 3) {
                        Text("Skill tree")
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.violet)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var battleLogPanel: some View {
        PadPanel("BATTLE LOG") {
            if sessions.isEmpty {
                Text("No sessions yet. Head to Train to begin your first quest.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 10) {
                    ForEach(sessions.prefix(12)) { session in
                        Button {
                            Haptics.shared.tick()
                            selectedDay = Calendar.current.startOfDay(for: session.startDate)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.name)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                    Text(session.startDate.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(Theme.textDim)
                                }
                                Spacer(minLength: 6)
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(Int(session.totalVolume).formatted()) lbs")
                                        .font(.subheadline.weight(.semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(Theme.emerald)
                                    if session.prCount > 0 {
                                        Text("\(session.prCount) LimitBreak\(session.prCount == 1 ? "" : "s")")
                                            .font(.caption)
                                            .foregroundStyle(Theme.gold)
                                    } else {
                                        Text(session.duration.clockString)
                                            .font(.caption)
                                            .foregroundStyle(Theme.textDim)
                                    }
                                }
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 12)
                            .glassControl(cornerRadius: 14)
                            .contentShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func masteryDisplayOrder(_ a: Mastery.Rank, _ b: Mastery.Rank) -> Bool {
        if a.level != b.level { return a.level > b.level }
        if a.completions != b.completions { return a.completions > b.completions }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    // MARK: - Derived data

    private var xpProgress: XPEngine.Progress {
        XPEngine.progress(
            sessions: sessions, records: records, walks: walks,
            activities: activities, routines: routines,
            stepGoalDays: StepGoalStore.achievedDays()
        )
    }

    private var levelInfo: XPEngine.LevelInfo {
        XPEngine.levelInfo(totalXP: xpProgress.totalXP)
    }

    private var weeklyVolume: Double {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        return sessions.filter { $0.startDate >= weekAgo }.reduce(0) { $0 + $1.totalVolume }
    }

    private var statsByDay: [Date: PadDayStats] {
        let calendar = Calendar.current
        var result: [Date: PadDayStats] = [:]
        for session in sessions {
            let day = calendar.startOfDay(for: session.startDate)
            var stats = result[day] ?? PadDayStats()
            stats.prCount += session.prCount
            stats.sessionCount += 1
            result[day] = stats
        }
        for walk in walks where walk.distanceMiles >= XPEngine.streakWalkMinimumMiles {
            let day = calendar.startOfDay(for: walk.date)
            var stats = result[day] ?? PadDayStats()
            stats.walkCount += 1
            result[day] = stats
        }
        for activity in activities {
            let day = calendar.startOfDay(for: activity.date)
            var stats = result[day] ?? PadDayStats()
            stats.activityCount += 1
            result[day] = stats
        }
        return result
    }
}

// MARK: - Activity grid

/// What happened on one day, reduced to the flags the node grid colors by.
struct PadDayStats {
    var prCount: Int = 0
    var sessionCount: Int = 0
    var walkCount: Int = 0
    var activityCount: Int = 0
}

/// The contribution-style node grid, sized for a screen that can show the whole
/// span at once — week columns run left to right, oldest to newest.
private struct PadActivityGrid: View {
    let weeksShown: Int
    let statsByDay: [Date: PadDayStats]
    let onSelect: (Date) -> Void

    private var calendar: Calendar { Calendar.current }

    private var gridStart: Date {
        let today = calendar.startOfDay(for: Date())
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)!.start
        return calendar.date(byAdding: .weekOfYear, value: -(weeksShown - 1), to: weekStart)!
    }

    /// Month labels above the first week column that falls in each month.
    private var monthLabels: [Int: String] {
        var labels: [Int: String] = [:]
        var seen: Set<Int> = []
        for week in 0..<weeksShown {
            guard let day = calendar.date(byAdding: .weekOfYear, value: week, to: gridStart) else { continue }
            let month = calendar.component(.month, from: day)
            if !seen.contains(month) {
                seen.insert(month)
                labels[week] = day.formatted(.dateTime.month(.abbreviated))
            }
        }
        return labels
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(0..<weeksShown, id: \.self) { week in
                    Text(monthLabels[week] ?? "")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textDim)
                        .frame(width: 18, alignment: .leading)
                        .fixedSize()
                        .frame(width: 18, alignment: .leading)
                        .clipped()
                }
            }

            HStack(alignment: .top, spacing: 5) {
                ForEach(0..<weeksShown, id: \.self) { week in
                    VStack(spacing: 5) {
                        ForEach(0..<7, id: \.self) { dayOfWeek in
                            let day = calendar.date(byAdding: .day, value: week * 7 + dayOfWeek, to: gridStart)!
                            node(for: day)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func node(for day: Date) -> some View {
        let stats = statsByDay[day]
        let isFuture = day > Date()
        let state: PadNodeState = if isFuture {
            .future
        } else if let stats {
            if stats.prCount > 0 { .limitBreak }
            else if stats.sessionCount > 0 { .active }
            else if stats.activityCount > 0 { .activity }
            else { .walk }
        } else {
            .dormant
        }

        RoundedRectangle(cornerRadius: 5)
            .fill(state.fill)
            .frame(width: 18, height: 18)
            .overlay {
                if let stroke = state.stroke {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(stroke, lineWidth: 1)
                }
            }
            .onTapGesture {
                guard stats != nil else { return }
                Haptics.shared.tick()
                onSelect(day)
            }
            .help(day.formatted(date: .abbreviated, time: .omitted))
    }
}

private enum PadNodeState {
    case future, dormant, active, activity, walk, limitBreak

    var fill: Color {
        switch self {
        case .future: .clear
        case .dormant: Theme.cobalt.opacity(0.22)
        case .active: Theme.emerald.opacity(0.85)
        case .activity: Theme.coral.opacity(0.75)
        case .walk: Theme.teal.opacity(0.75)
        case .limitBreak: Theme.gold.opacity(0.8)
        }
    }

    var stroke: Color? {
        switch self {
        case .active: Theme.emerald.opacity(0.6)
        case .activity: Theme.coral.opacity(0.6)
        case .walk: Theme.teal.opacity(0.6)
        case .limitBreak: Theme.gold
        default: nil
        }
    }
}

// MARK: - Stat detail

/// The explanation behind a headline number on the dashboard.
struct PadStatDetail: Identifiable {
    let id = UUID()
    let icon: String
    let tint: Color
    let title: String
    let value: String
    let detail: String
}

private struct PadStatDetailSheet: View {
    let detail: PadStatDetail

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(detail.tint.opacity(0.18)).frame(width: 80, height: 80)
                Image(systemName: detail.icon)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(detail.tint)
            }
            .padding(.top, 34)

            VStack(spacing: 6) {
                Text(detail.value)
                    .font(.system(size: 42, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(detail.title.uppercased())
                    .font(.caption.weight(.bold))
                    .kerning(1.5)
                    .foregroundStyle(Theme.textDim)
            }

            Text(detail.detail)
                .font(.subheadline)
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .obsidianBackground()
        .presentationDetents([.height(380)])
        .presentationDragIndicator(.visible)
    }
}

/// The gold multiplier seal that clings to the streak tile.
private struct PadMultiplierSeal: View {
    let multiplier: Int

    @State private var pulsing = false

    var body: some View {
        Image(systemName: "seal.fill")
            .font(.system(size: 32))
            .foregroundStyle(Theme.gold)
            .shadow(color: Theme.gold.opacity(pulsing ? 0.85 : 0.35), radius: pulsing ? 6 : 2)
            .overlay(
                Text("\u{00D7}\(multiplier)")
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.background)
            )
            .rotationEffect(.degrees(pulsing ? 8 : -8))
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
            .accessibilityLabel("\(multiplier) times XP multiplier")
    }
}
