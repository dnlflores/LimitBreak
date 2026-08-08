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

    var body: some View {
        GeometryReader { proxy in
            // Seven readable columns need roughly 160pt each plus gutters;
            // below that the week wraps into a grid instead of squeezing.
            let asRow = proxy.size.width >= 1150

            VStack(spacing: PadLayout.gutter) {
                header

                todayHero

                if asRow {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(PlanWeekday.mondayFirst, id: \.self) { weekday in
                            dayColumn(weekday)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 230, maximum: 400), spacing: 12)],
                            alignment: .leading,
                            spacing: 12
                        ) {
                            ForEach(PlanWeekday.mondayFirst, id: \.self) { weekday in
                                dayColumn(weekday)
                            }
                        }
                        .padding(.bottom, PadLayout.scrollBottomInset)
                    }
                }
            }
            .padding(.horizontal, PadLayout.screenPadding)
            .padding(.top, 4)
            .padding(.bottom, 12)
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

    // MARK: Today

    @ViewBuilder
    private var todayHero: some View {
        let today = PlanWeekday.today
        if let day = daysByWeekday[today], let routine = day.routine {
            let done = isDone(day)
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("TODAY \u{2014} \(PlanWeekday.name(today).uppercased())")
                        .font(.caption.weight(.bold))
                        .kerning(1.6)
                        .foregroundStyle(Theme.textDim)

                    Text(day.focus.label)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.limitBreakGradient)

                    if done {
                        Label("Completed", systemImage: "checkmark.seal.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.emerald)
                    } else {
                        Text(routine.exercises.map(\.name).prefix(5).joined(separator: " \u{00B7} "))
                            .font(.subheadline)
                            .foregroundStyle(Theme.textDim)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 12) {
                    NavigationLink(value: day) {
                        Label("Review", systemImage: "list.bullet")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 22)
                            .padding(.vertical, 15)
                            .glassControl()
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        Haptics.shared.tick()
                        workout.startSession(from: routine, withPartner: plan.withPartner)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: done ? "arrow.clockwise" : "play.fill")
                            Text(done ? "TRAIN AGAIN" : "START SESSION")
                                .font(.headline)
                                .kerning(0.8)
                        }
                        .frame(width: 230)
                        .padding(.vertical, 15)
                        .foregroundStyle(done ? Theme.emerald : .white)
                        .modifier(PlanCTAStyle(done: done))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26))
            .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(Theme.limitBreakGradient, lineWidth: 1))
            .shadow(color: Theme.violet.opacity(0.22), radius: 20, y: 8)
        } else {
            HStack(spacing: 14) {
                Image(systemName: "moon.zzz.fill")
                    .font(.title)
                    .foregroundStyle(Theme.textDim)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rest day")
                        .font(.title3.weight(.bold))
                    Text("Nothing scheduled for \(PlanWeekday.name(PlanWeekday.today)). Recover — or start something anyway from the Train tab.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textDim)
                }
                Spacer()
            }
            .padding(22)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26))
            .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(Theme.glassBorder, lineWidth: 1))
        }
    }

    // MARK: Day column

    @ViewBuilder
    private func dayColumn(_ weekday: Int) -> some View {
        let isToday = weekday == PlanWeekday.today
        let day = daysByWeekday[weekday]
        let routine = day?.routine

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(PlanWeekday.name(weekday, short: true).uppercased())
                    .font(.caption.weight(.black))
                    .kerning(1.2)
                    .foregroundStyle(routine != nil ? .primary : Theme.textDim)
                Spacer(minLength: 0)
                if let day, isDone(day) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.emerald)
                }
                if isToday {
                    Text("TODAY")
                        .font(.system(size: 9, weight: .black))
                        .kerning(0.8)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Theme.limitBreakGradient, in: Capsule())
                        .foregroundStyle(Theme.background)
                }
            }

            if let day, let routine {
                NavigationLink(value: day) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: day.focus.icon)
                                .font(.caption)
                                .foregroundStyle(Theme.emerald)
                            Text(day.focus.label)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        Text("\(routine.exerciseCount) movement\(routine.exerciseCount == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(Theme.textDim)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider().overlay(Theme.stroke)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(routine.orderedItems, id: \.id) { item in
                            if let exercise = item.exercise {
                                HStack(alignment: .top, spacing: 6) {
                                    Circle()
                                        .fill(Theme.emerald.opacity(0.5))
                                        .frame(width: 5, height: 5)
                                        .padding(.top, 5)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(exercise.name)
                                            .font(.caption)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                        Text(setSummary(item))
                                            .font(.system(size: 10, weight: .semibold))
                                            .monospacedDigit()
                                            .foregroundStyle(Theme.textDim)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)

                Button {
                    Haptics.shared.tick()
                    workout.startSession(from: routine, withPartner: plan.withPartner)
                } label: {
                    Label(isDone(day) ? "Again" : "Start", systemImage: isDone(day) ? "arrow.clockwise" : "play.fill")
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(isDone(day) ? Theme.emerald : .white)
                        .modifier(PlanCTAStyle(done: isDone(day), cornerRadius: 12))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.textDim)
                    Text("Rest")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textDim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 24)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(isToday ? Theme.emerald.opacity(0.5) : Theme.stroke, lineWidth: 1)
        )
        .opacity(routine == nil ? 0.65 : 1)
    }

    private func setSummary(_ item: RoutineItem) -> String {
        let sets = max(1, item.targetSets)
        if let reps = item.targetReps, reps > 0 {
            if let weight = item.targetWeight, weight > 0 {
                return "\(sets)\u{00D7}\(reps) @ \(weight.cleanWeight)"
            }
            return "\(sets)\u{00D7}\(reps)"
        }
        return "\(sets) set\(sets == 1 ? "" : "s")"
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

/// A start button reads as a solid call-to-action until the day is trained,
/// then softens to a glass "train again" affordance.
private struct PlanCTAStyle: ViewModifier {
    let done: Bool
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        if done {
            content.glassControl(cornerRadius: cornerRadius)
        } else {
            content.glassCTA(tint: Theme.emerald.opacity(0.85), cornerRadius: cornerRadius)
        }
    }
}
