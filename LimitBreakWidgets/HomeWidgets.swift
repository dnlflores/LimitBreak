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
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct SkillMatrixWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot

    private var weeksShown: Int { family == .systemSmall ? 7 : 16 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                    .font(.caption2)
                    .foregroundStyle(LBColor.gold)
                Text("\(snapshot.streakDays) day streak")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                if family == .systemMedium {
                    Text("\(Int(snapshot.weeklyVolume).formatted(.number.notation(.compactName))) lbs this week")
                        .font(.caption2)
                        .foregroundStyle(LBColor.dim)
                }
            }

            matrixGrid
        }
    }

    /// Columns are weeks (oldest → newest), rows are days.
    private var matrixGrid: some View {
        let days = snapshot.dayActivity.suffix(weeksShown * 7)
        let columns = days.chunked(into: 7)

        return GeometryReader { geo in
            let spacing: CGFloat = 3
            let cell = min(
                (geo.size.width - spacing * CGFloat(columns.count - 1)) / CGFloat(columns.count),
                (geo.size.height - spacing * 6) / 7
            )
            HStack(alignment: .top, spacing: spacing) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: spacing) {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, level in
                            RoundedRectangle(cornerRadius: cell / 4)
                                .fill(color(for: level))
                                .frame(width: cell, height: cell)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func color(for level: Int) -> Color {
        switch level {
        case 2: LBColor.gold
        case 1: LBColor.emerald
        default: Color.white.opacity(0.08)
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
        .description("Day streak and weekly damage dealt, at a glance.")
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
                Label("\(snapshot.streakDays) day streak", systemImage: "flame.fill")
                    .font(.headline)
                Text("\(Int(snapshot.weeklyVolume).formatted()) lbs this week")
                    .font(.caption2)
                Text("\(snapshot.weeklyPRs) LimitBreak\(snapshot.weeklyPRs == 1 ? "" : "s")")
                    .font(.caption2)
            }

        default:
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
                    Text("\(Int(snapshot.weeklyVolume).formatted(.number.notation(.compactName)))")
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(LBColor.emerald)
                    Text("lbs this week")
                        .font(.caption2)
                        .foregroundStyle(LBColor.dim)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
