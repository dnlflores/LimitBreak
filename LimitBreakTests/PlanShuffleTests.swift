//
//  PlanShuffleTests.swift
//  LimitBreakTests
//
//  Covers the decision logic behind the weekly plan shuffle: which movement may
//  replace a given slot, and when an automatic weekly roll is due.
//
//  The guarantee under test is composition: a shuffled slot must come back with
//  the SAME primary muscle group, so a day built as one biceps / one triceps /
//  one chest movement stays exactly that after shuffling.
//

import Foundation
import Testing
@testable import LimitBreak

struct PlanShuffleSelectionTests {

    private func candidate(_ name: String, _ muscle: MuscleGroup) -> PlanShuffle.Candidate {
        PlanShuffle.Candidate(name: name, primaryMuscle: muscle.rawValue)
    }

    private var library: [PlanShuffle.Candidate] {
        [
            candidate("Barbell Curl", .biceps),
            candidate("Hammer Curl", .biceps),
            candidate("Preacher Curl", .biceps),
            candidate("Skullcrusher", .triceps),
            candidate("Triceps Pushdown", .triceps),
            candidate("Bench Press", .chest),
            candidate("Incline Press", .chest),
            candidate("Lateral Raise", .deltoids),
            candidate("Back Squat", .quads),
        ]
    }

    /// The core contract Daniel asked for: a biceps slot comes back biceps.
    @Test func replacementKeepsThePrimaryMuscleGroup() {
        let pick = PlanShuffle.replacement(
            primaryMuscle: MuscleGroup.biceps.rawValue,
            current: "Barbell Curl",
            candidates: library,
            usedInDay: [],
            usedInWeek: []
        )
        #expect(pick != nil)
        #expect(pick?.primaryMuscle == MuscleGroup.biceps.rawValue)
    }

    @Test func replacementIsNeverTheCurrentMovement() {
        // Triceps has exactly two entries, so repeated rolls must all return the
        // other one — never the movement already in the slot.
        for _ in 0..<25 {
            let pick = PlanShuffle.replacement(
                primaryMuscle: MuscleGroup.triceps.rawValue,
                current: "Skullcrusher",
                candidates: library,
                usedInDay: [],
                usedInWeek: []
            )
            #expect(pick?.name == "Triceps Pushdown")
        }
    }

    /// A day must never end up with the same movement in two slots.
    @Test func replacementAvoidsMovementsAlreadyPlacedInTheDay() {
        let pick = PlanShuffle.replacement(
            primaryMuscle: MuscleGroup.biceps.rawValue,
            current: "Barbell Curl",
            candidates: library,
            usedInDay: ["Hammer Curl"],
            usedInWeek: []
        )
        #expect(pick?.name == "Preacher Curl")
    }

    /// Preferring movements unused elsewhere in the week keeps the whole plan
    /// looking shuffled rather than rotating two exercises between days.
    @Test func prefersMovementsNotUsedElsewhereInTheWeek() {
        for _ in 0..<25 {
            let pick = PlanShuffle.replacement(
                primaryMuscle: MuscleGroup.biceps.rawValue,
                current: "Barbell Curl",
                candidates: library,
                usedInDay: [],
                usedInWeek: ["Hammer Curl"]
            )
            #expect(pick?.name == "Preacher Curl")
        }
    }

    /// When every same-muscle option is already used somewhere in the week, the
    /// slot still shuffles rather than freezing — week-wide novelty is a
    /// preference, not a hard constraint.
    @Test func fallsBackToUsedMovementsWhenTheWeekIsExhausted() {
        let pick = PlanShuffle.replacement(
            primaryMuscle: MuscleGroup.biceps.rawValue,
            current: "Barbell Curl",
            candidates: library,
            usedInDay: [],
            usedInWeek: ["Hammer Curl", "Preacher Curl"]
        )
        #expect(pick != nil)
        #expect(pick?.primaryMuscle == MuscleGroup.biceps.rawValue)
    }

    /// A muscle group with only one movement in the library keeps that movement.
    /// Substituting a different muscle to manufacture visible change would break
    /// the day's composition — the whole point of the feature.
    @Test func returnsNilRatherThanSubstituteADifferentMuscle() {
        let pick = PlanShuffle.replacement(
            primaryMuscle: MuscleGroup.deltoids.rawValue,
            current: "Lateral Raise",
            candidates: library,
            usedInDay: [],
            usedInWeek: []
        )
        #expect(pick == nil)
    }

    @Test func muscleMatchingIsCaseInsensitive() {
        let pick = PlanShuffle.replacement(
            primaryMuscle: MuscleGroup.chest.rawValue.uppercased(),
            current: "Bench Press",
            candidates: library,
            usedInDay: [],
            usedInWeek: []
        )
        #expect(pick?.name == "Incline Press")
    }

    /// Simulates shuffling a full day and asserts the muscle-group multiset is
    /// unchanged — the exact scenario from the review: 1 each of biceps,
    /// triceps, chest, back-ish and shoulders comes back 1 each.
    @Test func shufflingAWholeDayPreservesItsMuscleComposition() {
        let day: [(name: String, muscle: MuscleGroup)] = [
            ("Barbell Curl", .biceps),
            ("Skullcrusher", .triceps),
            ("Bench Press", .chest),
            ("Lateral Raise", .deltoids),
            ("Back Squat", .quads),
        ]

        var used: Set<String> = []
        var resulting: [MuscleGroup] = []
        for slot in day {
            let pick = PlanShuffle.replacement(
                primaryMuscle: slot.muscle.rawValue,
                current: slot.name,
                candidates: library,
                usedInDay: used,
                usedInWeek: []
            )
            // Nil means "keep what's there", which also preserves the muscle.
            used.insert(pick?.name ?? slot.name)
            resulting.append(slot.muscle)
            if let pick {
                #expect(pick.primaryMuscle == slot.muscle.rawValue)
            }
        }

        #expect(resulting.count == day.count)
        #expect(Set(resulting) == Set(day.map(\.muscle)))
        // No duplicated movements within the day.
        #expect(used.count == day.count)
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

    /// An empty plan has no slots to swap; rolling it would do nothing.
    @Test func emptyPlanIsNeverDue() {
        let empty = WeeklyPlan(name: "Empty")
        #expect(!empty.needsWeeklyShuffle(now: Date(), calendar: calendar))
    }

    @Test func randomizeIsOffByDefault() {
        #expect(WeeklyPlan(name: "Default").randomizeWeekly == false)
    }
}
