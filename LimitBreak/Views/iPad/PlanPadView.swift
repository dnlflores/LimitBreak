import SwiftUI
import SwiftData

/// The Plan tab on iPad: the training week as a board.
///
/// The phone shows one weekday row at a time and hides each day's movements
/// behind a tap. With seven columns side by side you can read the whole week —
/// what's coming, what's done, and what every session actually contains —
/// without opening anything.
struct PlanPadView: View {
    @Query(sort: \WeeklyPlan.createdAt, order: .reverse) private var plans: [WeeklyPlan]

    @State private var showBuilder = false

    private var plan: WeeklyPlan? { plans.first }

    var body: some View {
        NavigationStack {
            Group {
                if let plan {
                    PlanBoardView(plan: plan, onRebuild: { showBuilder = true })
                } else {
                    emptyState
                }
            }
            .obsidianBackground()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: PlannedDay.self) { PlannedDayDetailView(day: $0) }
            .navigationDestination(for: WorkoutSession.self) { WorkoutDetailView(session: $0) }
        }
        .sheet(isPresented: $showBuilder) {
            WeeklyPlanBuilderView(existing: plan)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            Image(systemName: "calendar")
                .font(.system(size: 82))
                .foregroundStyle(Theme.limitBreakGradient)

            Text("Plan Your Week")
                .font(.system(size: 34, weight: .bold, design: .rounded))

            Text("Pick the days you train and a focus for each. The coach builds a workout for every day \u{2014} start a session or edit it whenever you like.")
                .font(.body)
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            Button {
                Haptics.shared.tick()
                showBuilder = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                    Text("BUILD YOUR WEEK")
                        .font(.headline)
                        .kerning(1)
                }
                .frame(width: 320)
                .padding(.vertical, 16)
                .foregroundStyle(.white)
                .glassCTA(tint: Theme.emerald.opacity(0.85))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Board

private struct PlanBoardView: View {
    @Environment(WorkoutManager.self) private var workout
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var sessions: [WorkoutSession]

    let plan: WeeklyPlan
    var onRebuild: () -> Void

    @State private var showClearConfirm = false
    /// The weekday whose workout fills the detail pane. Seeded to today (or the
    /// first training day) on appear; -1 until then.
    @State private var selectedWeekday = -1

    var body: some View {
        VStack(spacing: PadLayout.gutter) {
            header

            // Master-detail: a compact week rail on the left, the selected day's
            // full editable workout on the right. Fills the whole board instead
            // of tiling seven columns with an awkward empty slot.
            HStack(alignment: .top, spacing: PadLayout.gutter) {
                weekRail
                    .frame(width: 320)

                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, PadLayout.screenPadding)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .onAppear { if selectedWeekday < 0 { selectedWeekday = defaultWeekday } }
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
        let training = plan.days.filter { $0.routine != nil }
        let done = training.filter(isDone).count

        return PadScreenHeader(
            title: "Plan",
            subtitle: training.isEmpty
                ? "No training days scheduled yet."
                : "\(done) of \(training.count) sessions done this week"
        ) {
            HStack(spacing: 14) {
                if !training.isEmpty {
                    weekProgressRing(done: done, total: training.count)
                }
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
                        .font(.title3)
                        .foregroundStyle(Theme.textDim)
                        .glassCircle(diameter: 48)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Plan options")
            }
        }
    }

    private func weekProgressRing(done: Int, total: Int) -> some View {
        let progress = total > 0 ? Double(done) / Double(total) : 0
        return ZStack {
            Circle().stroke(Theme.emerald.opacity(0.15), lineWidth: 6)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Theme.emerald, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(progress * 100))%")
                .font(.system(size: 13, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.emerald)
        }
        .frame(width: 52, height: 52)
        .accessibilityLabel("\(done) of \(total) sessions done")
    }

    // MARK: Week rail

    private var weekRail: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 8) {
                ForEach(PlanWeekday.mondayFirst, id: \.self) { weekday in
                    railRow(weekday)
                }
            }
            .padding(.bottom, PadLayout.scrollBottomInset)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// One tappable weekday in the rail: its focus, movement count, and whether
    /// it's today or already trained. Selecting it fills the detail pane.
    private func railRow(_ weekday: Int) -> some View {
        let isToday = weekday == PlanWeekday.today
        let day = daysByWeekday[weekday]
        let routine = day?.routine
        let selected = weekday == selectedWeekday
        let done = day.map(isDone) ?? false

        return Button {
            Haptics.shared.tick()
            selectedWeekday = weekday
        } label: {
            HStack(spacing: 12) {
                Text(PlanWeekday.name(weekday, short: true).uppercased())
                    .font(.caption.weight(.black))
                    .kerning(0.8)
                    .foregroundStyle(routine != nil ? .primary : Theme.textDim)
                    .frame(width: 40, alignment: .leading)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: routine != nil ? (day?.focus.icon ?? "figure.strengthtraining.traditional") : "moon.zzz.fill")
                            .font(.caption)
                            .foregroundStyle(routine != nil ? Theme.emerald : Theme.textDim)
                        Text(routine != nil ? (day?.focus.label ?? "") : "Rest")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(routine != nil ? .primary : Theme.textDim)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    if let routine {
                        Text("\(routine.exerciseCount) movement\(routine.exerciseCount == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(Theme.textDim)
                    }
                }

                Spacer(minLength: 0)

                if done {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.subheadline)
                        .foregroundStyle(Theme.emerald)
                } else if isToday {
                    Text("TODAY")
                        .font(.system(size: 9, weight: .black))
                        .kerning(0.8)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Theme.limitBreakGradient, in: Capsule())
                        .foregroundStyle(Theme.background)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.emerald.opacity(0.14) : Color.white.opacity(0.03),
                        in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(selected ? Theme.emerald.opacity(0.6)
                                  : (isToday ? Theme.emerald.opacity(0.25) : Theme.stroke),
                                  lineWidth: selected ? 1.5 : 1)
            )
            .opacity(routine == nil && !selected ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(PlanWeekday.name(weekday)), \(routine != nil ? (day?.focus.label ?? "workout") : "rest day")")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Detail pane

    /// The selected day's full workout — reuses the phone day editor so add,
    /// replace (AI or manual), reorder, regenerate, and set/rep/weight edits all
    /// work inline. `.id` rebuilds it when the selection changes so its reorder
    /// mirror reseeds for the new day.
    @ViewBuilder
    private var detailPane: some View {
        if let day = daysByWeekday[selectedWeekday], day.routine != nil {
            PlannedDayDetailView(day: day)
                .id(day.id)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Theme.glassBorder, lineWidth: 1))
        } else {
            restPane
        }
    }

    private var restPane: some View {
        VStack(spacing: 18) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 72))
                .foregroundStyle(Theme.textDim)
            Text("Rest Day")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text("Nothing scheduled for \(PlanWeekday.name(selectedWeekday >= 0 ? selectedWeekday : PlanWeekday.today)). Recover \u{2014} or start something anyway from the Train tab.")
                .font(.body)
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Theme.glassBorder, lineWidth: 1))
    }

    /// Today when it's a training day, else the first training day, else today.
    private var defaultWeekday: Int {
        let today = PlanWeekday.today
        if daysByWeekday[today]?.routine != nil { return today }
        if let firstTraining = PlanWeekday.mondayFirst.first(where: { daysByWeekday[$0]?.routine != nil }) {
            return firstTraining
        }
        return today
    }

    // MARK: Data

    private var daysByWeekday: [Int: PlannedDay] {
        Dictionary(plan.days.map { ($0.weekday, $0) }) { first, _ in first }
    }

    private var sessionsByWeekday: [Int: WorkoutSession] {
        PlanCompletion.sessionsByWeekday(from: sessions)
    }

    private func isDone(_ day: PlannedDay) -> Bool {
        sessionsByWeekday[day.weekday] != nil
    }
}
