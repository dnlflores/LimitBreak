import SwiftUI
import SwiftData

// MARK: - Catalog thinning

/// Weekly re-rolling of the plan's workouts.
///
/// The plan builder generates each day once and then persists that routine
/// forever, so the same week repeats until the lifter rebuilds by hand. This
/// re-runs the *existing* generation pipeline per training day, keeping the
/// lifter's chosen weekdays, focuses, exercise count, duration, partner and
/// superset settings — only the movement selection changes.
///
/// Variety is not left to chance. Both generator tiers already pick from a
/// catalog (`WorkoutAI.focusedCatalog` for the on-device model, `fallbackPlan`
/// for the deterministic tier), so the cheapest honest way to force a different
/// week is to hide last week's movements from that catalog before generating.
/// No prompt engineering, no seeded RNG, no second code path.
enum PlanShuffle {

    /// Removes recently-used movements from the catalog handed to the generator,
    /// so the next roll cannot simply re-pick the same week.
    ///
    /// The exclusion is advisory: if hiding those names would leave too few
    /// movements that still hit the focus, the full catalog is returned instead.
    /// A thin, technically-fresh workout is worse than a repeated good one —
    /// this is a variety feature, not a correctness one.
    ///
    /// - Parameters:
    ///   - catalog: Every movement available to the generator.
    ///   - avoiding: Movement names used by the plan being replaced (case-insensitive).
    ///   - targetMuscleGroups: The day's focus muscles. Empty (Full Body) means
    ///     every remaining movement counts as a match.
    ///   - minimumMatches: How many focus-matching movements must survive for the
    ///     thinned catalog to be considered usable.
    static func thinnedCatalog(
        _ catalog: [ExerciseBrief],
        avoiding: Set<String>,
        targetMuscleGroups: [String],
        minimumMatches: Int
    ) -> [ExerciseBrief] {
        guard !avoiding.isEmpty else { return catalog }
        let excluded = Set(avoiding.map { $0.lowercased() })
        let remaining = catalog.filter { !excluded.contains($0.name.lowercased()) }

        let targets = Set(targetMuscleGroups.map { $0.lowercased() })
        let matches: Int
        if targets.isEmpty {
            matches = remaining.count
        } else {
            matches = remaining.filter { brief in
                brief.muscleGroups.contains { targets.contains($0.lowercased()) }
            }.count
        }
        return matches >= minimumMatches ? remaining : catalog
    }

    /// The movement names currently programmed across the whole plan — what a
    /// re-roll tries to avoid. Taken week-wide rather than per day so a Push day
    /// doesn't simply inherit the bench press that Monday's Upper day just lost.
    @MainActor
    static func currentMovementNames(in plan: WeeklyPlan) -> Set<String> {
        Set(plan.days.flatMap { $0.routine?.exercises.map(\.name) ?? [] })
    }

    /// How many focus-matching movements must remain after thinning: enough to
    /// fill the day twice over, so the generator still has room to choose.
    static func minimumMatches(exercisesPerDay: Int) -> Int {
        max(exercisesPerDay * 2, 6)
    }

    /// Re-rolls every training day in the plan, in place.
    ///
    /// Days are replaced one at a time via `replacePlanDayRoutine`, so a failure
    /// partway through leaves the earlier days re-rolled and the rest untouched
    /// rather than destroying the week — unlike `buildWeeklyPlan`, which clears
    /// the plan before it has anything to put back.
    ///
    /// - Returns: The number of days that were actually replaced.
    @MainActor
    @discardableResult
    static func reroll(
        plan: WeeklyPlan,
        workout: WorkoutManager,
        exercises: [Exercise],
        sessions: [WorkoutSession],
        profile: TrainingProfile?,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async -> Int {
        let days = plan.orderedDays
        guard !days.isEmpty else { return 0 }

        let avoid = currentMovementNames(in: plan)
        let minimum = minimumMatches(exercisesPerDay: plan.exercisesPerDay)
        var replaced = 0

        for (index, day) in days.enumerated() {
            onProgress?(index, days.count)
            guard let generated = await PlanBuilding.generateDay(
                focus: day.focus,
                exercisesPerDay: plan.exercisesPerDay,
                duration: plan.duration,
                withPartner: plan.withPartner,
                allowSupersets: plan.allowSupersets,
                exercises: exercises,
                sessions: sessions,
                profile: profile,
                avoiding: avoid,
                minimumMatches: minimum
            ), !generated.items.isEmpty else { continue }
            workout.replacePlanDayRoutine(day, title: generated.title, items: generated.items)
            replaced += 1
        }

        if replaced > 0 { workout.markPlanShuffled(plan) }
        return replaced
    }
}

// MARK: - Shuffle controller

/// Drives shuffling for whichever Plan screen is on-screen (phone or iPad) and
/// owns the progress overlay, so both screens get identical behaviour from one
/// implementation.
///
/// Also performs the automatic weekly roll: when "Shuffle every week" is on and
/// the calendar week has turned over since the last shuffle, opening the Plan
/// tab re-rolls the week once. There is no background scheduler here on purpose
/// — a plan the lifter never looks at doesn't need to have been rebuilt, and a
/// BGTaskScheduler job would burn battery and add an entitlement for a feature
/// that is only ever observed from this screen.
struct PlanShuffleModifier: ViewModifier {
    @Environment(WorkoutManager.self) private var workout
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var sessions: [WorkoutSession]
    @Query private var profiles: [TrainingProfile]

    let plan: WeeklyPlan
    @Binding var trigger: Bool

    @State private var isShuffling = false
    @State private var progress = (done: 0, total: 0)

    /// Identifies the current calendar week; changing it re-arms the automatic
    /// roll without needing a timer.
    private var weekKey: Date {
        Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? .distantPast
    }

    func body(content: Content) -> some View {
        content
            .overlay { if isShuffling { overlay } }
            .onChange(of: trigger) { _, newValue in
                guard newValue else { return }
                trigger = false
                Task { await run() }
            }
            .task(id: weekKey) {
                guard plan.randomizeWeekly, plan.needsWeeklyShuffle() else { return }
                await run()
            }
    }

    private var overlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().tint(Theme.emerald)
                Text("Shuffling your week…")
                    .font(.subheadline.weight(.semibold))
                if progress.total > 0 {
                    Text("\(min(progress.done + 1, progress.total)) of \(progress.total)")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                }
            }
            .padding(28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private func run() async {
        guard !isShuffling else { return }
        isShuffling = true
        progress = (0, plan.orderedDays.count)
        let replaced = await PlanShuffle.reroll(
            plan: plan,
            workout: workout,
            exercises: exercises,
            sessions: sessions,
            profile: profiles.first,
            onProgress: { done, total in progress = (done, total) }
        )
        isShuffling = false
        if replaced > 0 { Haptics.shared.success() }
    }
}

extension View {
    /// Adds shuffle handling to a Plan screen. Set `trigger` to true to re-roll
    /// the week now; automatic weekly rolls happen on their own.
    func planShuffle(plan: WeeklyPlan, trigger: Binding<Bool>) -> some View {
        modifier(PlanShuffleModifier(plan: plan, trigger: trigger))
    }
}
