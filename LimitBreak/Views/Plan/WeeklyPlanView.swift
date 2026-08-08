import SwiftUI
import SwiftData

/// Shows the built week: a prominent card for today's workout plus a row per
/// weekday. Training days push into a detail view; rest days are muted.
struct WeeklyPlanView: View {
    @Environment(WorkoutManager.self) private var workout
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var sessions: [WorkoutSession]

    let plan: WeeklyPlan
    var onRebuild: () -> Void

    @State private var showClearConfirm = false

    private var daysByWeekday: [Int: PlannedDay] {
        Dictionary(plan.days.map { ($0.weekday, $0) }) { first, _ in first }
    }

    /// The workout logged on each weekday this week — used to mark plan days done.
    private var sessionsByWeekday: [Int: WorkoutSession] {
        PlanCompletion.sessionsByWeekday(from: sessions)
    }

    private func isDone(_ day: PlannedDay) -> Bool {
        sessionsByWeekday[day.weekday] != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                todayCard

                weekSection
            }
            .padding()
        }
        .confirmationDialog("Clear this week's plan?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear Plan", role: .destructive) {
                workout.clearWeeklyPlan()
                Haptics.shared.logSet()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every day and its workout. You can build a new week anytime.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            Text("Plan")
                .font(.largeTitle.bold())
            Spacer()
            Menu {
                Button {
                    Haptics.shared.tick()
                    onRebuild()
                } label: {
                    Label("Rebuild Plan", systemImage: "arrow.triangle.2.circlepath")
                }
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label("Clear Plan", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title2)
                    .glassCircle()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Plan options")
        }
    }

    // MARK: Today

    @ViewBuilder
    private var todayCard: some View {
        let today = PlanWeekday.today
        VStack(alignment: .leading, spacing: 12) {
            Text("TODAY — \(PlanWeekday.name(today).uppercased())")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textDim)
                .kerning(1.5)

            if let day = daysByWeekday[today], let routine = day.routine {
                let done = isDone(day)
                NavigationLink(value: day) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(day.focus.label)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(Theme.limitBreakGradient)
                            if done {
                                Label("Completed", systemImage: "checkmark.seal.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.emerald)
                            } else {
                                Text("\(routine.exerciseCount) movement\(routine.exerciseCount == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textDim)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textDim)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    Haptics.shared.tick()
                    workout.startSession(from: routine, withPartner: plan.withPartner)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: done ? "arrow.clockwise" : "play.fill")
                        Text(done ? "TRAIN AGAIN" : "START TODAY'S SESSION")
                            .font(.headline)
                            .kerning(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .foregroundStyle(done ? Theme.emerald : .white)
                    .modifier(TodayCTAStyle(done: done))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.textDim)
                    Text("Rest day — no workout scheduled.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textDim)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: Week

    private var weekSection: some View {
        let trainingDays = plan.days.filter { $0.routine != nil }
        let doneCount = trainingDays.filter { isDone($0) }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("YOUR WEEK")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textDim)
                    .kerning(1.5)
                Spacer()
                if !trainingDays.isEmpty {
                    Text("\(doneCount) of \(trainingDays.count) done")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(doneCount == trainingDays.count ? Theme.emerald : Theme.textDim)
                }
            }

            VStack(spacing: 10) {
                ForEach(PlanWeekday.mondayFirst, id: \.self) { weekday in
                    weekdayRow(weekday)
                }
            }
        }
    }

    @ViewBuilder
    private func weekdayRow(_ weekday: Int) -> some View {
        let isToday = weekday == PlanWeekday.today
        if let day = daysByWeekday[weekday], let routine = day.routine {
            let done = isDone(day)
            NavigationLink(value: day) {
                HStack(spacing: 14) {
                    dayBadge(weekday, isToday: isToday, active: true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(day.focus.label)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.primary)
                        Text(routine.exercises.map(\.name).prefix(3).joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(Theme.textDim)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if done {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.subheadline)
                            .foregroundStyle(Theme.emerald)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                }
                .padding(12)
                .glassControl(cornerRadius: 16)
                .contentShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 14) {
                dayBadge(weekday, isToday: isToday, active: false)
                Text("Rest")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textDim)
                Spacer()
            }
            .padding(12)
            .opacity(0.6)
        }
    }

    private func dayBadge(_ weekday: Int, isToday: Bool, active: Bool) -> some View {
        Text(PlanWeekday.name(weekday, short: true).uppercased())
            .font(.caption2.weight(.bold))
            .frame(width: 44, height: 44)
            .foregroundStyle(active ? .black : Theme.textDim)
            .background(
                active ? AnyShapeStyle(Theme.emerald) : AnyShapeStyle(Theme.surfaceRaised),
                in: Circle()
            )
            .overlay {
                if isToday {
                    Circle().strokeBorder(Theme.limitBreakGradient, lineWidth: 2)
                }
            }
    }

    /// The today CTA reads as a solid call-to-action until the day is trained,
    /// then softens to a glass "train again" affordance.
    private struct TodayCTAStyle: ViewModifier {
        let done: Bool
        func body(content: Content) -> some View {
            if done {
                content.glassControl()
            } else {
                content.glassCTA(tint: Theme.emerald.opacity(0.85))
            }
        }
    }
}
