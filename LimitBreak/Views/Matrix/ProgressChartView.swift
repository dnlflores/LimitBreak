import SwiftUI
import Charts

/// Weekly training volume over the last 8 weeks, stacked by focus (Push /
/// Pull / Legs / Core). Tapping a bar reveals that week's full breakdown.
struct ProgressChartView: View {
    let sessions: [WorkoutSession]

    @State private var selectedDate: Date?

    private static let weeksShown = 8

    private enum Focus: String, CaseIterable {
        case push = "Push", pull = "Pull", legs = "Legs", core = "Core"

        init(group: MuscleGroup) {
            switch group {
            case .chest, .deltoids, .triceps: self = .push
            case .lats, .biceps, .forearms:   self = .pull
            case .quads, .hamstrings, .glutes, .calves: self = .legs
            case .core: self = .core
            }
        }

        var color: Color {
            switch self {
            case .push: Theme.violet
            case .pull: Theme.teal
            case .legs: Theme.gold
            case .core: Theme.coral
            }
        }
    }

    private struct WeekSlice: Identifiable {
        let id: String
        let weekStart: Date
        let focus: Focus
        let volume: Double
    }

    // MARK: - Data shaping

    private var calendar: Calendar { Calendar.current }

    private var chartStart: Date {
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: Date())!.start
        return calendar.date(byAdding: .weekOfYear, value: -(Self.weeksShown - 1), to: thisWeek)!
    }

    private var slices: [WeekSlice] {
        var totals: [Date: [Focus: Double]] = [:]
        for session in sessions where session.startDate >= chartStart {
            let week = calendar.dateInterval(of: .weekOfYear, for: session.startDate)!.start
            for set in session.sets where !set.isWarmup {
                guard let exercise = set.exercise else { continue }
                let volume = set.weight * Double(set.reps)
                guard volume > 0 else { continue }
                let focus = Focus(group: exercise.muscleGroup)
                totals[week, default: [:]][focus, default: 0] += volume
            }
        }
        return totals.flatMap { week, byFocus in
            byFocus.map { focus, volume in
                WeekSlice(
                    id: "\(week.timeIntervalSince1970)-\(focus.rawValue)",
                    weekStart: week,
                    focus: focus,
                    volume: volume
                )
            }
        }
        .sorted { $0.weekStart < $1.weekStart }
    }

    private var selectedWeek: Date? {
        guard let selectedDate else { return nil }
        let week = calendar.dateInterval(of: .weekOfYear, for: selectedDate)!.start
        return slices.contains { $0.weekStart == week } ? week : nil
    }

    private var selectedWeekSessions: [WorkoutSession] {
        guard let selectedWeek,
              let interval = calendar.dateInterval(of: .weekOfYear, for: selectedWeek) else { return [] }
        return sessions
            .filter { interval.contains($0.startDate) }
            .sorted { $0.startDate < $1.startDate }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("POWER OUTPUT — 8 WEEKS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textDim)
                .kerning(1.5)

            if slices.isEmpty {
                Text("Log a few sessions to charge up the chart.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
            } else {
                chart

                if let selectedWeek {
                    weekBreakdown(selectedWeek)
                        .transition(.opacity)
                } else {
                    Text("Tap a bar to see that week's battles.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textDim)
                }
            }
        }
        .cardStyle()
        .animation(.spring(duration: 0.3), value: selectedWeek)
    }

    private var chart: some View {
        Chart(slices) { slice in
            BarMark(
                x: .value("Week", slice.weekStart, unit: .weekOfYear),
                y: .value("Volume", slice.volume)
            )
            .foregroundStyle(by: .value("Focus", slice.focus.rawValue))
            .cornerRadius(3)
            .opacity(selectedWeek == nil || selectedWeek == slice.weekStart ? 1 : 0.35)
        }
        .chartForegroundStyleScale([
            Focus.push.rawValue: Focus.push.color,
            Focus.pull.rawValue: Focus.pull.color,
            Focus.legs.rawValue: Focus.legs.color,
            Focus.core.rawValue: Focus.core.color,
        ])
        .chartXSelection(value: $selectedDate)
        .chartXAxis {
            AxisMarks(values: .stride(by: .weekOfYear)) { _ in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: true)
                    .foregroundStyle(Theme.textDim)
                    .font(.system(size: 8))
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                AxisValueLabel {
                    if let volume = value.as(Double.self) {
                        Text(Int(volume).formatted(.number.notation(.compactName)))
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.textDim)
                    }
                }
            }
        }
        .chartLegend(position: .bottom, spacing: 8) {
            HStack(spacing: 12) {
                ForEach(Focus.allCases, id: \.rawValue) { focus in
                    HStack(spacing: 4) {
                        Circle().fill(focus.color).frame(width: 7, height: 7)
                        Text(focus.rawValue)
                    }
                }
            }
            .font(.caption2)
            .foregroundStyle(Theme.textDim)
        }
        .frame(height: 190)
    }

    private func weekBreakdown(_ week: Date) -> some View {
        let weekSlices = slices.filter { $0.weekStart == week }
        let total = weekSlices.reduce(0) { $0 + $1.volume }
        let sessions = selectedWeekSessions

        return VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Theme.stroke)

            HStack {
                Text("Week of \(week.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(total).formatted()) lbs · \(sessions.count) session\(sessions.count == 1 ? "" : "s")")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.emerald)
            }

            HStack(spacing: 6) {
                ForEach(weekSlices.sorted { $0.volume > $1.volume }) { slice in
                    HStack(spacing: 4) {
                        Circle().fill(slice.focus.color).frame(width: 6, height: 6)
                        Text("\(slice.focus.rawValue) \(Int(slice.volume).formatted(.number.notation(.compactName)))")
                    }
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.surfaceRaised, in: Capsule())
                }
                Spacer()
            }

            ForEach(sessions, id: \.id) { session in
                HStack {
                    Text(session.name)
                        .font(.caption)
                    Spacer()
                    Text(session.startDate.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.caption2)
                        .foregroundStyle(Theme.textDim)
                    Text("\(Int(session.totalVolume).formatted()) lbs")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.emerald)
                }
            }
        }
    }
}
