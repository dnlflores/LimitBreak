//
//  PlanShuffleTests.swift
//  LimitBreakTests
//
//  Covers the pure decision logic behind the weekly plan shuffle: which
//  movements the generator is allowed to see on a re-roll, and when an
//  automatic weekly roll is due. The generation itself is not tested here —
//  it goes through the AI tiers, which are exercised elsewhere.
//

import Foundation
import Testing
@testable import LimitBreak

struct PlanShuffleCatalogTests {

    private func brief(_ name: String, _ groups: [String]) -> ExerciseBrief {
        ExerciseBrief(name: name, muscleGroups: groups, equipment: "Barbell")
    }

    private var pushCatalog: [ExerciseBrief] {
        [
            brief("Bench Press", ["Chest", "Triceps"]),
            brief("Incline Press", ["Chest"]),
            brief("Dip", ["Chest", "Triceps"]),
            brief("Overhead Press", ["Deltoids"]),
            brief("Lateral Raise", ["Deltoids"]),
            brief("Cable Fly", ["Chest"]),
            brief("Skullcrusher", ["Triceps"]),
            brief("Back Squat", ["Quads"]),
        ]
    }

    @Test func excludesRecentlyUsedMovements() {
        let thinned = PlanShuffle.thinnedCatalog(
            pushCatalog,
            avoiding: ["Bench Press", "Dip"],
            targetMuscleGroups: ["Chest", "Deltoids", "Triceps"],
            minimumMatches: 4
        )
        let names = Set(thinned.map(\.name))
        #expect(!names.contains("Bench Press"))
        #expect(!names.contains("Dip"))
        #expect(names.contains("Incline Press"))
    }

    @Test func exclusionIsCaseInsensitive() {
        let thinned = PlanShuffle.thinnedCatalog(
            pushCatalog,
            avoiding: ["bench press"],
            targetMuscleGroups: ["Chest"],
            minimumMatches: 2
        )
        #expect(!thinned.contains { $0.name == "Bench Press" })
    }

    @Test func keepsFullCatalogWhenNothingToAvoid() {
        let thinned = PlanShuffle.thinnedCatalog(
            pushCatalog,
            avoiding: [],
            targetMuscleGroups: ["Chest"],
            minimumMatches: 99
        )
        #expect(thinned.count == pushCatalog.count)
    }

    /// The whole point of the guard: variety must never starve the workout. If
    /// avoiding last week would leave too few focus movements, the generator
    /// gets the full library back and may legitimately repeat.
    @Test func fallsBackToFullCatalogWhenTooFewMatchesRemain() {
        let thinned = PlanShuffle.thinnedCatalog(
            pushCatalog,
            avoiding: ["Bench Press", "Incline Press", "Dip", "Cable Fly"],
            targetMuscleGroups: ["Chest"],
            minimumMatches: 4
        )
        #expect(thinned.count == pushCatalog.count)
    }

    /// Full Body has no target muscles, so every surviving movement counts
    /// toward the minimum rather than zero of them.
    @Test func fullBodyCountsEveryRemainingMovement() {
        let thinned = PlanShuffle.thinnedCatalog(
            pushCatalog,
            avoiding: ["Bench Press"],
            targetMuscleGroups: [],
            minimumMatches: 6
        )
        #expect(thinned.count == pushCatalog.count - 1)
    }

    @Test func minimumScalesWithDayLength() {
        #expect(PlanShuffle.minimumMatches(exercisesPerDay: 5) == 10)
        // Short days still demand a floor, so a 3-exercise day keeps real choice.
        #expect(PlanShuffle.minimumMatches(exercisesPerDay: 2) == 6)
    }
}

struct WeeklyShuffleDueTests {

    private var calendar: Calendar { Calendar(identifier: .gregorian) }

    private func plan(lastShuffled: Date?) -> WeeklyPlan {
        let plan = WeeklyPlan(name: "Test Week")
        plan.days = [PlannedDay(weekday: 2), PlannedDay(weekday: 4)]
        plan.lastShuffledWeek = lastShuffled
        return plan
    }

    @Test func dueWhenNeverShuffled() {
        #expect(plan(lastShuffled: nil).needsWeeklyShuffle(now: Date(), calendar: calendar))
    }

    @Test func notDueTwiceInTheSameWeek() {
        let now = Date()
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        #expect(!plan(lastShuffled: weekStart).needsWeeklyShuffle(now: now, calendar: calendar))
    }

    @Test func dueOnceTheWeekTurnsOver() {
        let now = Date()
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        let lastWeek = calendar.date(byAdding: .day, value: -7, to: weekStart)!
        #expect(plan(lastShuffled: lastWeek).needsWeeklyShuffle(now: now, calendar: calendar))
    }

    /// An empty plan has nothing to re-roll; shuffling it would just spin the
    /// generator and overwrite nothing.
    @Test func emptyPlanIsNeverDue() {
        let empty = WeeklyPlan(name: "Empty")
        #expect(!empty.needsWeeklyShuffle(now: Date(), calendar: calendar))
    }

    @Test func randomizeIsOffByDefault() {
        #expect(WeeklyPlan(name: "Default").randomizeWeekly == false)
    }
}
