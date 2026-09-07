import SwiftUI
import SwiftData

// MARK: - Composition-preserving shuffle

/// Re-rolls the plan's workouts without changing what each day trains.
///
/// The plan builder generates each day once and then persists that routine
/// forever, so the same week repeats until the lifter rebuilds by hand.
///
/// A shuffle swaps **each slot individually for a different movement with the
/// same primary muscle group**, keeping the day's muscle composition exactly
/// intact. A day built as one biceps, one triceps, one chest, one back and one
/// shoulder movement comes back as one of each — different exercises, same
/// shape. Set count, slot order and superset pairing are preserved too; only
/// the movement changes, and its rep/load targets are re-grounded in that
/// movement's own history.
///
/// This is deliberately *not* a re-run of the AI day generator. The generator
/// only targets a focus's muscle-group set, so regenerating a Push day could
/// legitimately return three chest movements and two triceps — a valid Push
/// day, but not the day the lifter programmed. Slot-wise swapping is the only
/// approach that guarantees composition survives.
enum PlanShuffle {

    /// The minimum a shuffle needs to know about a movement: its name and its
    /// primary muscle group. Keeps the selection logic free of SwiftData so it
    /// can be tested directly.
    struct Candidate: Equatable {
        let name: String
        /// Primary muscle group only. Secondaries are ignored on purpose — a
        /// movement's *primary* is what makes it "the biceps slot", and matching
        /// on secondaries too would let a chest press fill a triceps slot.
        let primaryMuscle: String

        init(name: String, primaryMuscle: String) {
            self.name = name
            self.primaryMuscle = primaryMuscle
        }
    }

    /// Picks a replacement for one slot: a different movement whose primary
    /// muscle group matches the slot's.
    ///
    /// Selection runs in tiers, so variety never costs correctness:
    /// 1. A matching movement used nowhere else in the week — the ideal roll.
    /// 2. Failing that, any matching movement not already in *this day*, so a
    ///    day can never end up with the same exercise twice.
    /// 3. Failing that, `nil` — the caller keeps the current movement. A muscle
    ///    group with only one exercise in the library simply doesn't shuffle;
    ///    that is far better than dropping the slot or substituting the wrong
    ///    muscle to manufacture the appearance of change.
    ///
    /// - Parameters:
    ///   - primaryMuscle: The muscle group the slot must keep.
    ///   - current: The movement currently in the slot, never returned.
    ///   - candidates: Every movement in the library.
    ///   - usedInDay: Movements already placed in this day by this shuffle.
    ///   - usedInWeek: Movements used anywhere in the plan before this shuffle.
    ///   - randomizer: Injection point so tests can be deterministic.
    static func replacement(
        primaryMuscle: String,
        current: String,
        candidates: [Candidate],
        usedInDay: Set<String>,
        usedInWeek: Set<String>,
        randomizer: ([Candidate]) -> Candidate? = { $0.randomElement() }
    ) -> Candidate? {
        let currentKey = current.lowercased()
        let dayKeys = Set(usedInDay.map { $0.lowercased() })
        let weekKeys = Set(usedInWeek.map { $0.lowercased() })

        let sameMuscle = candidates.filter {
            $0.primaryMuscle.caseInsensitiveCompare(primaryMuscle) == .orderedSame
                && $0.name.lowercased() != currentKey
                && !dayKeys.contains($0.name.lowercased())
        }
        guard !sameMuscle.isEmpty else { return nil }

        let unusedThisWeek = sameMuscle.filter { !weekKeys.contains($0.name.lowercased()) }
        return randomizer(unusedThisWeek.isEmpty ? sameMuscle : unusedThisWeek)
    }

    /// Every movement name currently programmed across the plan. Taken week-wide
    /// so Wednesday's chest slot doesn't grab the bench press Monday just gave
    /// up, which would leave the week looking barely shuffled.
    @MainActor
    static func currentMovementNames(in plan: WeeklyPlan) -> Set<String> {
        Set(plan.days.flatMap { $0.routine?.exercises.map(\.name) ?? [] })
    }

    /// Re-rolls every training day in the plan, in place.
    ///
    /// Each day is mutated slot by slot rather than rebuilt, so a day whose
    /// muscle groups have no alternatives left is simply left alone instead of
    /// being emptied. Nothing is deleted at any point — unlike a rebuild, which
    /// clears the plan before it has anything to put back.
    ///
    /// - Returns: The number of slots that actually changed movement.
    @MainActor
    @discardableResult
    static func reroll(
        plan: WeeklyPlan,
        workout: WorkoutManager,
        exercises: [Exercise]
    ) -> Int {
        let candidates = exercises.map {
            Candidate(name: $0.name, primaryMuscle: $0.muscleGroup.rawValue)
        }
        let byName = Dictionary(exercises.map { ($0.name.lowercased(), $0) }) { first, _ in first }
        let usedInWeek = currentMovementNames(in: plan)

        var swapped = 0
        for day in plan.orderedDays {
            guard let routine = day.routine else { continue }
            var usedInDay: Set<String> = []

            for item in routine.orderedItems {
                guard let exercise = item.exercise else { continue }
                guard let pick = replacement(
                    primaryMuscle: exercise.muscleGroup.rawValue,
                    current: exercise.name,
                    candidates: candidates,
                    usedInDay: usedInDay,
                    usedInWeek: usedInWeek
                ), let replacement = byName[pick.name.lowercased()] else {
                    // No alternative for this muscle group — keep what's there,
                    // and still reserve it so a later slot can't duplicate it.
                    usedInDay.insert(exercise.name)
                    continue
                }
                workout.swapRoutineItemExercise(item, to: replacement)
                usedInDay.insert(replacement.name)
                swapped += 1
            }
        }

        if swapped > 0 { workout.markPlanShuffled(plan) }
        return swapped
    }
}

// MARK: - Shuffle controller

/// Drives shuffling for whichever Plan screen is on-screen (phone or iPad), so
/// both get identical behaviour from one implementation.
///
/// Also performs the automatic weekly roll: when "Shuffle every week" is on and
/// the calendar week has turned over since the last shuffle, opening the Plan
/// tab re-rolls the week once. There is no background scheduler on purpose — a
/// plan the lifter never opens doesn't need rebuilding, and a BGTaskScheduler
/// job would need an entitlement and burn battery for a result only ever seen
/// from this screen.
struct PlanShuffleModifier: ViewModifier {
    @Environment(WorkoutManager.self) private var workout
    @Query(sort: \Exercise.name) private var exercises: [Exercise]

    let plan: WeeklyPlan
    @Binding var trigger: Bool

    /// Identifies the current calendar week; changing it re-arms the automatic
    /// roll without needing a timer.
    private var weekKey: Date {
        Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? .distantPast
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: trigger) { _, newValue in
                guard newValue else { return }
                trigger = false
                run()
            }
            .task(id: weekKey) {
                guard plan.randomizeWeekly, plan.needsWeeklyShuffle() else { return }
                run()
            }
    }

    /// Swapping is local catalog selection plus the deterministic progression
    /// algorithm — no model call — so it completes in one frame and needs no
    /// progress overlay.
    private func run() {
        let swapped = PlanShuffle.reroll(plan: plan, workout: workout, exercises: exercises)
        if swapped > 0 { Haptics.shared.success() }
    }
}

extension View {
    /// Adds shuffle handling to a Plan screen. Set `trigger` to true to re-roll
    /// the week now; automatic weekly rolls happen on their own.
    func planShuffle(plan: WeeklyPlan, trigger: Binding<Bool>) -> some View {
        modifier(PlanShuffleModifier(plan: plan, trigger: trigger))
    }
}
