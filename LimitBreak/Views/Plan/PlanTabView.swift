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
            .navigationTitle("Plan")
            .navigationDestination(for: PlannedDay.self) { day in
                PlannedDayDetailView(day: day)
            }
        }
        .sheet(isPresented: $showBuilder) {
            WeeklyPlanBuilderView(existing: plan)
        }
    }

    private var emptyState: some View {
        ScrollView {
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
