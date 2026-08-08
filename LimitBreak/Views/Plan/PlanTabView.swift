import SwiftUI
import SwiftData

// MARK: - Weekday helpers

/// Weekdays in Monday-first order using `Calendar` weekday numbers
/// (1 = Sunday … 7 = Saturday), for display and iteration.
enum PlanWeekday {
    static let mondayFirst = [2, 3, 4, 5, 6, 7, 1]

    static func name(_ weekday: Int, short: Bool = false) -> String {
        let symbols = short
            ? Calendar.current.shortWeekdaySymbols
            : Calendar.current.weekdaySymbols
        let index = (weekday - 1) % symbols.count
        return symbols[index]
    }

    static var today: Int { Calendar.current.component(.weekday, from: Date()) }
}

// MARK: - Plan completion

/// Works out which plan days have been trained this week by reading the training
/// log directly. A plan day counts as done when *any* workout was logged on that
/// weekday during the current week — no matter how the session was started — and
/// the matching session is linked so the lifter can open its report. Completion
/// resets automatically when a new calendar week begins.
enum PlanCompletion {
    /// The most-recent finished session logged on each weekday of the current
    /// week, keyed by `Calendar` weekday (1 = Sunday … 7 = Saturday).
    static func sessionsByWeekday(
        from sessions: [WorkoutSession],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Int: WorkoutSession] {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return [:] }
        var map: [Int: WorkoutSession] = [:]
        for session in sessions where session.endDate != nil {
            guard week.contains(session.startDate) else { continue }
            let weekday = calendar.component(.weekday, from: session.startDate)
            if let existing = map[weekday], existing.startDate >= session.startDate { continue }
            map[weekday] = session
        }
        return map
    }
}

// MARK: - Plan tab root

/// The Plan tab: build a repeating training week, then view it, start any day's
/// session, and edit its exercises. Replaces the old Campaign tab.
struct PlanTabView: View {
    @Query(sort: \WeeklyPlan.createdAt, order: .reverse) private var plans: [WeeklyPlan]
    @State private var showBuilder = false

    private var plan: WeeklyPlan? { plans.first }

    var body: some View {
        NavigationStack {
            Group {
                if let plan {
                    WeeklyPlanView(plan: plan, onRebuild: { showBuilder = true })
                } else {
                    emptyState
                }
            }
            .obsidianBackground()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: PlannedDay.self) { day in
                PlannedDayDetailView(day: day)
            }
            .navigationDestination(for: WorkoutSession.self) { session in
                WorkoutDetailView(session: session)
            }
        }
        .sheet(isPresented: $showBuilder) {
            WeeklyPlanBuilderView(existing: plan)
        }
    }

    private var emptyState: some View {
        ScrollView {
            HStack(alignment: .center) {
                Text("Plan")
                    .font(.largeTitle.bold())
                Spacer()
            }
            .padding([.horizontal, .top])

            VStack(spacing: 20) {
                Image(systemName: "calendar")
                    .font(.system(size: 60))
                    .foregroundStyle(Theme.limitBreakGradient)
                    .padding(.top, 40)

                Text("Plan Your Week")
                    .font(.title2.weight(.bold))

                Text("Pick the days you train and a focus for each. The coach builds a workout for every day — start a session or edit it whenever you like.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Button {
                    Haptics.shared.tick()
                    showBuilder = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                        Text("BUILD YOUR WEEK")
                            .font(.headline)
                            .kerning(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(.white)
                    .glassCTA(tint: Theme.emerald.opacity(0.85))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }
}
