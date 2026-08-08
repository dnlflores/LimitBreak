import SwiftUI
import WidgetKit

// MARK: - Shared timeline plumbing

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

/// Widgets are ambient: the app pushes fresh data and reloads timelines, so a
/// single entry with a lazy refresh window is all that's needed.
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: WidgetSnapshotStore.load() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: Date(), snapshot: WidgetSnapshotStore.load() ?? .placeholder)
        let refresh = Calendar.current.date(byAdding: .hour, value: 6, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }
}

// MARK: - Skill Matrix widget

/// The activity-node grid, straight from the app's Matrix tab.
struct SkillMatrixWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SkillMatrixWidget", provider: SnapshotProvider()) { entry in
            SkillMatrixWidgetView(snapshot: entry.snapshot)
                .containerBackground(LBColor.background, for: .widget)
        }
        .configurationDisplayName("Skill Matrix")
        .description("Your activity nodes — every session lights one, every LimitBreak turns it gold.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct SkillMatrixWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot

    private var weeksShown: Int { family == .systemSmall ? 7 : 16 }
    private var isLarge: Bool { family == .systemLarge }

    var body: some View {
        VStack(alignment: .leading, spacing: isLarge ? 12 : 8) {
            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                    .font(.caption2)
                    .foregroundStyle(LBColor.gold)
                Text("\(snapshot.streakDays) day streak")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                if family != .systemSmall {
                    Text("\(Int(snapshot.weeklyVolume).formatted(.number.notation(.compactName))) lbs this week")
                        .font(.caption2)
                        .foregroundStyle(LBColor.dim)
                }
            }

            ActivityMatrix(levels: Array(snapshot.dayActivity.suffix(weeksShown * 7)))

            if isLarge {
                RecordStrip(records: snapshot.topRecords, totalLimitBreaks: snapshot.totalLimitBreaks)
            }
        }
    }
}

// MARK: - Record Board widget

/// Top ceilings, crowned in gold.
struct RecordBoardWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RecordBoardWidget", provider: SnapshotProvider()) { entry in
            RecordBoardWidgetView(snapshot: entry.snapshot)
                .containerBackground(LBColor.background, for: .widget)
        }
        .configurationDisplayName("Record Board")
        .description("Your heaviest ceilings — the numbers every LimitBreak is chasing.")
        .supportedFamilies([.systemMedium])
    }
}

struct RecordBoardWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "crown.fill")
                    .font(.caption)
                    .foregroundStyle(LBColor.gold)
                Text("RECORD BOARD")
                    .font(.caption2.weight(.bold))
                    .kerning(1.2)
                    .foregroundStyle(LBColor.dim)
                Spacer()
                Text("\(snapshot.totalLimitBreaks) LimitBreaks")
                    .font(.caption2)
                    .foregroundStyle(LBColor.violet)
            }

            if snapshot.topRecords.isEmpty {
                Spacer()
                Text("No records yet — log a session and shatter your first ceiling.")
                    .font(.caption)
                    .foregroundStyle(LBColor.dim)
                Spacer()
            } else {
                ForEach(Array(snapshot.topRecords.enumerated()), id: \.element.id) { index, record in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption2.weight(.black))
                            .foregroundStyle(index == 0 ? LBColor.gold : LBColor.dim)
                            .frame(width: 14)
                        Text(record.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer()
                        Text("\(Int(record.value)) \(record.unit)")
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(LBColor.gold)
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(
                        Color.white.opacity(index == 0 ? 0.07 : 0.03),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }
            }
        }
    }
}

// MARK: - Streak widget (home + lock screen)

struct StreakWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "StreakWidget", provider: SnapshotProvider()) { entry in
            StreakWidgetView(snapshot: entry.snapshot)
                .containerBackground(LBColor.background, for: .widget)
        }
        .configurationDisplayName("Streak")
        .description("Your level, today's steps, and day streak, at a glance.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

struct StreakWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot

    var body: some View {
        switch family {
        case .accessoryCircular:
            VStack(spacing: 0) {
                Image(systemName: "flame.fill")
                    .font(.caption2)
                Text("\(snapshot.streakDays)")
                    .font(.system(.title3, design: .rounded, weight: .black))
                    .monospacedDigit()
            }

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("LV \(snapshot.level) \(snapshot.rankTitle)")
                    .font(.headline)
                Text("\(Int(snapshot.todaySteps).formatted()) / \(snapshot.stepGoal.formatted(.number.notation(.compactName))) steps")
                    .font(.caption2)
                Label("\(snapshot.streakDays) day streak", systemImage: "flame.fill")
                    .font(.caption2)
            }

        default:
            let hitGoal = snapshot.todaySteps >= Double(snapshot.stepGoal)
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "flame.fill")
                    .font(.title3)
                    .foregroundStyle(LBColor.limitBreakGradient)

                Text("\(snapshot.streakDays)")
                    .font(.system(size: 40, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text("DAY STREAK")
                    .font(.caption2.weight(.bold))
                    .kerning(1.2)
                    .foregroundStyle(LBColor.dim)

                Spacer(minLength: 0)

                HStack(spacing: 4) {
                    Image(systemName: "shoeprints.fill")
                        .font(.caption2)
                        .foregroundStyle(hitGoal ? LBColor.emerald : LBColor.teal)
                    Text(StepFormat.compact(snapshot.todaySteps))
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(hitGoal ? LBColor.emerald : LBColor.teal)
                    Text("/ \(snapshot.stepGoal.formatted(.number.notation(.compactName))) steps")
                        .font(.caption2)
                        .foregroundStyle(LBColor.dim)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Steps widget (minimal)

/// The smallest possible widget: today's step count and nothing else.
struct StepsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "StepsWidget", provider: SnapshotProvider()) { entry in
            StepsWidgetView(snapshot: entry.snapshot)
                .containerBackground(LBColor.background, for: .widget)
        }
        .configurationDisplayName("Steps")
        .description("Today's step count — nothing else.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

struct StepsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot

    var body: some View {
        switch family {
        case .accessoryCircular:
            VStack(spacing: 0) {
                Image(systemName: "shoeprints.fill")
                    .font(.caption2)
                Text(StepFormat.compact(snapshot.todaySteps))
                    .font(.system(.headline, design: .rounded, weight: .black))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
            }

        default:
            VStack(spacing: 8) {
                Image(systemName: "shoeprints.fill")
                    .font(.title2)
                    .foregroundStyle(LBColor.teal)
                Text(StepFormat.compact(snapshot.todaySteps))
                    .font(.system(size: 40, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Training Dashboard widget (extra large)

/// The screen-filling board: a stat rail with the activity history and record
/// board side by side. No single panel is the star — it's everything the app
/// knows, at a glance.
struct DashboardWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DashboardWidget", provider: SnapshotProvider()) { entry in
            DashboardWidgetView(snapshot: entry.snapshot)
                .containerBackground(LBColor.background, for: .widget)
        }
        .configurationDisplayName("Training Dashboard")
        .description("A full board — your stats, activity history, and records, all in one place.")
        .supportedFamilies(Self.families)
    }

    /// iPhone's full-screen extra-large (`.systemExtraLargePortrait`) only exists
    /// on iOS 27; `.systemExtraLarge` is the iPad/macOS size.
    private static var families: [WidgetFamily] {
        var families: [WidgetFamily] = [.systemExtraLarge]
        if #available(iOS 27.0, *) { families.append(.systemExtraLargePortrait) }
        return families
    }
}

struct DashboardWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(spacing: 14) {
            StatRail(snapshot: snapshot)

            HStack(alignment: .top, spacing: 14) {
                DashboardCard {
                    MomentumChart(dayActivity: snapshot.dayActivity)
                }
                DashboardCard {
                    CeilingsPodium(records: snapshot.topRecords, totalLimitBreaks: snapshot.totalLimitBreaks)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Shared building blocks

/// The activity-node grid, columns are weeks (oldest → newest), rows are days.
struct ActivityMatrix: View {
    let levels: [Int]

    var body: some View {
        let columns = levels.chunked(into: 7)
        GeometryReader { geo in
            let spacing: CGFloat = 3
            let count = max(1, columns.count)
            let cell = min(
                (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count),
                (geo.size.height - spacing * 6) / 7
            )
            HStack(alignment: .top, spacing: spacing) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: spacing) {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, level in
                            RoundedRectangle(cornerRadius: cell / 4)
                                .fill(Self.color(for: level))
                                .frame(width: cell, height: cell)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    static func color(for level: Int) -> Color {
        switch level {
        case 2: LBColor.gold
        case 1: LBColor.emerald
        default: Color.white.opacity(0.08)
        }
    }
}

/// A compact horizontal list of top ceilings, used to fill the large widgets.
struct RecordStrip: View {
    let records: [WidgetSnapshot.TopRecord]
    let totalLimitBreaks: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "crown.fill")
                    .font(.caption2)
                    .foregroundStyle(LBColor.gold)
                Text("RECORD BOARD")
                    .font(.caption2.weight(.bold))
                    .kerning(1.2)
                    .foregroundStyle(LBColor.dim)
                Spacer()
                Text("\(totalLimitBreaks) LimitBreaks")
                    .font(.caption2)
                    .foregroundStyle(LBColor.violet)
            }

            if records.isEmpty {
                Text("No records yet — log a session and shatter your first ceiling.")
                    .font(.caption2)
                    .foregroundStyle(LBColor.dim)
            } else {
                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption2.weight(.black))
                            .foregroundStyle(index == 0 ? LBColor.gold : LBColor.dim)
                            .frame(width: 12)
                        Text(record.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(Int(record.value)) \(record.unit)")
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(LBColor.gold)
                    }
                }
            }
        }
    }
}

/// A gradient bar chart of weekly training — one bar per week, its height set by
/// how many days were trained, and tipped in the LimitBreak gradient on any week
/// that held a record. Reads as a momentum trend rather than a data grid.
struct MomentumChart: View {
    let dayActivity: [Int]

    /// The last 13 weeks as (days trained, broke a record that week).
    private var weeks: [(active: Int, brokeRecord: Bool)] {
        dayActivity.chunked(into: 7).suffix(13).map { week in
            (week.filter { $0 > 0 }.count, week.contains(2))
        }
    }

    private var barGradient: LinearGradient {
        LinearGradient(colors: [LBColor.emerald.opacity(0.35), LBColor.emerald],
                       startPoint: .bottom, endPoint: .top)
    }

    var body: some View {
        let data = weeks
        let peak = max(1, data.map(\.active).max() ?? 1)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                SectionLabel("MOMENTUM", icon: "chart.bar.xaxis")
                    .layoutPriority(1)
                Spacer(minLength: 4)
                Text("13 WEEKS")
                    .font(.system(size: 9, weight: .bold))
                    .kerning(0.8)
                    .foregroundStyle(LBColor.dim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            GeometryReader { geo in
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(data.enumerated()), id: \.offset) { _, week in
                        let fraction = CGFloat(week.active) / CGFloat(peak)
                        ZStack(alignment: .bottom) {
                            // Faint full-height track so rest weeks still read as bars.
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.white.opacity(0.05))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(week.brokeRecord
                                      ? AnyShapeStyle(LBColor.limitBreakGradient)
                                      : AnyShapeStyle(barGradient))
                                .frame(height: max(3, geo.size.height * fraction))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}

/// The top three ceilings as a podium — #1 centered and tallest, crowned gold,
/// with silver and bronze flanking it. Far more of a trophy shelf than a list.
struct CeilingsPodium: View {
    let records: [WidgetSnapshot.TopRecord]
    let totalLimitBreaks: Int

    /// Left-to-right podium order: silver, gold, bronze.
    private var podium: [(rank: Int, record: WidgetSnapshot.TopRecord)] {
        let top = Array(records.prefix(3))
        var slots: [(Int, WidgetSnapshot.TopRecord)] = []
        if top.count > 1 { slots.append((2, top[1])) }
        if top.count > 0 { slots.append((1, top[0])) }
        if top.count > 2 { slots.append((3, top[2])) }
        return slots
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                SectionLabel("CEILINGS", icon: "crown.fill")
                    .layoutPriority(1)
                Spacer(minLength: 4)
                Text("\(totalLimitBreaks) BREAKS")
                    .font(.system(size: 9, weight: .bold))
                    .kerning(0.8)
                    .foregroundStyle(LBColor.violet)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            if records.isEmpty {
                Spacer()
                Text("No ceilings yet — log a session and shatter your first.")
                    .font(.caption2)
                    .foregroundStyle(LBColor.dim)
                Spacer()
            } else {
                GeometryReader { geo in
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(podium, id: \.rank) { item in
                            column(item.rank, item.record, area: geo.size.height)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
    }

    private func column(_ rank: Int, _ record: WidgetSnapshot.TopRecord, area: CGFloat) -> some View {
        let scale: CGFloat = rank == 1 ? 1.0 : (rank == 2 ? 0.7 : 0.52)
        let tint = medal(rank)
        // Reserve room for the two text rows; the bar takes what's left, scaled.
        let barHeight = max(18, (area - 34) * scale)

        return VStack(spacing: 3) {
            Text("\(Int(record.value))")
                .font(.system(.callout, design: .rounded, weight: .black))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(record.name)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(LBColor.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            RoundedRectangle(cornerRadius: 7)
                .fill(LinearGradient(colors: [tint.opacity(0.3), tint],
                                     startPoint: .bottom, endPoint: .top))
                .frame(height: barHeight)
                .overlay(alignment: .top) {
                    Text("\(rank)")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.black.opacity(0.55))
                        .padding(.top, 4)
                }
        }
        .frame(maxWidth: .infinity)
    }

    private func medal(_ rank: Int) -> Color {
        switch rank {
        case 1:  return LBColor.gold
        case 2:  return Color(white: 0.78)
        default: return LBColor.coral
        }
    }
}

/// The hero stat rail across the top of the dashboard: level and rank, then the
/// day's live vitals as pills.
struct StatRail: View {
    let snapshot: WidgetSnapshot

    private var hitGoal: Bool { snapshot.todaySteps >= Double(snapshot.stepGoal) }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("LV \(snapshot.level)")
                    .font(.system(.title3, design: .rounded, weight: .black))
                    .foregroundStyle(.white)
                Text(snapshot.rankTitle.uppercased())
                    .font(.caption2.weight(.bold))
                    .kerning(1)
                    .foregroundStyle(LBColor.violet)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            statPill(icon: "flame.fill", value: "\(snapshot.streakDays)", label: "streak", tint: LBColor.gold)
            statPill(icon: "shoeprints.fill", value: StepFormat.compact(snapshot.todaySteps), label: "steps",
                     tint: hitGoal ? LBColor.emerald : LBColor.teal)
            statPill(icon: "bolt.fill", value: snapshot.weeklyXP.formatted(.number.notation(.compactName)),
                     label: "xp / wk", tint: LBColor.violet)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private func statPill(icon: String, value: String, label: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .kerning(0.8)
                    .foregroundStyle(LBColor.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small uppercase section header with a violet glyph.
struct SectionLabel: View {
    let title: String
    let icon: String

    init(_ title: String, icon: String) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(LBColor.violet)
            Text(title)
                .font(.caption2.weight(.bold))
                .kerning(1.2)
                .foregroundStyle(LBColor.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// A translucent rounded container that gives each dashboard panel its own tile.
/// `fillHeight` lets a panel expand to fill available height, or hug its content.
struct DashboardCard<Content: View>: View {
    var fillHeight: Bool = true
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Helpers

private extension Collection {
    func chunked(into size: Int) -> [[Element]] {
        var result: [[Element]] = []
        var chunk: [Element] = []
        for element in self {
            chunk.append(element)
            if chunk.count == size {
                result.append(chunk)
                chunk = []
            }
        }
        if !chunk.isEmpty { result.append(chunk) }
        return result
    }
}

#if DEBUG
#Preview("Dashboard", as: .systemLarge) {
    DashboardWidget()
} timeline: {
    SnapshotEntry(date: Date(), snapshot: .placeholder)
}
#endif
