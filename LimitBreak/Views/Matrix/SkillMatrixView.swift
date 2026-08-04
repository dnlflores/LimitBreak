import SwiftUI
import SwiftData

/// The Skill Matrix: LimitBreak's progress dashboard. Power dials, a body
/// status diagram, an 8-week output chart, and the activity-node grid — all
/// interactive, all backed by the same session log.
struct SkillMatrixView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var sessions: [WorkoutSession]
    @Query(sort: \Walk.date, order: .reverse) private var walks: [Walk]
    @Query(sort: \PRRecord.dateAchieved, order: .reverse) private var records: [PRRecord]
    @Query(sort: \Activity.date, order: .reverse) private var activities: [Activity]
    @Query private var routines: [Routine]

    @State private var selectedDay: Date?
    @State private var selectedStat: StatInfo?
    @State private var showHealthSheet = false
    @State private var showSettings = false
    // Debug/UI-test hook: launch with "-open-timeline" to push the timeline.
    @State private var showTimeline = ProcessInfo.processInfo.arguments.contains("-open-timeline")
    // Debug/UI-test hook: launch with "-open-level" to present the hero sheet.
    @State private var showLevelSheet = ProcessInfo.processInfo.arguments.contains("-open-level")

    private let weeksShown = 22

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    titleHeader
                    levelCard
                    statHeader
                    rewardsSection
                    masterySection
                    StatDialsView(sessions: sessions)
                    BodyDiagramView(sessions: sessions)
                    ProgressChartView(sessions: sessions)
                    matrixCard
                    recentSessions
                }
                .padding()
            }
            .obsidianBackground()
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $selectedDay) { day in
                DayDetailSheet(day: day)
            }
            .sheet(isPresented: $showHealthSheet) {
                HealthKitSheet()
            }
            .navigationDestination(isPresented: $showTimeline) {
                RewardsTimelineView()
            }
            .sheet(isPresented: $showLevelSheet) {
                LevelDetailSheet(info: levelInfo)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(item: $selectedStat) { info in
                StatInfoSheet(info: info)
            }
            .task {
                // Keep today's step tile live whenever the Level tab appears.
                await HealthKitManager.shared.refreshTodayStats()
            }
        }
    }

    // MARK: - Day aggregation

    fileprivate struct DayStats {
        var volume: Double = 0
        var prCount: Int = 0
        var duration: TimeInterval = 0
        var sessionCount: Int = 0
        var walkCount: Int = 0
        var activityCount: Int = 0
    }

    private var statsByDay: [Date: DayStats] {
        let calendar = Calendar.current
        var result: [Date: DayStats] = [:]
        for session in sessions {
            let day = calendar.startOfDay(for: session.startDate)
            var stats = result[day] ?? DayStats()
            stats.volume += session.totalVolume
            stats.prCount += session.prCount
            stats.duration += session.duration
            stats.sessionCount += 1
            result[day] = stats
        }
        // Only walks that sustain the streak (≥ 1 mile) light a node, so the
        // grid agrees with the streak count. Sub-mile walks still earn XP, they
        // just don't mark a trained day.
        for walk in walks where walk.distanceMiles >= XPEngine.streakWalkMinimumMiles {
            let day = calendar.startOfDay(for: walk.date)
            var stats = result[day] ?? DayStats()
            stats.walkCount += 1
            result[day] = stats
        }
        // Cross-training lights a node too — a basketball night is a trained day,
        // and it already sustains the streak, so the grid must agree.
        for activity in activities {
            let day = calendar.startOfDay(for: activity.date)
            var stats = result[day] ?? DayStats()
            stats.activityCount += 1
            stats.duration += TimeInterval(activity.durationMinutes * 60)
            result[day] = stats
        }
        return result
    }

    // MARK: - Header stats

    private var weeklyVolume: Double {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        return sessions.filter { $0.startDate >= weekAgo }.reduce(0) { $0 + $1.totalVolume }
    }

    private var titleHeader: some View {
        HStack(alignment: .center) {
            Text("Level Up")
                .font(.largeTitle.bold())
            Spacer()
            Button {
                showHealthSheet = true
            } label: {
                Image(systemName: HealthKitManager.shared.isConnected ? "heart.fill" : "heart")
                    .font(.title2)
                    .foregroundStyle(Theme.crimson)
                    .glassCircle()
            }
            .buttonStyle(.plain)

            Button {
                Haptics.shared.tick()
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.textDim)
                    .glassCircle()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .padding(.bottom, 8)
    }

    private var statHeader: some View {
        let progress = xpProgress
        let steps = HealthKitManager.shared.todaySteps
        let hitGoal = (steps ?? 0) >= Double(StepGoals.dailyGoal)
        let limitBreaks = sessions.reduce(0) { $0 + $1.prCount }
        return HStack(spacing: 12) {
            statButton(
                StatInfo(
                    icon: "flame.fill", tint: Theme.emerald, title: "Day Streak",
                    value: "\(progress.currentStreak) day\(progress.currentStreak == 1 ? "" : "s")",
                    detail: "Consecutive days you've stayed active — a finished session, a sport, or a walk of at least a mile keeps it alive. Every full 7-day run adds a +1× multiplier to all the XP you earn."
                ),
                value: "\(progress.currentStreak)", label: "Day Streak", color: Theme.emerald
            )
            .overlay(alignment: .topTrailing) {
                if progress.currentMultiplier > 1 {
                    MultiplierBadge(multiplier: progress.currentMultiplier)
                        .offset(x: 9, y: -9)
                }
            }
            statButton(
                StatInfo(
                    icon: "shoeprints.fill", tint: hitGoal ? Theme.emerald : Theme.teal, title: "Steps Today",
                    value: steps.map { Int($0).formatted() } ?? "—",
                    detail: stepsDetail(steps: steps, hitGoal: hitGoal)
                ),
                value: steps.map { StepFormat.compact($0) } ?? "—",
                label: "of 10k steps", color: hitGoal ? Theme.emerald : Theme.teal
            )
            statButton(
                StatInfo(
                    icon: "crown.fill", tint: Theme.gold, title: "LimitBreaks",
                    value: "\(limitBreaks)",
                    detail: "Personal records you've shattered. Every time you beat a previous best on a lift, that's a LimitBreak — worth +\(XPEngine.limitBreakXP) XP each."
                ),
                value: "\(limitBreaks)", label: "LimitBreaks", color: Theme.gold
            )
        }
    }

    /// A tappable header stat: shows the tile, opens its info card on tap.
    private func statButton(_ info: StatInfo, value: String, label: String, color: Color) -> some View {
        Button {
            Haptics.shared.tick()
            selectedStat = info
        } label: {
            statTile(value: value, label: label, color: color)
        }
        .buttonStyle(.plain)
    }

    private func stepsDetail(steps: Double?, hitGoal: Bool) -> String {
        let base = "Steps counted by Apple Health today. Reach \(StepGoals.dailyGoal.formatted()) to bank +\(StepGoals.bonusXP) XP and a little fanfare."
        guard let steps else {
            return base + " Connect Apple Health from the heart icon to start tracking."
        }
        if hitGoal {
            return base + " Goal smashed — nice work."
        }
        let remaining = max(0, StepGoals.dailyGoal - Int(steps))
        return base + " You're \(remaining.formatted()) steps away."
    }

    // MARK: - Level & rewards

    private var xpProgress: XPEngine.Progress {
        XPEngine.progress(sessions: sessions, records: records, walks: walks, activities: activities, routines: routines, stepGoalDays: StepGoalStore.achievedDays())
    }

    private var levelInfo: XPEngine.LevelInfo {
        XPEngine.levelInfo(totalXP: xpProgress.totalXP)
    }

    /// The character sheet teaser: level seal, rank title, and one XP bar.
    /// Tap for the full hero stats.
    private var levelCard: some View {
        let info = levelInfo

        return Button {
            Haptics.shared.tick()
            showLevelSheet = true
        } label: {
            HStack(spacing: 16) {
                LevelSealBadge(level: info.level, size: 68)

                VStack(alignment: .leading, spacing: 6) {
                    Text(XPEngine.rankTitle(for: info.level).uppercased())
                        .font(.subheadline.weight(.black))
                        .kerning(1.5)
                        .foregroundStyle(Theme.limitBreakGradient)

                    XPProgressBar(progress: info.progress)

                    Text("\(info.xpIntoLevel.formatted()) / \(info.xpForNext.formatted()) XP to LV \(info.level + 1)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textDim)
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textDim)
            }
            .cardStyle()
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }

    /// The latest loot: LimitBreaks, finished quests, and side quests with
    /// the XP each one paid out.
    @ViewBuilder
    private var rewardsSection: some View {
        let rewards = XPEngine.recentRewards(
            sessions: sessions, records: records, walks: walks, activities: activities, routines: routines,
            stepGoalDays: StepGoalStore.achievedDays(),
            multipliers: xpProgress.multipliers
        )
        if !rewards.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("RECENT REWARDS")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textDim)
                        .kerning(1.5)
                    Spacer()
                    NavigationLink {
                        RewardsTimelineView()
                    } label: {
                        HStack(spacing: 3) {
                            Text("Timeline")
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.emerald)
                    }
                    .buttonStyle(.plain)
                }

                VStack(spacing: 6) {
                    ForEach(rewards) { reward in
                        HStack(spacing: 10) {
                            Image(systemName: reward.icon)
                                .font(.caption)
                                .foregroundStyle(reward.tint)
                                .frame(width: 28, height: 28)
                                .background(reward.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                            VStack(alignment: .leading, spacing: 1) {
                                Text(reward.title)
                                    .font(.caption.weight(.bold))
                                Text(reward.detail)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textDim)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Text("+\(reward.xp) XP")
                                .font(.caption.weight(.black))
                                .monospacedDigit()
                                .foregroundStyle(reward.tint)
                        }
                    }
                }
                .cardStyle()
            }
        }
    }

    /// Workout mastery: the exercises and routines ground the deepest, each with
    /// its rank and a bar toward the next. Tap through for the full skill tree.
    @ViewBuilder
    private var masterySection: some View {
        let ranks = Mastery.routineRanks(in: sessions, routines: routines)
            + Mastery.exerciseRanks(in: sessions)
        let top = Array(ranks.sorted(by: masteryDisplayOrder).prefix(3))
        if !top.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("WORKOUT MASTERY")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textDim)
                        .kerning(1.5)
                    Spacer()
                    NavigationLink {
                        MasteryView()
                    } label: {
                        HStack(spacing: 3) {
                            Text("Skill tree")
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.violet)
                    }
                    .buttonStyle(.plain)
                }

                VStack(spacing: 10) {
                    ForEach(top) { rank in
                        MasteryRankRow(rank: rank)
                    }
                }
                .cardStyle()
            }
        }
    }

    /// Deepest rank first, then most completions, then name.
    private func masteryDisplayOrder(_ a: Mastery.Rank, _ b: Mastery.Rank) -> Bool {
        if a.level != b.level { return a.level > b.level }
        if a.completions != b.completions { return a.completions > b.completions }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    private func statTile(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .statNumberStyle()
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    // MARK: - The grid

    private var matrixCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ACTIVITY NODES")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textDim)
                .kerning(1.5)

            ScrollView(.horizontal, showsIndicators: false) {
                MatrixGrid(weeksShown: weeksShown, statsByDay: statsByDay) { day in
                    selectedDay = day
                }
                .scaleEffect(x: -1)
            }
            .scaleEffect(x: -1) // right-anchored: most recent week visible first

            HStack(spacing: 14) {
                legendDot(color: Theme.cobalt.opacity(0.35), label: "Dormant")
                legendDot(color: Theme.emerald, label: "Active")
                legendDot(color: Theme.coral, label: "Sport")
                legendDot(color: Theme.teal, label: "Walk")
                legendDot(color: Theme.gold, label: "LimitBreak")
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(Theme.textDim)
        }
        .cardStyle()
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
        }
    }

    // MARK: - Recent sessions

    private var recentSessions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("BATTLE LOG")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textDim)
                .kerning(1.5)

            if sessions.isEmpty {
                Text("No sessions yet. Head to Train to begin your first quest.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .cardStyle()
            }

            ForEach(sessions.prefix(10)) { session in
                Button {
                    Haptics.shared.tick()
                    selectedDay = Calendar.current.startOfDay(for: session.startDate)
                } label: {
                    sessionRow(session)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func sessionRow(_ session: WorkoutSession) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.name)
                    .font(.subheadline.weight(.semibold))
                Text(session.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
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
        .cardStyle()
    }
}

/// Lets Date drive `.sheet(item:)` for the day-detail presentation.
extension Date: @retroactive Identifiable {
    public var id: TimeInterval { timeIntervalSince1970 }
}

// MARK: - Stat info card

/// The content behind a header stat tile — its icon, current value, and a plain
/// explanation of what the number means and how to move it.
struct StatInfo: Identifiable {
    let id = UUID()
    let icon: String
    let tint: Color
    let title: String
    let value: String
    let detail: String
}

/// A compact modal that explains a tapped header stat.
private struct StatInfoSheet: View {
    let info: StatInfo

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(info.tint.opacity(0.18))
                    .frame(width: 72, height: 72)
                Image(systemName: info.icon)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(info.tint)
            }
            .padding(.top, 32)

            VStack(spacing: 6) {
                Text(info.value)
                    .font(.system(size: 38, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(info.title.uppercased())
                    .font(.caption.weight(.bold))
                    .kerning(1.5)
                    .foregroundStyle(Theme.textDim)
            }

            Text(info.detail)
                .font(.subheadline)
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .obsidianBackground()
        .presentationDetents([.height(340)])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Grid component

private struct MatrixGrid: View {
    let weeksShown: Int
    let statsByDay: [Date: SkillMatrixView.DayStats]
    let onSelect: (Date) -> Void

    private var calendar: Calendar { Calendar.current }

    /// Start of the week `weeksShown - 1` weeks ago.
    private var gridStart: Date {
        let today = calendar.startOfDay(for: Date())
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)!.start
        return calendar.date(byAdding: .weekOfYear, value: -(weeksShown - 1), to: weekStart)!
    }

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            ForEach(0..<weeksShown, id: \.self) { week in
                VStack(spacing: 5) {
                    ForEach(0..<7, id: \.self) { dayOfWeek in
                        let day = calendar.date(byAdding: .day, value: week * 7 + dayOfWeek, to: gridStart)!
                        nodeView(for: day)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func nodeView(for day: Date) -> some View {
        let stats = statsByDay[day]
        let isFuture = day > Date()
        // Most notable thing that happened that day wins the node's colour:
        // a record, then a lift, then a sport, then a walk.
        let state: MatrixNode.NodeState = if isFuture {
            .future
        } else if let stats {
            if stats.prCount > 0 {
                .limitBreak
            } else if stats.sessionCount > 0 {
                .active
            } else if stats.activityCount > 0 {
                .activity
            } else {
                .walk
            }
        } else {
            .dormant
        }

        MatrixNode(state: state)
            .onTapGesture {
                guard stats != nil else { return }
                Haptics.shared.tick()
                onSelect(day)
            }
    }
}

private struct MatrixNode: View {
    enum NodeState { case future, dormant, active, activity, walk, limitBreak }
    let state: NodeState

    @State private var pulsing = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(fillColor)
                .frame(width: 16, height: 16)

            if state == .limitBreak {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Theme.limitBreakGradient, lineWidth: 1.5)
                    .frame(width: 16, height: 16)
                    .shadow(color: Theme.gold.opacity(pulsing ? 0.9 : 0.3), radius: pulsing ? 5 : 1)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                            pulsing = true
                        }
                    }
            } else if state == .active {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Theme.emerald.opacity(0.6), lineWidth: 1)
                    .frame(width: 16, height: 16)
            } else if state == .activity {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Theme.coral.opacity(0.6), lineWidth: 1)
                    .frame(width: 16, height: 16)
            } else if state == .walk {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Theme.teal.opacity(0.6), lineWidth: 1)
                    .frame(width: 16, height: 16)
            }
        }
    }

    private var fillColor: Color {
        switch state {
        case .future: .clear
        case .dormant: Theme.cobalt.opacity(0.22)
        case .active: Theme.emerald.opacity(0.85)
        case .activity: Theme.coral.opacity(0.75)
        case .walk: Theme.teal.opacity(0.75)
        case .limitBreak: Theme.gold.opacity(0.75)
        }
    }
}

// MARK: - Multiplier badge

/// A tiny gold seal that clings to the corner of the streak tile, calling out
/// the active XP multiplier. A scalloped "squiggle" badge with a slow breathing
/// glow so a hot streak feels like earned loot.
private struct MultiplierBadge: View {
    let multiplier: Int

    @State private var pulsing = false

    var body: some View {
        Image(systemName: "seal.fill")
            .font(.system(size: 30))
            .foregroundStyle(Theme.gold)
            .shadow(color: Theme.gold.opacity(pulsing ? 0.85 : 0.35), radius: pulsing ? 6 : 2)
            .overlay(
                Text("\u{00D7}\(multiplier)")
                    .font(.system(size: 12, weight: .black, design: .rounded))
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
