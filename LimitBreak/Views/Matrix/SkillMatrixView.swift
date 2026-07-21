import SwiftUI
import SwiftData

/// The Skill Matrix: LimitBreak's progress dashboard. Power dials, a body
/// status diagram, an 8-week output chart, and the activity-node grid — all
/// interactive, all backed by the same session log.
struct SkillMatrixView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var sessions: [WorkoutSession]
    @Query(sort: \Walk.date, order: .reverse) private var walks: [Walk]

    @State private var selectedDay: Date?
    @State private var showHealthSheet = false

    private let weeksShown = 22

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    titleHeader
                    statHeader
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
        }
    }

    // MARK: - Day aggregation

    fileprivate struct DayStats {
        var volume: Double = 0
        var prCount: Int = 0
        var duration: TimeInterval = 0
        var sessionCount: Int = 0
        var walkCount: Int = 0
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
        for walk in walks {
            let day = calendar.startOfDay(for: walk.date)
            var stats = result[day] ?? DayStats()
            stats.walkCount += 1
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
            Text("Skill Matrix")
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
        }
        .padding(.bottom, 8)
    }

    private var statHeader: some View {
        HStack(spacing: 12) {
            statTile(
                value: "\(NarrativeEngine.currentStreak(context: modelContext))",
                label: "Day Streak",
                color: Theme.emerald
            )
            statTile(
                value: Int(weeklyVolume).formatted(.number.notation(.compactName)),
                label: "Weekly lbs",
                color: Theme.violet
            )
            statTile(
                value: "\(sessions.reduce(0) { $0 + $1.prCount })",
                label: "LimitBreaks",
                color: Theme.gold
            )
        }
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
        let state: MatrixNode.NodeState = if isFuture {
            .future
        } else if let stats {
            if stats.prCount > 0 {
                .limitBreak
            } else if stats.sessionCount > 0 {
                .active
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
    enum NodeState { case future, dormant, active, walk, limitBreak }
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
        case .walk: Theme.teal.opacity(0.75)
        case .limitBreak: Theme.gold.opacity(0.75)
        }
    }
}
