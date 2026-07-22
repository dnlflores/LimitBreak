import SwiftUI
import SwiftData

/// The full progression story: a calendar timeline of every reward earned —
/// LimitBreaks, finished quests, walks, activities — with LEVEL UP milestones
/// marked on the day each threshold fell.
struct RewardsTimelineView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var sessions: [WorkoutSession]
    @Query(sort: \Walk.date, order: .reverse) private var walks: [Walk]
    @Query(sort: \Activity.date, order: .reverse) private var activities: [Activity]
    @Query(sort: \PRRecord.dateAchieved, order: .reverse) private var records: [PRRecord]

    private var timeline: [XPEngine.TimelineDay] {
        XPEngine.timeline(sessions: sessions, records: records, walks: walks, activities: activities)
    }

    /// Days grouped under "JULY 2026"-style month banners.
    private var months: [(label: String, days: [XPEngine.TimelineDay])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [XPEngine.TimelineDay]] = [:]
        for day in timeline {
            let month = calendar.dateInterval(of: .month, for: day.day)!.start
            if buckets[month] == nil { order.append(month) }
            buckets[month, default: []].append(day)
        }
        return order.map { month in
            (month.formatted(.dateTime.month(.wide).year()).uppercased(), buckets[month] ?? [])
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

            if timeline.isEmpty {
                    Text("No rewards yet. Every session, LimitBreak, walk, and activity lands here.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .cardStyle()
                } else {
                    ForEach(months, id: \.label) { month in
                        Text(month.label)
                            .font(.caption.weight(.bold))
                            .kerning(1.5)
                            .foregroundStyle(Theme.textDim)
                            .padding(.top, 6)

                        ForEach(month.days) { day in
                            dayCard(day)
                        }
                    }
                }
            }
            .padding()
        }
        .obsidianBackground()
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .glassCircle()
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text("Reward Timeline")
                    .font(.title2.bold())
                Text("Every point earned, every level climbed.")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }

            Spacer()
        }
        .padding(.bottom, 8)
    }

    private func dayCard(_ day: XPEngine.TimelineDay) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Date column
            VStack(spacing: 1) {
                Text(day.day.formatted(.dateTime.day()))
                    .font(.system(.title3, design: .rounded, weight: .black))
                    .monospacedDigit()
                Text(day.day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textDim)
            }
            .frame(width: 40)
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(day.events) { event in
                    if event.isLevelUp {
                        levelUpRow(event)
                    } else {
                        rewardRow(event)
                    }
                }

                if day.dayXP > 0 {
                    Text("+\(day.dayXP) XP total")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textDim)
                }
            }
        }
        .cardStyle()
    }

    private func rewardRow(_ event: XPEngine.TimelineEvent) -> some View {
        HStack(spacing: 10) {
            Image(systemName: event.icon)
                .font(.caption)
                .foregroundStyle(event.tint)
                .frame(width: 28, height: 28)
                .background(event.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.caption.weight(.bold))
                Text(event.detail)
                    .font(.caption2)
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
            }

            Spacer()

            Text("+\(event.xp) XP")
                .font(.caption.weight(.black))
                .monospacedDigit()
                .foregroundStyle(event.tint)
        }
    }

    /// The milestone row — rimmed in LimitBreak energy.
    private func levelUpRow(_ event: XPEngine.TimelineEvent) -> some View {
        HStack(spacing: 10) {
            Image(systemName: event.icon)
                .font(.subheadline)
                .foregroundStyle(Theme.limitBreakGradient)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.caption.weight(.black))
                    .kerning(1)
                    .foregroundStyle(Theme.limitBreakGradient)
                Text(event.detail)
                    .font(.caption2.weight(.semibold))
            }

            Spacer()

            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(Theme.gold)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(Theme.violet.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.limitBreakGradient, lineWidth: 1)
                .opacity(0.5)
        )
    }
}
