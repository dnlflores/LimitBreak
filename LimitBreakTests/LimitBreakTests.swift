//
//  LimitBreakTests.swift
//  LimitBreakTests
//

import Foundation
import Testing
import SwiftData
@testable import LimitBreak

struct FormulaTests {

    @Test func epleyMatchesSpec() {
        // 1RM = w * (1 + r/30)
        #expect(OneRMFormula.epley.estimate(weight: 225, reps: 5) == 225 * (1 + 5.0 / 30.0))
        #expect(OneRMFormula.epley.estimate(weight: 315, reps: 1) == 315)
        #expect(OneRMFormula.epley.estimate(weight: 100, reps: 0) == 0)
    }

    @Test func brzycki() {
        #expect(abs(OneRMFormula.brzycki.estimate(weight: 200, reps: 5) - 200 * 36 / 32) < 0.001)
        #expect(OneRMFormula.brzycki.estimate(weight: 200, reps: 1) == 200)
    }

    @Test func rawMaxIgnoresReps() {
        #expect(OneRMFormula.rawMax.estimate(weight: 185, reps: 12) == 185)
    }
}

struct XPEngineTests {

    @Test func levelCurveClimbs() {
        // Level 1 → 2 costs 150; below that you're still level 1.
        #expect(XPEngine.levelInfo(totalXP: 0).level == 1)
        #expect(XPEngine.levelInfo(totalXP: 149).level == 1)
        #expect(XPEngine.levelInfo(totalXP: 150).level == 2)

        // 150 + 200 = 350 total reaches level 3, starting it with 0 into-level XP.
        let info = XPEngine.levelInfo(totalXP: 350)
        #expect(info.level == 3)
        #expect(info.xpIntoLevel == 0)
        #expect(info.xpForNext == 250)
    }

    @Test func ranksProgress() {
        #expect(XPEngine.rankTitle(for: 1) == "Novice")
        #expect(XPEngine.rankTitle(for: 12) == "Warrior")
        #expect(XPEngine.rankTitle(for: 50) == "Raid Boss")
    }

    @Test func nextRankLooksAhead() {
        let next = XPEngine.nextRank(after: 1)
        #expect(next?.title == "Squire")
        #expect(next?.level == 3)
        #expect(XPEngine.nextRank(after: 50) == nil) // already Raid Boss
    }

    @Test func activityXPScalesWithTime() {
        // +10 for showing up, +1 per 2 minutes.
        // Parity with lifting: ~450/hour, like a solid session's set + volume XP.
        #expect(XPEngine.xpForActivity(minutes: 60) == 445)
        #expect(XPEngine.xpForActivity(minutes: 0) == 25)
        #expect(XPEngine.xpForActivity(minutes: 120) == 865)
    }

    @Test func streakMultiplierClimbsWeekly() {
        #expect(XPEngine.multiplier(forStreakDay: 1) == 1)
        #expect(XPEngine.multiplier(forStreakDay: 6) == 1)
        #expect(XPEngine.multiplier(forStreakDay: 7) == 2)   // one full week -> 2x
        #expect(XPEngine.multiplier(forStreakDay: 13) == 2)
        #expect(XPEngine.multiplier(forStreakDay: 14) == 3)  // two weeks -> 3x
    }

    @Test @MainActor func sevenDayStreakDoublesDaySevenXP() throws {
        let schema = Schema([Exercise.self, WorkoutSession.self, ExerciseSet.self, PRRecord.self, Walk.self, Activity.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // Seven consecutive daily sessions ending today; no sets, so each is
        // worth the flat 25 XP before multipliers.
        for offset in (0..<7).reversed() {
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            let session = WorkoutSession(name: "Day", startDate: day.addingTimeInterval(3600))
            container.mainContext.insert(session)
        }
        let sessions = try container.mainContext.fetch(FetchDescriptor<WorkoutSession>())

        let progress = XPEngine.progress(sessions: sessions, walks: [])
        // Days 1-6 pay 25 each; day 7 hits the 2x multiplier and pays 50.
        #expect(progress.totalXP == 6 * 25 + 50)
        #expect(progress.currentStreak == 7)
        #expect(progress.currentMultiplier == 2)
    }

    @Test @MainActor func idleDecayDocksAndCanDropLevels() throws {
        let schema = Schema([Exercise.self, WorkoutSession.self, ExerciseSet.self, PRRecord.self, Walk.self, Activity.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // One session 10 days ago (25 XP), then silence: 9 idle days, the
        // first 2 free, so 7 x 10 = 70 docked — clamped at zero, no negatives.
        let day = calendar.date(byAdding: .day, value: -10, to: today)!
        let session = WorkoutSession(name: "Lone", startDate: day.addingTimeInterval(3600))
        container.mainContext.insert(session)
        let sessions = try container.mainContext.fetch(FetchDescriptor<WorkoutSession>())

        let progress = XPEngine.progress(sessions: sessions, walks: [])
        #expect(progress.totalXP == 0)
        #expect(progress.weeklyXP < 0) // the docked week reads negative
        #expect(XPEngine.levelInfo(totalXP: progress.totalXP).level == 1)
        #expect(progress.currentStreak == 0)
    }

    @Test @MainActor func timelineMarksLevelUps() throws {
        let schema = Schema([Exercise.self, WorkoutSession.self, ExerciseSet.self, PRRecord.self, Walk.self, Activity.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let manager = WorkoutManager(context: container.mainContext)
        let bench = Exercise(name: "Bench", muscleGroup: "Chest")
        container.mainContext.insert(bench)

        // Two heavy past sessions push total XP well past the first threshold (150).
        let entries: [(exercise: Exercise, supersetGroup: Int?, sets: [PastSetEntry])] = [
            (bench, nil, (0..<5).map { _ in PastSetEntry(weight: 200, reps: 5) })
        ]
        manager.logPastSession(name: "Day 1", date: Date().addingTimeInterval(-172_800), entries: entries)
        manager.logPastSession(name: "Day 2", date: Date().addingTimeInterval(-86_400), entries: entries)

        let sessions = try container.mainContext.fetch(FetchDescriptor<WorkoutSession>())
        let records = try container.mainContext.fetch(FetchDescriptor<PRRecord>())
        let timeline = XPEngine.timeline(sessions: sessions, records: records, walks: [], activities: [])

        let levelUps = timeline.flatMap(\.events).filter(\.isLevelUp)
        #expect(!levelUps.isEmpty)
        #expect(levelUps.allSatisfy { ($0.levelReached ?? 0) > 1 })
    }
}

struct TrainingProfileTests {

    /// Every goal and experience level carries a brief — they're interpolated
    /// straight into the request, so an empty one would silently produce an
    /// unguided plan.
    @Test func everyGoalAndLevelHasCoachingText() {
        for goal in TrainingGoal.allCases {
            #expect(!goal.coachingBrief.isEmpty, "\(goal.rawValue) has no coaching brief")
            #expect(!goal.blurb.isEmpty)
        }
        for level in ExperienceLevel.allCases {
            #expect(!level.coachingBrief.isEmpty, "\(level.rawValue) has no coaching brief")
            #expect(!level.blurb.isEmpty)
        }
    }

    /// The profile is a singleton — repeated access must not accumulate rows.
    @Test @MainActor func currentCreatesExactlyOneProfile() throws {
        let schema = Schema([Exercise.self, WorkoutSession.self, ExerciseSet.self, PRRecord.self,
                             Walk.self, Activity.self, TrainingProfile.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )

        let first = TrainingProfile.current(in: container.mainContext)
        let second = TrainingProfile.current(in: container.mainContext)
        #expect(first.id == second.id)

        let all = try container.mainContext.fetch(FetchDescriptor<TrainingProfile>())
        #expect(all.count == 1)

        // Defaults are safe: cloud off until explicitly enabled.
        #expect(first.cloudAIEnabled == false)
        #expect(first.hasCompletedOnboarding == false)
        withExtendedLifetime(container) {}
    }

    /// An API key is never rendered in full.
    @Test func maskedKeyHidesTheSecret() {
        let key = "sk-ant-api03-SECRETMATERIAL9876"
        let masked = key.maskedAPIKey
        #expect(masked.hasPrefix("sk-ant-"))
        #expect(masked.hasSuffix("9876"))
        #expect(!masked.contains("SECRETMATERIAL"))
    }
}

struct TrainingContextTests {

    @Test @MainActor func buildSummarizesFatigueHistoryAndCeilings() throws {
        let schema = Schema([Exercise.self, WorkoutSession.self, ExerciseSet.self, PRRecord.self,
                             Walk.self, Activity.self, TrainingProfile.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let now = Date()

        let bench = Exercise(name: "Bench Press", muscleGroup: "Chest", secondaryMuscles: ["Triceps"])
        let row = Exercise(name: "Barbell Row", muscleGroup: "Lats")
        [bench, row].forEach(context.insert)

        // A chest session yesterday — recent enough to still be recovering.
        let session = WorkoutSession(name: "Push Day", startDate: now.addingTimeInterval(-86_400))
        context.insert(session)
        let set = ExerciseSet(weight: 185, reps: 5, timestamp: now.addingTimeInterval(-86_400))
        set.exercise = bench
        set.session = session
        context.insert(set)

        let record = PRRecord(recordType: "1RM", numericValue: 225, repsAchieved: 1, exercise: bench)
        context.insert(record)
        try context.save()

        let profile = TrainingProfile(goal: .getStronger, experience: .advanced, daysPerWeek: 5)
        let built = TrainingContext.build(
            profile: profile,
            sessions: [session],
            exercises: [bench, row],
            withPartner: true,
            now: now
        )

        #expect(built.goal == .getStronger)
        #expect(built.experience == .advanced)
        #expect(built.daysPerWeek == 5)
        #expect(built.withPartner)

        // Chest was trained yesterday; lats never were.
        #expect(built.muscleStatuses[.chest]?.state(now: now) == .recovering)
        #expect(built.muscleStatuses[.lats]?.state(now: now) == .dormant)

        #expect(built.recentSessions.count == 1)
        #expect(built.recentSessions.first?.name == "Push Day")
        #expect(built.recentSessions.first?.daysAgo == 1)
        #expect(built.recentSessions.first?.workingSets == 1)

        // Only movements with a recorded ceiling are worth sending.
        #expect(built.ceilings["Bench Press"] == 225)
        #expect(built.ceilings["Barbell Row"] == nil)
        withExtendedLifetime(container) {}
    }

    /// History and ceilings are unbounded in the store but capped in the
    /// request — otherwise the prompt grows without limit as the log fills up.
    @Test @MainActor func buildCapsHistoryAndCeilings() throws {
        let schema = Schema([Exercise.self, WorkoutSession.self, ExerciseSet.self, PRRecord.self,
                             Walk.self, Activity.self, TrainingProfile.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let store = container.mainContext
        let now = Date()

        let sessions = (1...30).map { index -> WorkoutSession in
            let session = WorkoutSession(
                name: "Session \(index)",
                startDate: now.addingTimeInterval(-Double(index) * 86_400)
            )
            store.insert(session)
            return session
        }

        let exercises = (1...60).map { index -> Exercise in
            let exercise = Exercise(name: "Move \(index)", muscleGroup: "Chest")
            store.insert(exercise)
            let record = PRRecord(
                recordType: "1RM",
                numericValue: Double(index) * 10,
                repsAchieved: 1,
                exercise: exercise
            )
            store.insert(record)
            return exercise
        }
        try store.save()

        let built = TrainingContext.build(
            profile: TrainingProfile(),
            sessions: sessions,
            exercises: exercises,
            withPartner: false,
            now: now
        )

        #expect(built.recentSessions.count == TrainingContext.recentSessionLimit)
        #expect(built.ceilings.count == TrainingContext.ceilingLimit)
        // Newest session first, and the heaviest ceilings are the ones kept.
        #expect(built.recentSessions.first?.name == "Session 1")
        #expect(built.ceilings["Move 60"] == 600)
        #expect(built.ceilings["Move 1"] == nil)
        withExtendedLifetime(container) {}
    }
}

struct CoachedPlanMappingTests {

    private func brief(_ name: String) -> ExerciseBrief {
        ExerciseBrief(name: name, muscleGroups: ["Chest"], equipment: "Barbell")
    }

    private func coached(_ exercises: [CoachedExercise], title: String = "Iron Ascent") -> CoachedPlan {
        let json: [String: Any] = [
            "title": title,
            "rationale": "Chest is fresh; legs need another day.",
            "exercises": exercises.map { entry in
                [
                    "name": entry.name, "sets": entry.sets,
                    "repRangeLow": entry.repRangeLow, "repRangeHigh": entry.repRangeHigh,
                    "targetLoadPounds": entry.targetLoadPounds,
                    "restSeconds": entry.restSeconds, "note": entry.note,
                ] as [String: Any]
            },
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(CoachedPlan.self, from: data)
    }

    private func exercise(
        _ name: String, sets: Int = 3, low: Int = 6, high: Int = 10,
        load: Double = 185, rest: Int = 120
    ) -> CoachedExercise {
        let json: [String: Any] = [
            "name": name, "sets": sets, "repRangeLow": low, "repRangeHigh": high,
            "targetLoadPounds": load, "restSeconds": rest, "note": "Primary press.",
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(CoachedExercise.self, from: data)
    }

    /// A valid plan maps straight through and is tagged as cloud-sourced.
    @Test func validPlanMapsToCatalogNames() {
        let plan = WorkoutAI.matchToCatalog(
            coached([exercise("bench press")]),                 // lowercase from the model
            catalog: [brief("Bench Press")],
            limit: 5
        )
        let mapped = try! #require(plan)
        #expect(mapped.source == .cloud)
        #expect(mapped.rationale?.isEmpty == false)
        #expect(mapped.exercises.map(\.name) == ["Bench Press"])  // canonical casing restored
        #expect(mapped.exercises.first?.prescription?.repRangeText == "6-10")
    }

    /// Movements the model invented are dropped rather than surfaced.
    @Test func hallucinatedMovementsAreDropped() {
        let plan = WorkoutAI.matchToCatalog(
            coached([exercise("Bench Press"), exercise("Quantum Thruster")]),
            catalog: [brief("Bench Press")],
            limit: 5
        )
        #expect(plan?.exercises.map(\.name) == ["Bench Press"])
    }

    /// A plan of nothing but hallucinations yields nil, so the caller falls
    /// through to the on-device tier instead of showing an empty plan.
    @Test func allHallucinatedYieldsNil() {
        let plan = WorkoutAI.matchToCatalog(
            coached([exercise("Quantum Thruster")]),
            catalog: [brief("Bench Press")],
            limit: 5
        )
        #expect(plan == nil)
    }

    @Test func duplicatesAreCollapsedAndLimitRespected() {
        let plan = WorkoutAI.matchToCatalog(
            coached([exercise("Bench Press"), exercise("Bench Press"), exercise("Incline Press")]),
            catalog: [brief("Bench Press"), brief("Incline Press")],
            limit: 1
        )
        #expect(plan?.exercises.count == 1)
    }

    /// JSON Schema can't express numeric bounds, so out-of-range values have to
    /// be clamped after decoding rather than trusted.
    @Test func outOfRangeValuesAreClamped() {
        let plan = WorkoutAI.matchToCatalog(
            coached([exercise("Bench Press", sets: 99, low: 12, high: 4, load: -50, rest: 9999)]),
            catalog: [brief("Bench Press")],
            limit: 5
        )
        let rx = try! #require(plan?.exercises.first?.prescription)
        #expect(plan?.exercises.first?.sets == 8)      // capped
        #expect(rx.repRangeLow == 4)                    // reversed range corrected
        #expect(rx.repRangeHigh == 12)
        #expect(rx.targetLoadPounds == 0)               // negative load floored
        #expect(rx.restSeconds == 600)                  // capped
    }
}

struct ExerciseReorderTests {

    /// Runs `body` against a fresh in-memory store. The container is held for the
    /// duration of the call — handing back a bare `ModelContext` would let the
    /// container deallocate and leave the context dangling.
    @MainActor
    private func withManager(_ body: (WorkoutManager, ModelContext) throws -> Void) throws {
        let schema = Schema([Exercise.self, WorkoutSession.self, ExerciseSet.self, PRRecord.self, Walk.self, Activity.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let manager = WorkoutManager(context: container.mainContext)
        try body(manager, container.mainContext)
        // No rest timer may outlive the store it would write back into.
        manager.stopRest()
        withExtendedLifetime(container) {}
    }

    /// Reordering rewrites the running order without disturbing logged sets,
    /// per-exercise targets, or which exercise is up next.
    @Test @MainActor func reorderKeepsSetsAndTargetsWithTheirExercise() throws {
        try withManager { manager, context in
            let bench = Exercise(name: "Bench", muscleGroup: "Chest", defaultRestSeconds: 0)
            let row = Exercise(name: "Row", muscleGroup: "Lats", defaultRestSeconds: 0)
            let curl = Exercise(name: "Curl", muscleGroup: "Biceps", defaultRestSeconds: 0)
            [bench, row, curl].forEach(context.insert)

            manager.startSession(named: "Order Test", exercises: [bench, row, curl],
                                 targets: [bench.id: 2, row.id: 4, curl.id: 3])
            manager.logSet(exercise: row, weight: 135, reps: 8)

            manager.reorderExercises(to: [curl, row, bench])

            #expect(manager.sessionExercises.map(\.name) == ["Curl", "Row", "Bench"])
            // The logged set and the target follow the movement, not the slot.
            #expect(manager.sets(for: row).count == 1)
            #expect(manager.targetSets(for: row) == 4)
            #expect(manager.targetSets(for: bench) == 2)
            // Curl is now first with nothing logged, so it's what LOG SET works on.
            #expect(manager.currentExercise?.name == "Curl")
        }
    }

    /// A reorder that doesn't account for every exercise is refused rather than
    /// silently dropping one from the session.
    @Test @MainActor func reorderRejectsMismatchedCounts() throws {
        try withManager { manager, context in
            let bench = Exercise(name: "Bench", muscleGroup: "Chest", defaultRestSeconds: 0)
            let row = Exercise(name: "Row", muscleGroup: "Lats", defaultRestSeconds: 0)
            [bench, row].forEach(context.insert)

            manager.startSession(named: "Order Test", exercises: [bench, row])
            manager.reorderExercises(to: [row])

            #expect(manager.sessionExercises.map(\.name) == ["Bench", "Row"])
        }
    }

    /// Skips are tracked per exercise, so they survive a reorder too.
    @Test @MainActor func reorderPreservesSkips() throws {
        try withManager { manager, context in
            let bench = Exercise(name: "Bench", muscleGroup: "Chest", defaultRestSeconds: 0)
            let row = Exercise(name: "Row", muscleGroup: "Lats", defaultRestSeconds: 0)
            [bench, row].forEach(context.insert)

            manager.startSession(named: "Order Test", exercises: [bench, row])
            manager.advanceToNextExercise() // skips Bench
            #expect(manager.currentExercise?.name == "Row")

            manager.reorderExercises(to: [row, bench])
            #expect(manager.skippedExercises.contains(bench.id))
            #expect(manager.currentExercise?.name == "Row")
        }
    }
}

struct MuscleNamingTests {

    /// Back and Shoulders are what the user sees; Lats and Deltoids stay the
    /// stored identity so no history or catalog data has to migrate.
    @Test func gymNamesShowWithoutChangingStoredValues() {
        #expect(MuscleGroup.lats.displayName == "Back")
        #expect(MuscleGroup.deltoids.displayName == "Shoulders")
        #expect(MuscleGroup.lats.rawValue == "Lats")
        #expect(MuscleGroup.deltoids.rawValue == "Deltoids")

        // Every other group is unchanged.
        for group in MuscleGroup.allCases where group != .lats && group != .deltoids {
            #expect(group.displayName == group.rawValue)
        }
    }

    /// Traps is its own group, named the same in storage and on screen.
    @Test func trapsIsAFirstClassGroup() {
        let traps = MuscleGroup(rawValue: "Traps")
        #expect(traps == .traps)
        #expect(MuscleGroup.traps.displayName == "Traps")
        #expect(MuscleGroup.allCases.contains(.traps))

        // Separate from Back — a shrug shouldn't read as a lat movement.
        #expect(MuscleGroup.traps != MuscleGroup.lats)
    }

    /// Back-ish focus presets reach traps, or shrugs would be unreachable
    /// through the AI generator.
    @Test func backFocusesIncludeTraps() {
        #expect(WorkoutFocus.back.targetMuscleGroups.contains("Traps"))
        #expect(WorkoutFocus.pull.targetMuscleGroups.contains("Traps"))
        #expect(WorkoutFocus.upper.targetMuscleGroups.contains("Traps"))
    }

    /// An exercise surfaces the display name while still filtering on the raw one.
    @Test func exerciseExposesDisplayNames() {
        let row = Exercise(
            name: "Barbell Row",
            muscleGroup: "Lats",
            secondaryMuscles: ["Biceps", "Deltoids"]
        )
        #expect(row.muscleGroupDisplay == "Back")
        #expect(row.muscleGroupRaw == "Lats")
        #expect(row.secondaryMuscleDisplayNames == ["Biceps", "Shoulders"])
    }

    /// The AI focus presets still target stored raw values — a display name
    /// here would silently match nothing in the catalog.
    @Test func focusPresetsTargetRawValues() {
        let valid = Set(MuscleGroup.allCases.map(\.rawValue))
        for focus in WorkoutFocus.allCases {
            for target in focus.targetMuscleGroups {
                #expect(valid.contains(target), "\(focus.label) targets unknown group \(target)")
            }
        }
        #expect(WorkoutFocus.back.targetMuscleGroups == ["Lats", "Traps"])
        #expect(WorkoutFocus.shoulders.targetMuscleGroups == ["Deltoids"])
    }
}

struct ActivityStreakTests {

    /// A sport-only day is a trained day: it sustains the streak with no
    /// session and no walk involved.
    @Test func activitiesAloneSustainAStreak() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let activities = (0..<4).map { offset in
            Activity(
                sport: .basketball,
                date: calendar.date(byAdding: .day, value: -offset, to: today)!.addingTimeInterval(3600),
                durationMinutes: 60
            )
        }

        let streak = XPEngine.currentStreak(sessions: [], walks: [], activities: activities)
        #expect(streak == 4)
    }

    /// Sports, lifts and walks chain into one another — the streak doesn't care
    /// which kind of day it was.
    @Test func mixedDayTypesChainIntoOneStreak() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func day(_ offset: Int) -> Date {
            calendar.date(byAdding: .day, value: -offset, to: today)!.addingTimeInterval(3600)
        }

        let session = WorkoutSession(name: "Lift", startDate: day(0))
        let activity = Activity(sport: .volleyball, date: day(1), durationMinutes: 90)
        let walk = Walk(date: day(2), durationSeconds: 1800, distanceMeters: 3200) // ~2 mi

        let streak = XPEngine.currentStreak(sessions: [session], walks: [walk], activities: [activity])
        #expect(streak == 3)
    }

    /// Activity XP lands in the replayed ledger and earns the streak multiplier
    /// like anything else.
    @Test func activityXPFlowsThroughProgress() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let activity = Activity(
            sport: .basketball,
            date: calendar.date(byAdding: .day, value: -1, to: today)!.addingTimeInterval(3600),
            durationMinutes: 60
        )

        let progress = XPEngine.progress(sessions: [], walks: [], activities: [activity])
        #expect(progress.totalXP == XPEngine.xpForActivity(minutes: 60))
        #expect(progress.currentStreak == 1)

        // And it shows up as its own reward, not folded into something else.
        let rewards = XPEngine.allRewards(sessions: [], records: [], walks: [], activities: [activity])
        #expect(rewards.count == 1)
        #expect(rewards.first?.title == "Basketball")
    }
}

struct TrainingPartnerTests {

    /// A spot only buys you weight on free-weight lifts that can pin you.
    @Test func onlyFreeWeightLiftsBenefitFromASpotter() {
        let bench = Exercise(name: "Bench Press", muscleGroup: "Chest", equipmentType: "Barbell")
        let dbPress = Exercise(name: "DB Press", muscleGroup: "Chest", equipmentType: "Dumbbell")
        let safetyBar = Exercise(name: "SSB Squat", muscleGroup: "Quads", equipmentType: "Specialty Bar")
        #expect(bench.benefitsFromSpotter)
        #expect(dbPress.benefitsFromSpotter)
        #expect(safetyBar.benefitsFromSpotter)

        // Machines, cables and bands have their own bail-out — a partner changes nothing.
        let machine = Exercise(name: "Leg Press", muscleGroup: "Quads", equipmentType: "Machine")
        let cable = Exercise(name: "Cable Fly", muscleGroup: "Chest", equipmentType: "Cable")
        let band = Exercise(name: "Band Pull", muscleGroup: "Lats", equipmentType: "Resistance Band")
        #expect(!machine.benefitsFromSpotter)
        #expect(!cable.benefitsFromSpotter)
        #expect(!band.benefitsFromSpotter)
    }

    /// Bodyweight and duration work never qualify, even on a barbell rack.
    @Test func nonWeightTrackingNeverQualifies() {
        let pullup = Exercise(
            name: "Pull-Up",
            muscleGroup: "Lats",
            trackingType: .bodyweightAndReps,
            equipmentType: "Barbell"
        )
        let plank = Exercise(
            name: "Plank",
            muscleGroup: "Core",
            trackingType: .durationAndReps,
            equipmentType: "Barbell"
        )
        #expect(!pullup.benefitsFromSpotter)
        #expect(!plank.benefitsFromSpotter)
    }

    /// The spotted load rounds to the movement's own increment and always
    /// clears the starting weight by at least one increment.
    @Test func spottedLoadBumpsAndSnapsToIncrement() {
        let bench = Exercise(name: "Bench Press", muscleGroup: "Chest", equipmentType: "Barbell", defaultIncrement: 5)
        // 225 * 1.05 = 236.25 → snaps to 235, which clears 225 by more than one increment.
        #expect(bench.spottedLoad(fromPounds: 225) == 235)

        // 100 * 1.05 = 105 → exactly one increment up.
        #expect(bench.spottedLoad(fromPounds: 100) == 105)

        // Light loads: 5% rounds to nothing, so the floor of +1 increment applies.
        #expect(bench.spottedLoad(fromPounds: 45) == 50)
    }

    /// Movements a spot doesn't help — and non-positive loads — pass through.
    @Test func spottedLoadLeavesUnspottableMovementsAlone() {
        let machine = Exercise(name: "Leg Press", muscleGroup: "Quads", equipmentType: "Machine", defaultIncrement: 10)
        #expect(machine.spottedLoad(fromPounds: 300) == 300)

        let bench = Exercise(name: "Bench Press", muscleGroup: "Chest", equipmentType: "Barbell")
        #expect(bench.spottedLoad(fromPounds: 0) == 0)
    }

    /// Sessions default to solo, and the flag survives a round trip through the store.
    @Test @MainActor func sessionsRecordPartnerStatus() throws {
        let schema = Schema([Exercise.self, WorkoutSession.self, ExerciseSet.self, PRRecord.self, Walk.self, Activity.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let manager = WorkoutManager(context: container.mainContext)

        manager.startSession(named: "Solo Run")
        #expect(manager.isTrainingWithPartner == false)

        // A partner turning up mid-session is recorded on the live session.
        manager.setTrainingWithPartner(true)
        #expect(manager.isTrainingWithPartner)
        #expect(manager.activeSession?.trainedWithPartner == true)
        manager.endSession()

        manager.startSession(named: "Spotted Run", withPartner: true)
        #expect(manager.activeSession?.trainedWithPartner == true)
        manager.endSession()

        let sessions = try container.mainContext.fetch(FetchDescriptor<WorkoutSession>())
        #expect(sessions.count == 2)
        #expect(sessions.allSatisfy { $0.trainedWithPartner })
    }

    /// Retroactive logging and edits carry the flag too.
    @Test @MainActor func pastSessionsAndEditsCarryPartnerStatus() throws {
        let schema = Schema([Exercise.self, WorkoutSession.self, ExerciseSet.self, PRRecord.self, Walk.self, Activity.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let manager = WorkoutManager(context: container.mainContext)
        let bench = Exercise(name: "Bench", muscleGroup: "Chest")
        container.mainContext.insert(bench)

        let entries: [(exercise: Exercise, supersetGroup: Int?, sets: [PastSetEntry])] = [
            (bench, nil, [PastSetEntry(weight: 185, reps: 5)])
        ]
        manager.logPastSession(
            name: "Spotted",
            date: Date().addingTimeInterval(-86_400),
            withPartner: true,
            entries: entries
        )

        let session = try #require(
            try container.mainContext.fetch(FetchDescriptor<WorkoutSession>()).first
        )
        #expect(session.trainedWithPartner)

        // Editing it back to solo sticks.
        manager.updateSession(
            session,
            name: session.name,
            date: session.startDate,
            withPartner: false,
            entries: entries
        )
        #expect(session.trainedWithPartner == false)
    }
}

struct CatalogGuideTests {

    /// The bundled library is big, unique, and enum-valid.
    @Test func bundledCatalogIsLargeAndValid() {
        let entries = ExerciseCatalog.entries
        #expect(entries.count >= 150)

        let names = entries.map(\.name)
        #expect(Set(names).count == names.count)

        // Seeding matches on lowercased name, so a case-only collision would
        // silently drop a movement instead of adding it.
        #expect(Set(names.map { $0.lowercased() }).count == names.count)

        for entry in entries {
            #expect(MuscleGroup(rawValue: entry.muscle) != nil)
            #expect(entry.tracking.map { TrackingType(rawValue: $0) != nil } ?? true)
            #expect(entry.formula.map { OneRMFormula(rawValue: $0) != nil } ?? true)
            #expect(entry.equipment.map { EquipmentType(rawValue: $0) != nil } ?? true)
            #expect(entry.secondary?.allSatisfy { MuscleGroup(rawValue: $0) != nil } ?? true)
            #expect(!entry.desc.isEmpty && entry.steps.count >= 3)
        }
    }

    /// The press patterns a lifter expects to find under every implement —
    /// incline and decline shouldn't be barbell-and-dumbbell only.
    @Test func pressPatternsCoverEachImplement() {
        let byName = Dictionary(
            ExerciseCatalog.entries.map { ($0.name.lowercased(), $0.equipment ?? "Barbell") }
        ) { first, _ in first }

        func equipment(_ name: String) -> String? { byName[name.lowercased()] }

        #expect(equipment("Incline Barbell Press") == "Barbell")
        #expect(equipment("Incline Dumbbell Press") == "Dumbbell")
        #expect(equipment("Incline Machine Press") == "Machine")

        #expect(equipment("Decline Barbell Press") == "Barbell")
        #expect(equipment("Decline Dumbbell Press") == "Dumbbell")
        #expect(equipment("Decline Machine Press") == "Machine")
    }

    /// Every muscle group can be trained with real variety, and no group is a
    /// single-implement dead end.
    @Test func everyMuscleHasVariedEquipmentOptions() {
        let entries = ExerciseCatalog.entries
        for group in MuscleGroup.allCases {
            let matching = entries.filter { $0.muscle == group.rawValue }
            #expect(matching.count >= 10, "\(group.displayName) has only \(matching.count) movements")

            let implements = Set(matching.map { $0.equipment ?? "Barbell" })
            #expect(implements.count >= 3, "\(group.displayName) only offers \(implements)")
        }
    }

    /// Seeding twice never duplicates; every entry lands exactly once.
    @Test @MainActor func seedIsIdempotent() throws {
        let schema = Schema([Exercise.self, WorkoutSession.self, ExerciseSet.self, PRRecord.self, Walk.self, Activity.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        ExerciseCatalog.seedIfNeeded(context: container.mainContext)
        ExerciseCatalog.seedIfNeeded(context: container.mainContext)

        let count = try container.mainContext.fetchCount(FetchDescriptor<Exercise>())
        #expect(count == ExerciseCatalog.entries.count)
    }

    @Test @MainActor func seedIncludesGuides() throws {
        let schema = Schema([Exercise.self, WorkoutSession.self, ExerciseSet.self, PRRecord.self, Walk.self, Activity.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        ExerciseCatalog.seedIfNeeded(context: container.mainContext)

        let exercises = try container.mainContext.fetch(FetchDescriptor<Exercise>())
        #expect(!exercises.isEmpty)
        #expect(exercises.allSatisfy { $0.exerciseDescription != nil && !$0.instructionSteps.isEmpty })
    }

    /// Catalogs seeded before guides existed get them filled in on next launch.
    @Test @MainActor func backfillFillsLegacyDefaults() throws {
        let schema = Schema([Exercise.self, WorkoutSession.self, ExerciseSet.self, PRRecord.self, Walk.self, Activity.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        // Simulate a legacy install: a default movement with no guide, plus a
        // custom movement that must stay untouched.
        let legacy = Exercise(name: "Deadlift", muscleGroup: "Lats")
        let custom = Exercise(name: "My Weird Lift", muscleGroup: "Core", isCustom: true)
        container.mainContext.insert(legacy)
        container.mainContext.insert(custom)
        try container.mainContext.save()

        ExerciseCatalog.seedIfNeeded(context: container.mainContext)

        #expect(legacy.exerciseDescription != nil)
        #expect(!legacy.instructionSteps.isEmpty)
        #expect(custom.exerciseDescription == nil)
    }
}

struct AICatalogFilterTests {

    private func brief(_ name: String, _ muscles: [String]) -> ExerciseBrief {
        ExerciseBrief(name: name, muscleGroups: muscles, equipment: "Barbell")
    }

    /// The prompt catalog is capped and prioritizes the focus muscles.
    @Test func focusedCatalogCapsAndPrioritizes() {
        let chest = (0..<60).map { brief("Chest \($0)", ["Chest"]) }
        let legs = (0..<60).map { brief("Legs \($0)", ["Quads"]) }
        let result = WorkoutAI.focusedCatalog(chest + legs, targetMuscleGroups: ["Chest"], cap: 40)

        #expect(result.count == 40)
        #expect(result.allSatisfy { $0.muscleGroups.contains("Chest") })
    }

    /// Small catalogs pass through untouched; short focus lists get padded
    /// with accessories up to the cap.
    @Test func focusedCatalogFillsWithAccessories() {
        let chest = (0..<10).map { brief("Chest \($0)", ["Chest"]) }
        let legs = (0..<60).map { brief("Legs \($0)", ["Quads"]) }

        #expect(WorkoutAI.focusedCatalog(chest, targetMuscleGroups: ["Chest"], cap: 40).count == 10)

        let padded = WorkoutAI.focusedCatalog(chest + legs, targetMuscleGroups: ["Chest"], cap: 40)
        #expect(padded.count == 40)
        #expect(padded.filter { $0.muscleGroups.contains("Chest") }.count == 10)
    }
}

struct MuscleRecoveryTests {

    /// Training a few muscles today must not zero out overall readiness —
    /// everything untouched is rested and therefore ready.
    @Test func untouchedMusclesCountAsReady() {
        var statuses: [MuscleGroup: MuscleStatus] = [:]
        for group in MuscleGroup.allCases {
            statuses[group] = MuscleStatus(group: group)
        }
        // Chest and triceps trained an hour ago -> needs rest.
        statuses[.chest]?.lastTrained = Date().addingTimeInterval(-3600)
        statuses[.triceps]?.lastTrained = Date().addingTimeInterval(-3600)

        let fraction = MuscleRecovery.readyFraction(statuses: statuses)
        let expected = Double(MuscleGroup.allCases.count - 2) / Double(MuscleGroup.allCases.count)
        #expect(abs(fraction - expected) < 0.001)
    }

    @Test func recoveredMuscleCountsAsReady() {
        var statuses: [MuscleGroup: MuscleStatus] = [:]
        for group in MuscleGroup.allCases {
            statuses[group] = MuscleStatus(group: group)
        }
        // Trained three days ago -> recovered and ready.
        statuses[.quads]?.lastTrained = Date().addingTimeInterval(-3 * 24 * 3600)

        #expect(abs(MuscleRecovery.readyFraction(statuses: statuses) - 1.0) < 0.001)
    }
}

@MainActor
struct PREngineTests {

    /// The container must outlive the test body: ModelContext does not retain
    /// its ModelContainer, and using a context whose container was deallocated
    /// crashes inside SwiftData.
    @MainActor
    private struct Harness {
        let container: ModelContainer
        let manager: WorkoutManager
        var context: ModelContext { container.mainContext }
    }

    private func makeHarness() throws -> Harness {
        let schema = Schema([Exercise.self, WorkoutSession.self, ExerciseSet.self, PRRecord.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        return Harness(container: container, manager: WorkoutManager(context: container.mainContext))
    }

    @Test func firstSetTriggersLimitBreak() throws {
        let harness = try makeHarness()
        let bench = Exercise(name: "Bench", muscleGroup: "Chest")
        harness.context.insert(bench)

        harness.manager.startSession(named: "Test")
        let event = harness.manager.logSet(exercise: bench, weight: 200, reps: 5)

        #expect(event != nil)
        #expect(event?.recordType == "1RM")
        #expect(event?.deltaPercent == nil) // first record has no prior ceiling
        #expect(bench.ceiling(for: "1RM") == 200 * (1 + 5.0 / 30.0))
    }

    @Test func weakerSetDoesNotTrigger() throws {
        let harness = try makeHarness()
        let bench = Exercise(name: "Bench", muscleGroup: "Chest")
        harness.context.insert(bench)

        harness.manager.startSession(named: "Test")
        _ = harness.manager.logSet(exercise: bench, weight: 200, reps: 5)
        let weaker = harness.manager.logSet(exercise: bench, weight: 135, reps: 5)

        #expect(weaker == nil)
        #expect(bench.prRecords.count == 1)
    }

    @Test func heavierSetRaisesCeilingWithDelta() throws {
        let harness = try makeHarness()
        let bench = Exercise(name: "Bench", muscleGroup: "Chest")
        harness.context.insert(bench)

        harness.manager.startSession(named: "Test")
        _ = harness.manager.logSet(exercise: bench, weight: 200, reps: 5)
        let event = harness.manager.logSet(exercise: bench, weight: 220, reps: 5)

        #expect(event != nil)
        #expect(abs((event?.deltaPercent ?? 0) - 10.0) < 0.0001) // 220 vs 200 at equal reps
        #expect(bench.prRecords.count == 2)
    }

    @Test func warmupSetsNeverTrigger() throws {
        let harness = try makeHarness()
        let bench = Exercise(name: "Bench", muscleGroup: "Chest")
        harness.context.insert(bench)

        harness.manager.startSession(named: "Test")
        let event = harness.manager.logSet(exercise: bench, weight: 300, reps: 5, isWarmup: true)

        #expect(event == nil)
        #expect(bench.prRecords.isEmpty)
    }

    @Test func bodyweightExerciseRecordsMaxReps() throws {
        let harness = try makeHarness()
        let pullUp = Exercise(name: "Pull-Up", muscleGroup: "Lats", trackingType: .bodyweightAndReps)
        harness.context.insert(pullUp)

        harness.manager.startSession(named: "Test")
        harness.manager.bodyWeightOverride = nil
        // Force the legacy path: without any known body weight the record
        // falls back to max reps. (Simulators may carry a manual weight.)
        let healthWeight = HealthKitManager.shared.currentBodyWeightLbs
        guard healthWeight == nil else { return } // covered by the stamped test below
        let event = harness.manager.logSet(exercise: pullUp, weight: 0, reps: 12)

        #expect(event?.recordType == "Max Reps")
        #expect(event?.newValue == 12)
    }

    @Test func bodyweightSetUsesBodyWeightWhenKnown() throws {
        let harness = try makeHarness()
        let pullUp = Exercise(name: "Pull-Up", muscleGroup: "Lats", trackingType: .bodyweightAndReps)
        harness.context.insert(pullUp)

        harness.manager.startSession(named: "Test")
        harness.manager.bodyWeightOverride = 180
        let event = harness.manager.logSet(exercise: pullUp, weight: 0, reps: 5)

        // Effective load 180 lbs → Epley: 180 × (1 + 5/30) = 210.
        #expect(event?.recordType == "1RM")
        #expect(abs((event?.newValue ?? 0) - 210) < 0.001)
    }

    @Test func assistedSetSubtractsAssistanceFromBodyWeight() throws {
        let harness = try makeHarness()
        let assisted = Exercise(
            name: "Assisted Pull-Up",
            muscleGroup: "Lats",
            trackingType: .bodyweightAndReps,
            isAssisted: true
        )
        harness.context.insert(assisted)

        harness.manager.startSession(named: "Test")
        harness.manager.bodyWeightOverride = 200
        let event = harness.manager.logSet(exercise: assisted, weight: -50, reps: 5)

        // Effective load 150 lbs → Epley: 150 × (1 + 5/30) = 175.
        #expect(event?.recordType == "1RM")
        #expect(abs((event?.newValue ?? 0) - 175) < 0.001)

        // Volume counts the effective load, not the negative assistance.
        let volume = harness.manager.activeSession?.totalVolume ?? 0
        #expect(abs(volume - 150 * 5) < 0.001)
    }

    @Test func orderedLoggingWalksExercisesInOrder() throws {
        let harness = try makeHarness()
        let bench = Exercise(name: "Bench", muscleGroup: "Chest")
        let squat = Exercise(name: "Squat", muscleGroup: "Quads")
        harness.context.insert(bench)
        harness.context.insert(squat)

        harness.manager.startSession(
            named: "Test",
            exercises: [bench, squat],
            targets: [bench.id: 2, squat.id: 1]
        )

        #expect(harness.manager.currentExercise?.id == bench.id)
        harness.manager.logNextSetInOrder()
        #expect(harness.manager.currentExercise?.id == bench.id) // 1 of 2 done
        harness.manager.logNextSetInOrder()
        #expect(harness.manager.currentExercise?.id == squat.id) // bench complete
        harness.manager.logNextSetInOrder()
        #expect(harness.manager.currentExercise == nil) // all planned sets done

        #expect(harness.manager.sets(for: bench).count == 2)
        #expect(harness.manager.sets(for: squat).count == 1)
    }

    @Test func advanceSkipsRemainderOfCurrentExercise() throws {
        let harness = try makeHarness()
        let bench = Exercise(name: "Bench", muscleGroup: "Chest")
        let squat = Exercise(name: "Squat", muscleGroup: "Quads")
        harness.context.insert(bench)
        harness.context.insert(squat)

        harness.manager.startSession(
            named: "Test",
            exercises: [bench, squat],
            targets: [bench.id: 3, squat.id: 2]
        )

        harness.manager.logNextSetInOrder()          // bench 1/3
        harness.manager.advanceToNextExercise()      // skip bench remainder
        #expect(harness.manager.currentExercise?.id == squat.id)
        harness.manager.logNextSetInOrder()
        #expect(harness.manager.sets(for: squat).count == 1)
    }
}

// MARK: - Odysseus

/// Templates are the core of the app, so they're pinned here rather than left
/// to drift. These assert on *contract* — the rules a model has to be told and
/// the data it has to be given — not on exact wording, so copy can be reworded
/// without breaking the suite.
struct PromptBuilderTests {

    private func catalog() -> [ExerciseBrief] {
        [
            ExerciseBrief(name: "Bench Press", muscleGroups: ["Chest"], equipment: "Barbell"),
            ExerciseBrief(name: "Lat Pulldown", muscleGroups: ["Lats"], equipment: "Cable"),
        ]
    }

    private func context(
        goal: TrainingGoal = .buildMuscle,
        withPartner: Bool = false,
        provider: AIProvider = .odysseus
    ) -> TrainingContext {
        TrainingContext(
            goal: goal,
            experience: .intermediate,
            daysPerWeek: 4,
            muscleStatuses: [:],
            recentSessions: [
                .init(name: "Push Day", daysAgo: 2, muscleGroups: ["Chest"], workingSets: 12)
            ],
            ceilings: ["Bench Press": 225],
            withPartner: withPartner,
            provider: provider
        )
    }

    /// The catalog is a closed set — every movement has to be listed, with the
    /// equipment and muscles the coach needs to pick sensibly.
    @Test func catalogBlockListsEveryMovement() {
        let block = PromptBuilder.catalogBlock(catalog())
        #expect(block.contains("Bench Press"))
        #expect(block.contains("Lat Pulldown"))
        #expect(block.contains("Barbell"))
        #expect(block.contains("Chest"))
    }

    /// The request block is where all volatile data lives; the system prefix
    /// must stay stable so the Anthropic prompt cache isn't invalidated.
    @Test func requestBlockCarriesGoalHistoryAndCeilings() {
        let block = PromptBuilder.requestBlock(
            focusLabel: "Upper Body",
            targetMuscleGroups: [],
            exerciseCount: 5,
            durationMinutes: 45,
            context: context()
        )
        #expect(block.contains("Build Muscle"))
        #expect(block.contains("Upper Body"))
        #expect(block.contains("Select exactly 5 movements."))
        #expect(block.contains("about 45 minutes"))
        #expect(block.contains("Push Day"))
        #expect(block.contains("225"))
        // Nothing volatile belongs in the system prefix.
        #expect(!PromptBuilder.coachInstructions.contains("Upper Body"))
    }

    /// Whether a spotter is present changes what's safe to program, so it has
    /// to reach the model either way — not only when a partner is there.
    @Test func partnerPresenceIsAlwaysStated() {
        let alone = PromptBuilder.requestBlock(
            focusLabel: "Legs", targetMuscleGroups: [], exerciseCount: 4,
            durationMinutes: nil, context: context(withPartner: false)
        )
        let spotted = PromptBuilder.requestBlock(
            focusLabel: "Legs", targetMuscleGroups: [], exerciseCount: 4,
            durationMinutes: nil, context: context(withPartner: true)
        )
        #expect(alone.contains("no spotter"))
        #expect(spotted.contains("partner is present"))
    }

    /// A duration is optional; omitting it must not leave a dangling label.
    @Test func omittedDurationIsAbsentEntirely() {
        let block = PromptBuilder.requestBlock(
            focusLabel: "Legs", targetMuscleGroups: [], exerciseCount: 4,
            durationMinutes: nil, context: context()
        )
        #expect(!block.contains("Target length"))
    }

    /// The superset directive is opt-in: allowed → the coach is told to add some
    /// and the strict count is relaxed; disallowed → an explicit ban and a hard
    /// count. Default (no flag) is the disallowed, back-compatible path.
    @Test func supersetDirectiveTracksTheFlag() {
        let allowed = PromptBuilder.requestBlock(
            focusLabel: "Push", targetMuscleGroups: [], exerciseCount: 5,
            durationMinutes: nil, context: context(), allowSupersets: true
        )
        #expect(allowed.lowercased().contains("superset"))
        #expect(!allowed.contains("Select exactly"))

        let disallowed = PromptBuilder.requestBlock(
            focusLabel: "Push", targetMuscleGroups: [], exerciseCount: 5,
            durationMinutes: nil, context: context(), allowSupersets: false
        )
        #expect(disallowed.contains("Select exactly 5 movements."))
        #expect(disallowed.contains("Do not use supersets"))

        // Default omits the flag → same as disallowed.
        let byDefault = PromptBuilder.requestBlock(
            focusLabel: "Push", targetMuscleGroups: [], exerciseCount: 5,
            durationMinutes: nil, context: context()
        )
        #expect(byDefault.contains("Do not use supersets"))
    }

    /// The self-hosted prompt has no system channel, so instructions, catalog,
    /// output contract, and request all have to arrive in one message — with
    /// the format rules last, immediately before generation.
    @Test func selfHostedPromptIsSelfContained() {
        let prompt = PromptBuilder.selfHostedPlanPrompt(
            focusLabel: "Upper Body",
            targetMuscleGroups: [],
            exerciseCount: 5,
            durationMinutes: nil,
            context: context(),
            catalog: catalog()
        )
        #expect(prompt.contains("strength coach behind LimitBreak"))
        #expect(prompt.contains("Bench Press"))
        #expect(prompt.contains("OUTPUT FORMAT"))
        #expect(prompt.contains("Upper Body"))

        let contract = try! #require(prompt.range(of: "OUTPUT FORMAT"))
        let request = try! #require(prompt.range(of: "THIS SESSION:"))
        #expect(contract.lowerBound < request.lowerBound)
    }

    /// Every key the parser reads has to be named in the contract, or a local
    /// model has no way to know it's expected.
    @Test func outputContractNamesEveryField() {
        let contract = PromptBuilder.jsonOutputContract
        for key in ["title", "rationale", "exercises", "name", "sets",
                    "repRangeLow", "repRangeHigh", "targetLoadPounds",
                    "restSeconds", "note"] {
            #expect(contract.contains(key), "contract omits \(key)")
        }
    }

    /// The fatigue report is time-relative, so it's rendered against an
    /// injected clock rather than the wall clock.
    @Test func fatigueReportUsesTheInjectedClock() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var ctx = context()
        ctx.muscleStatuses = [
            .chest: MuscleStatus(
                group: .chest,
                lastTrained: now.addingTimeInterval(-2 * 86_400),
                weeklySets: 9
            )
        ]
        let block = PromptBuilder.requestBlock(
            focusLabel: "Push", targetMuscleGroups: [], exerciseCount: 3,
            durationMinutes: nil, context: ctx, now: now
        )
        #expect(block.contains("2 days ago"))
        #expect(block.contains("9 sets this week"))
    }
}

/// A local model can't be constrained to a schema, so the reply arrives wrapped
/// in whatever it felt like emitting. These cover the wrappings seen in
/// practice — the parser has to survive all of them.
struct JSONExtractorTests {

    @Test func bareObjectPassesThrough() {
        let text = #"{"title":"Iron Ascent"}"#
        #expect(JSONExtractor.firstObject(in: text) == text)
    }

    @Test func fencedJSONIsUnwrapped() {
        let text = """
            Sure, here's your plan:

            ```json
            {"title": "Iron Ascent", "exercises": []}
            ```

            Let me know if you want it harder!
            """
        let object = try! #require(JSONExtractor.firstObject(in: text))
        #expect(object.hasPrefix("{"))
        #expect(object.hasSuffix("}"))
        #expect(!object.contains("```"))
        #expect(!object.contains("Let me know"))
    }

    /// Braces inside a string value must not close the object early — an
    /// exercise note is free text and can contain anything.
    @Test func bracesInsideStringsDoNotTerminate() {
        let text = #"{"note": "use a { grip }", "sets": 3}"#
        let object = try! #require(JSONExtractor.firstObject(in: text))
        #expect(object == text)
    }

    /// An escaped quote must not be read as the end of the string.
    @Test func escapedQuotesAreHandled() {
        let text = #"{"note": "say \"go\" then lift", "sets": 3}"#
        let object = try! #require(JSONExtractor.firstObject(in: text))
        #expect(object == text)
    }

    @Test func nestedObjectsSurviveIntact() {
        let text = #"{"a": {"b": {"c": 1}}, "d": 2}"#
        #expect(JSONExtractor.firstObject(in: text) == text)
    }

    /// Reasoning models draft a throwaway object inside <think>. Taking the
    /// first balanced object without stripping that would return the draft.
    @Test func reasoningBlockIsDiscardedBeforeScanning() {
        let text = """
            <think>Maybe {"title": "Draft"} — no, too easy.</think>
            {"title": "Final", "exercises": []}
            """
        let object = try! #require(JSONExtractor.firstObject(in: text))
        #expect(object.contains("Final"))
        #expect(!object.contains("Draft"))
    }

    /// A generation cut off mid-thought yields no object, rather than a
    /// truncated one that would decode into a wrong plan.
    @Test func unclosedReasoningBlockYieldsNothing() {
        let text = #"<think>I should probably use {"title": "Draft"}"#
        #expect(JSONExtractor.firstObject(in: text) == nil)
    }

    @Test func proseWithNoObjectReturnsNil() {
        #expect(JSONExtractor.firstObject(in: "I can't help with that.") == nil)
    }

    @Test func unbalancedObjectReturnsNil() {
        #expect(JSONExtractor.firstObject(in: #"{"title": "Truncated""#) == nil)
    }
}

/// The server reports failures under two different keys depending on which
/// layer rejected the request. Surfacing the wrong one turns a clear "your
/// token is bad" into a generic failure, so both shapes are pinned.
struct OdysseusDecodingTests {

    private func body(_ json: String) -> Data { Data(json.utf8) }

    /// The auth middleware's shape.
    @Test func errorKeyIsSurfaced() {
        let message = OdysseusClient.ErrorBody.message(from: body(#"{"error": "Invalid API token"}"#))
        #expect(message == "Invalid API token")
    }

    /// The routes' shape.
    @Test func detailKeyIsSurfaced() {
        let message = OdysseusClient.ErrorBody.message(
            from: body(#"{"detail": "Model endpoint no longer exists"}"#)
        )
        #expect(message == "Model endpoint no longer exists")
    }

    /// FastAPI validation failures arrive as an array under `detail`.
    @Test func validationArrayIsFlattened() {
        let json = #"{"detail": [{"loc": ["body"], "msg": "field required"}]}"#
        #expect(OdysseusClient.ErrorBody.message(from: body(json)) == "field required")
    }

    /// An unreadable error body must not throw on top of the error it reports.
    @Test func unknownShapesDegradeToNil() {
        #expect(OdysseusClient.ErrorBody.message(from: body(#"{"oops": true}"#)) == nil)
        #expect(OdysseusClient.ErrorBody.message(from: body("not json at all")) == nil)
        #expect(OdysseusClient.ErrorBody.message(from: body(#"{"error": "   "}"#)) == nil)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: body(json))
    }

    @Test func pingDecodes() throws {
        let ping = try decode(
            OdysseusClient.Ping.self,
            #"{"ok": true, "name": "odysseus", "version": "1.4.0", "auth": "token"}"#
        )
        #expect(ping.ok)
        #expect(ping.summary.contains("odysseus"))
        #expect(ping.summary.contains("1.4.0"))
    }

    /// snake_case keys have to survive the mapping, especially `endpoint_id` —
    /// it's the only identifier the server accepts from a token caller.
    @Test func modelListDecodesSnakeCaseKeys() throws {
        let json = """
            {"endpoints": [{"endpoint_id": "ep-1", "name": "Local", \
            "endpoint_url": "http://127.0.0.1:8080", \
            "models": ["qwen3-30b", "llama-3.3-70b"], "supports_tools": true}]}
            """
        let list = try decode(OdysseusClient.ModelList.self, json)
        let endpoint = try #require(list.endpoints.first)
        #expect(endpoint.endpointId == "ep-1")
        #expect(endpoint.id == "ep-1")
        #expect(endpoint.displayName == "Local")
        #expect(endpoint.models.count == 2)
        #expect(endpoint.supportsTools == true)
    }

    /// A nameless endpoint still needs something to render.
    @Test func endpointFallsBackToItsID() throws {
        let json = #"{"endpoints": [{"endpoint_id": "ep-2", "models": ["m"]}]}"#
        let list = try decode(OdysseusClient.ModelList.self, json)
        #expect(list.endpoints.first?.displayName == "ep-2")
    }

    @Test func sessionAndChatDecode() throws {
        let session = try decode(
            OdysseusClient.Session.self,
            #"{"id": "sess-9", "name": "LimitBreak", "model": "qwen3-30b", "rag": false, "archived": false}"#
        )
        #expect(session.id == "sess-9")

        let reply = try decode(OdysseusClient.ChatReply.self, #"{"response": "hello"}"#)
        #expect(reply.response == "hello")
    }

    /// `/api/session` is form-encoded. `.urlQueryAllowed` would leave `&` and
    /// `+` intact and corrupt the field boundaries, so encoding is pinned.
    @Test func formEncodingEscapesReservedCharacters() {
        let encoded = OdysseusClient.formEncode(["name": "Leg Day & Abs", "model": "a+b"])
        #expect(encoded.contains("Leg%20Day%20%26%20Abs"))
        #expect(encoded.contains("a%2Bb"))
        // Sorted, so the output is stable and assertable.
        #expect(encoded == "model=a%2Bb&name=Leg%20Day%20%26%20Abs")
    }

    /// A pasted host with no scheme is the common slip; trailing slashes would
    /// produce a double slash in every path.
    @Test func baseURLIsNormalized() throws {
        #expect(try OdysseusClient.normalizedBaseURL("daniel-pc.ts.net").absoluteString
                == "https://daniel-pc.ts.net")
        #expect(try OdysseusClient.normalizedBaseURL("https://daniel-pc.ts.net/").absoluteString
                == "https://daniel-pc.ts.net")
        #expect(throws: OdysseusClient.OdysseusError.self) {
            try OdysseusClient.normalizedBaseURL("   ")
        }
    }

    /// A revoked token has to read as an auth problem, not a generic failure —
    /// otherwise the fix isn't discoverable.
    @Test func authFailureReadsAsAuthFailure() {
        let withMessage = OdysseusClient.OdysseusError.unauthorized("Invalid API token")
        let bare = OdysseusClient.OdysseusError.unauthorized(nil)
        #expect(withMessage.errorDescription?.contains("Authentication failed") == true)
        #expect(withMessage.errorDescription?.contains("Invalid API token") == true)
        #expect(bare.errorDescription?.contains("Authentication failed") == true)
        #expect(bare.errorDescription?.contains("Settings") == true)
    }
}

/// Local models deviate from the contract in small, predictable ways. Each of
/// these is a deviation worth absorbing rather than failing a two-minute
/// generation over.
struct OdysseusPlanParsingTests {

    @Test func cleanReplyDecodes() throws {
        let reply = """
            {"title": "Iron Ascent", "rationale": "Chest is fresh.",
             "exercises": [{"name": "Bench Press", "sets": 4, "repRangeLow": 6,
             "repRangeHigh": 10, "targetLoadPounds": 185, "restSeconds": 120,
             "note": "Primary press."}]}
            """
        let plan = try OdysseusWorkoutAI.decodePlan(from: reply)
        #expect(plan.title == "Iron Ascent")
        #expect(plan.exercises.first?.name == "Bench Press")
        #expect(plan.exercises.first?.targetLoadPounds == 185)
    }

    @Test func fencedReplyDecodes() throws {
        let reply = """
            Here's the session:
            ```json
            {"title": "Steel Surge", "rationale": "Back day.",
             "exercises": [{"name": "Lat Pulldown", "sets": 3, "repRangeLow": 8,
             "repRangeHigh": 12, "targetLoadPounds": 120, "restSeconds": 90,
             "note": "Vertical pull."}]}
            ```
            """
        let plan = try OdysseusWorkoutAI.decodePlan(from: reply)
        #expect(plan.title == "Steel Surge")
    }

    /// Numbers quoted as strings, and a weight carrying its unit.
    @Test func stringifiedNumbersAreCoerced() throws {
        let reply = """
            {"title": "Quoted", "rationale": "",
             "exercises": [{"name": "Squat", "sets": "5", "repRangeLow": "3",
             "repRangeHigh": "5", "targetLoadPounds": "315 lbs",
             "restSeconds": "180", "note": "Heavy."}]}
            """
        let plan = try OdysseusWorkoutAI.decodePlan(from: reply)
        let squat = try #require(plan.exercises.first)
        #expect(squat.sets == 5)
        #expect(squat.repRangeLow == 3)
        #expect(squat.targetLoadPounds == 315)
        #expect(squat.restSeconds == 180)
    }

    /// A rep range collapsed into one field: take the first number and let the
    /// caller's clamping handle the rest.
    @Test func collapsedRepRangeTakesTheFirstNumber() throws {
        let reply = """
            {"title": "Range", "exercises": [{"name": "Row", "repRangeLow": "8-12",
             "repRangeHigh": 12, "sets": 3, "targetLoadPounds": 95,
             "restSeconds": 90, "note": ""}]}
            """
        let plan = try OdysseusWorkoutAI.decodePlan(from: reply)
        #expect(plan.exercises.first?.repRangeLow == 8)
    }

    /// Missing optional fields fall back to a sane prescription rather than
    /// discarding an otherwise usable plan.
    @Test func missingFieldsFallBackToDefaults() throws {
        let reply = #"{"exercises": [{"name": "Deadlift"}]}"#
        let plan = try OdysseusWorkoutAI.decodePlan(from: reply)
        let lift = try #require(plan.exercises.first)
        #expect(lift.name == "Deadlift")
        #expect(lift.sets == 3)
        #expect(lift.repRangeLow <= lift.repRangeHigh)
        #expect(lift.restSeconds == 90)
        #expect(!plan.title.isEmpty)
    }

    /// Small models rename the list; a plan is still a plan.
    @Test func aliasedExerciseListIsAccepted() throws {
        let reply = """
            {"title": "Aliased", "movements": [{"exercise": "Overhead Press",
             "sets": 3, "repRangeLow": 5, "repRangeHigh": 8,
             "targetLoadPounds": 95, "restSeconds": 120, "note": "Press."}]}
            """
        let plan = try OdysseusWorkoutAI.decodePlan(from: reply)
        #expect(plan.exercises.first?.name == "Overhead Press")
    }

    /// An empty plan can't be rendered, and the on-device tiers do better.
    @Test func emptyPlanIsRejected() {
        #expect(throws: OdysseusClient.OdysseusError.self) {
            try OdysseusWorkoutAI.decodePlan(from: #"{"title": "Nothing", "exercises": []}"#)
        }
    }

    @Test func replyWithoutJSONIsRejected() {
        #expect(throws: OdysseusClient.OdysseusError.self) {
            try OdysseusWorkoutAI.decodePlan(from: "I'd rather not build a workout today.")
        }
    }

    /// A parsed plan still has to survive catalog matching, which is what
    /// finally tags it as self-hosted rather than Claude-coached.
    @Test func parsedPlanMapsAndIsTaggedSelfHosted() throws {
        let reply = """
            {"title": "Iron Ascent", "rationale": "Push day.",
             "exercises": [{"name": "bench press", "sets": 4, "repRangeLow": 6,
             "repRangeHigh": 10, "targetLoadPounds": 185, "restSeconds": 120,
             "note": "Primary press."}]}
            """
        let plan = try OdysseusWorkoutAI.decodePlan(from: reply)
        let mapped = try #require(WorkoutAI.matchToCatalog(
            plan,
            catalog: [ExerciseBrief(name: "Bench Press", muscleGroups: ["Chest"], equipment: "Barbell")],
            limit: 5,
            source: .selfHosted
        ))
        #expect(mapped.source == .selfHosted)
        #expect(mapped.source.label.contains("your server"))
        #expect(mapped.exercises.first?.name == "Bench Press")
    }
}

/// The token is a long-lived credential; these pin the storage guarantees that
/// matter, without asserting on Keychain internals.
struct OdysseusCredentialTests {

    /// The two credentials live under separate services, so removing one must
    /// not disturb the other.
    @Test func tokensAreStoredIndependentlyOfTheAnthropicKey() {
        let savedKey = KeychainStore.apiKey
        let savedToken = KeychainStore.odysseusToken
        defer {
            KeychainStore.setAPIKey(savedKey)
            KeychainStore.setOdysseusToken(savedToken)
        }

        KeychainStore.setAPIKey("sk-ant-test-key-1234")
        KeychainStore.setOdysseusToken("ody_test_token_5678")
        #expect(KeychainStore.apiKey == "sk-ant-test-key-1234")
        #expect(KeychainStore.odysseusToken == "ody_test_token_5678")

        KeychainStore.deleteOdysseusToken()
        #expect(KeychainStore.odysseusToken == nil)
        #expect(KeychainStore.apiKey == "sk-ant-test-key-1234")
    }

    /// An `ody_` token is masked the same way an API key is — recognizable
    /// prefix, last four, nothing in between.
    @Test func tokenIsNeverRenderedInFull() {
        let token = "ody_liveSECRETMATERIAL4321"
        let masked = token.maskedAPIKey
        #expect(masked.hasPrefix("ody_"))
        #expect(masked.hasSuffix("4321"))
        #expect(!masked.contains("SECRETMATERIAL"))
    }
}

/// The self-hosted prompt has to survive a modest context window, because a
/// local runtime often loads a large-context model with a small one and
/// truncates silently rather than erroring.
struct PromptBudgetTests {

    /// A stand-in for the bundled library, at its real size.
    private func fullCatalog() -> [ExerciseBrief] {
        let groups = MuscleGroup.allCases
        return (0..<264).map { i in
            ExerciseBrief(
                name: "Movement \(i)",
                muscleGroups: [groups[i % groups.count].rawValue],
                equipment: "Barbell"
            )
        }
    }

    private func context() -> TrainingContext {
        TrainingContext(
            goal: .buildMuscle,
            experience: .intermediate,
            daysPerWeek: 4,
            muscleStatuses: [:],
            recentSessions: (0..<8).map {
                .init(name: "Session \($0)", daysAgo: $0, muscleGroups: ["Chest"], workingSets: 10)
            },
            ceilings: Dictionary(uniqueKeysWithValues: (0..<40).map { ("Lift \($0)", Double(100 + $0)) }),
            withPartner: false,
            provider: .odysseus
        )
    }

    private func prompt(_ budget: PromptBuilder.Budget) -> String {
        PromptBuilder.selfHostedPlanPrompt(
            focusLabel: "Push",
            targetMuscleGroups: [MuscleGroup.chest.rawValue],
            exerciseCount: 5,
            durationMinutes: nil,
            context: context(),
            catalog: fullCatalog(),
            budget: budget
        )
    }

    /// The whole point: a compact prompt fits a 4k window with room to reply.
    @Test func compactPromptFitsASmallContextWindow() {
        let tokens = PromptBuilder.estimatedTokens(prompt(.compact))
        #expect(tokens < 2_500, "compact prompt is ~\(tokens) tokens")
    }

    /// And it's meaningfully smaller than sending everything.
    @Test func compactPromptIsSubstantiallySmallerThanFull() {
        let compact = PromptBuilder.estimatedTokens(prompt(.compact))
        let full = PromptBuilder.estimatedTokens(prompt(.full))
        #expect(compact < full / 2)
    }

    /// Trimming must not cost the model the movements it actually needs — the
    /// requested muscle group has to survive the cut.
    @Test func narrowingKeepsMovementsForTheRequestedMuscles() {
        let catalog = fullCatalog()
        let offered = WorkoutAI.focusedCatalog(
            catalog,
            targetMuscleGroups: [MuscleGroup.chest.rawValue],
            cap: PromptBuilder.Budget.compact.catalogCap
        )
        #expect(offered.count <= PromptBuilder.Budget.compact.catalogCap)
        #expect(offered.contains { $0.muscleGroups.contains(MuscleGroup.chest.rawValue) })
    }

    /// Caps apply to the volatile blocks too, strongest lifts kept first.
    @Test func budgetTrimsCeilingsAndHistory() {
        let block = PromptBuilder.requestBlock(
            focusLabel: "Push",
            targetMuscleGroups: [],
            exerciseCount: 5,
            durationMinutes: nil,
            context: context(),
            budget: .compact
        )
        #expect(block.contains("Lift 39"))          // strongest, kept
        #expect(!block.contains("Lift 0:"))         // weakest, dropped
        #expect(block.contains("Session 0"))        // newest, kept
        #expect(!block.contains("Session 7"))       // oldest, dropped
    }

    /// The Anthropic path must keep sending the whole catalog: it's the cached
    /// system prefix, and narrowing it per request would change the prefix on
    /// every generation and defeat the cache.
    @Test func fullBudgetSendsEverything() {
        let full = prompt(.full)
        #expect(full.contains("Movement 263"))
        #expect(full.contains("Session 7"))
    }
}

/// "Couldn't read the response" was one message covering three unrelated
/// failures, which made it undiagnosable from the phone. Each now names its own
/// cause, because each has a different fix.
struct OdysseusReplyDiagnosisTests {

    private func failure(_ reply: String) -> OdysseusClient.OdysseusError? {
        do {
            _ = try OdysseusWorkoutAI.decodePlan(from: reply)
            return nil
        } catch let error as OdysseusClient.OdysseusError {
            return error
        } catch {
            return nil
        }
    }

    /// Model ignored the format instruction — fix is the prompt.
    @Test func proseReplyIsNamedAsProse() throws {
        let error = try #require(failure("I'd suggest starting with three sets of bench press."))
        guard case .replyNotJSON(let snippet) = error else {
            Issue.record("expected .replyNotJSON, got \(error)")
            return
        }
        #expect(snippet.contains("bench press"))
        #expect(error.errorDescription?.contains("prose") == true)
    }

    /// Reply hit an output-token cap — fix is server config, and the message
    /// has to say so or it reads identically to a prompt problem.
    @Test func truncatedReplyIsNamedAsTruncated() throws {
        let cut = """
            {"title": "Iron Ascent", "rationale": "Push day.", "exercises": [
              {"name": "Bench Press", "sets": 4, "repRangeLow": 6, "repRangeHi
            """
        let error = try #require(failure(cut))
        guard case .replyTruncated = error else {
            Issue.record("expected .replyTruncated, got \(error)")
            return
        }
        #expect(error.errorDescription?.contains("cut off") == true)
        #expect(error.errorDescription?.contains("output token limit") == true)
    }

    /// Valid JSON, but not a workout.
    @Test func wrongShapeIsNamedAsWrongShape() throws {
        let error = try #require(failure(#"{"status": "ok", "items": []}"#))
        guard case .planShapeUnexpected = error else {
            Issue.record("expected .planShapeUnexpected, got \(error)")
            return
        }
        #expect(error.errorDescription?.contains("no workout") == true)
    }

    /// Snippets go in front of the lifter, so they stay short and single-line.
    @Test func snippetsAreTrimmedAndCollapsed() {
        let noisy = "  line one\n\n\tline   two  " + String(repeating: "x", count: 400)
        let snippet = OdysseusClient.snippet(noisy)
        #expect(!snippet.contains("\n"))
        #expect(!snippet.contains("  "))
        #expect(snippet.count <= 181)
        #expect(snippet.hasSuffix("…"))
    }
}

/// Shapes real local models produce that the first parser didn't survive.
struct OdysseusReplyShapeTests {

    /// Several Qwen and DeepSeek builds echo only the *closing* think tag,
    /// because the chat template opens the block for them. The draft JSON in
    /// that reasoning must not be mistaken for the answer.
    @Test func orphanClosingThinkTagIsHandled() throws {
        let reply = """
            Okay, the user wants a push day. Maybe {"title": "Draft", "exercises": []}?
            No, let me use real movements.
            </think>
            {"title": "Iron Ascent", "rationale": "Push day.",
             "exercises": [{"name": "Bench Press", "sets": 4, "repRangeLow": 6,
             "repRangeHigh": 10, "targetLoadPounds": 185, "restSeconds": 120,
             "note": "Primary press."}]}
            """
        let plan = try OdysseusWorkoutAI.decodePlan(from: reply)
        #expect(plan.title == "Iron Ascent")
        #expect(plan.exercises.count == 1)
    }

    /// A preamble object before the real plan must not win just by being first.
    @Test func firstObjectIsNotAssumedToBeThePlan() throws {
        let reply = """
            {"acknowledged": true}
            {"title": "Steel Surge", "exercises": [{"name": "Lat Pulldown",
             "sets": 3, "repRangeLow": 8, "repRangeHigh": 12,
             "targetLoadPounds": 120, "restSeconds": 90, "note": "Pull."}]}
            """
        let plan = try OdysseusWorkoutAI.decodePlan(from: reply)
        #expect(plan.title == "Steel Surge")
    }

    /// The plan nested one layer deeper than asked for.
    @Test func nestedPlanWrapperIsUnwrapped() throws {
        let reply = """
            {"workout": {"title": "Deep Cut", "rationale": "Legs.",
             "exercises": [{"name": "Back Squat", "sets": 5, "repRangeLow": 3,
             "repRangeHigh": 5, "targetLoadPounds": 315, "restSeconds": 180,
             "note": "Main lift."}]}}
            """
        let plan = try OdysseusWorkoutAI.decodePlan(from: reply)
        #expect(plan.title == "Deep Cut")
        #expect(plan.rationale == "Legs.")
        #expect(plan.exercises.first?.name == "Back Squat")
    }

    /// A title on the outer object and the list on the inner one.
    @Test func titleOutsideWrapperIsStillFound() throws {
        let reply = """
            {"title": "Split Level",
             "plan": {"exercises": [{"name": "Deadlift", "sets": 3,
             "repRangeLow": 3, "repRangeHigh": 5, "targetLoadPounds": 405,
             "restSeconds": 240, "note": "Pull."}]}}
            """
        let plan = try OdysseusWorkoutAI.decodePlan(from: reply)
        #expect(plan.title == "Split Level")
        #expect(plan.exercises.first?.name == "Deadlift")
    }

    /// snake_case naming for the list.
    @Test func snakeCaseListKeyIsAccepted() throws {
        let reply = """
            {"title": "Snake", "exercise_list": [{"name": "Row", "sets": 3,
             "repRangeLow": 8, "repRangeHigh": 12, "targetLoadPounds": 135,
             "restSeconds": 90, "note": "Pull."}]}
            """
        let plan = try OdysseusWorkoutAI.decodePlan(from: reply)
        #expect(plan.exercises.first?.name == "Row")
    }

    /// The scanner's own diagnosis, independent of plan decoding.
    @Test func scanDistinguishesTruncationFromProse() {
        #expect(JSONExtractor.scan("just talking") == .none)
        #expect(JSONExtractor.scan(#"{"a": 1, "b": "#) == .truncated)
        #expect(JSONExtractor.scan(#"{"a": "unterminated"#) == .truncated)
        #expect(JSONExtractor.scan(#"{"a":1}{"b":2}"#) == .found([#"{"a":1}"#, #"{"b":2}"#]))
    }
}

// MARK: - Progressive overload

@MainActor
struct ProgressionEngineTests {

    /// An in-memory store plus one weight/rep movement to hang history on. The
    /// container is returned so the caller can keep it alive — a context whose
    /// container has been deallocated crashes on use.
    private func makeStore() throws -> (ModelContainer, ModelContext, Exercise) {
        let schema = Schema([Exercise.self, WorkoutSession.self, ExerciseSet.self, PRRecord.self,
                             Walk.self, Activity.self, TrainingProfile.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        // Barbell → benefits from a spot → treated as a compound (narrow bands).
        let bench = Exercise(name: "Bench Press", muscleGroup: "Chest", equipmentType: "Barbell")
        context.insert(bench)
        return (container, context, bench)
    }

    /// Logs one session of identical working sets for an exercise.
    @discardableResult
    private func logSession(
        _ context: ModelContext,
        exercise: Exercise,
        weight: Double,
        reps: Int,
        sets: Int,
        daysAgo: Double,
        repsInReserve: Int? = nil
    ) -> WorkoutSession {
        let start = Date().addingTimeInterval(-daysAgo * 86_400)
        let session = WorkoutSession(name: "Session", startDate: start)
        context.insert(session)
        for i in 0..<sets {
            let set = ExerciseSet(weight: weight, reps: reps,
                                  timestamp: start.addingTimeInterval(Double(i) * 120))
            set.exercise = exercise
            set.session = session
            // Effort is now captured per exercise, stamped on each working set.
            set.repsInReserve = repsInReserve
            context.insert(set)
        }
        try? context.save()
        return session
    }

    /// Rep short of the top and effort left → hold weight, add a rep.
    @Test func addsARepWhenShortOfTheTop() throws {
        let (container, context, bench) = try makeStore()
        // buildMuscle volume band is 10–12; 3×10 with reps left → aim 11.
        logSession(context, exercise: bench, weight: 135, reps: 10, sets: 3, daysAgo: 3, repsInReserve: 2)

        let target = ProgressionEngine.nextTarget(
            for: bench, goal: .buildMuscle, emphasis: .volume
        )
        #expect(target?.targetReps == 11)
        #expect(target?.targetWeightPounds == 135)
        #expect(target?.previous?.topReps == 10)
        #expect(target?.previous?.sets == 3)
        withExtendedLifetime(container) {}
    }

    /// Every set caps the range → cash the reps in for a heavier load, reset reps.
    @Test func cashesInLoadWhenRangeCapped() throws {
        let (container, context, bench) = try makeStore()
        // getStronger heavy band is 3–4; 3×4 across the board → +increment, reset to 3.
        logSession(context, exercise: bench, weight: 200, reps: 4, sets: 3, daysAgo: 3)

        let target = ProgressionEngine.nextTarget(
            for: bench, goal: .getStronger, emphasis: .heavy
        )
        #expect(target?.targetReps == 3)
        #expect(target?.targetWeightPounds == 205) // 200 + default 5 lb increment
        withExtendedLifetime(container) {}
    }

    /// Trained to failure but short of the top → consolidate the same numbers.
    @Test func holdsWhenTrainedToFailure() throws {
        let (container, context, bench) = try makeStore()
        logSession(context, exercise: bench, weight: 135, reps: 10, sets: 3, daysAgo: 3, repsInReserve: 0)

        let target = ProgressionEngine.nextTarget(
            for: bench, goal: .buildMuscle, emphasis: .volume
        )
        #expect(target?.targetReps == 10)
        #expect(target?.targetWeightPounds == 135)
        withExtendedLifetime(container) {}
    }

    /// No history → seed a starting load from the recorded ceiling.
    @Test func startsFromCeilingWithNoHistory() throws {
        let (container, context, bench) = try makeStore()
        let pr = PRRecord(recordType: "1RM", numericValue: 225, repsAchieved: 1, exercise: bench)
        context.insert(pr)
        try context.save()

        let target = ProgressionEngine.nextTarget(
            for: bench, goal: .getStronger, emphasis: .heavy
        )
        // ~78% of 225 = 175.5, snapped to the 5 lb increment.
        #expect(target?.targetWeightPounds == 175)
        #expect(target?.targetReps == 3)
        #expect(target?.previous == nil)
        withExtendedLifetime(container) {}
    }

    /// The session track alternates: a heavy last session → a volume next one.
    @Test func emphasisUndulatesOffLastSession() throws {
        let (container, context, bench) = try makeStore()
        // getStronger heavy band tops out at 4; 3 reps reads as a heavy day.
        logSession(context, exercise: bench, weight: 200, reps: 3, sets: 3, daysAgo: 3)

        let target = ProgressionEngine.nextTarget(for: bench, goal: .getStronger)
        #expect(target?.emphasis == .volume)
        withExtendedLifetime(container) {}
    }
}

// MARK: - Supersets

/// Grouping is derived, never stored as runs — so the run logic and the AI's
/// tag-normalization are the load-bearing pieces and are pinned here.
struct SupersetGroupingTests {

    /// Consecutive slots sharing a non-nil tag form one run; a nil tag always
    /// breaks the run, so standalone slots come back as singletons.
    @Test func runsGroupConsecutiveMatchingTags() {
        let tags: [Int: Int?] = [0: nil, 1: 1, 2: 1, 3: nil, 4: 2, 5: 3]
        let runs = supersetRuns([0, 1, 2, 3, 4, 5]) { tags[$0] ?? nil }
        #expect(runs == [[0], [1, 2], [3], [4], [5]])
    }

    /// The same tag on non-adjacent slots does not merge across the gap.
    @Test func runsDoNotMergeAcrossAGap() {
        let tags: [Int: Int?] = [0: 1, 1: 2, 2: 1]
        let runs = supersetRuns([0, 1, 2]) { tags[$0] ?? nil }
        #expect(runs == [[0], [1], [2]])
    }

    private func planned(_ name: String, group: Int?) -> PlannedExercise {
        PlannedExercise(name: name, sets: 3, supersetGroup: group)
    }

    /// Coached tags are rewritten to clean 1…N groups regardless of what the
    /// model numbered them.
    @Test func normalizeRenumbersContiguousPairs() {
        let result = WorkoutAI.normalizeSupersets([
            planned("A", group: 5),
            planned("B", group: 5),
            planned("C", group: nil),
            planned("D", group: 9),
            planned("E", group: 9),
        ])
        #expect(result.map(\.supersetGroup) == [1, 1, nil, 2, 2])
    }

    /// A group left with a single survivor (its partner was hallucinated away)
    /// collapses to standalone rather than showing a superset of one.
    @Test func normalizeDropsSingleMemberGroups() {
        let result = WorkoutAI.normalizeSupersets([
            planned("A", group: nil),
            planned("B", group: 3),
            planned("C", group: nil),
        ])
        #expect(result.allSatisfy { $0.supersetGroup == nil })
    }

    /// A tag scattered across non-adjacent slots is not a real superset — both
    /// slots become standalone.
    @Test func normalizeSplitsNonAdjacentSameTag() {
        let result = WorkoutAI.normalizeSupersets([
            planned("A", group: 1),
            planned("B", group: 2),
            planned("C", group: 1),
        ])
        #expect(result.map(\.supersetGroup) == [nil, nil, nil])
    }
}

/// Serialized: each test spins up a `WorkoutManager`, which claims the process
/// -wide `WorkoutManager.shared` singleton and broadcasts over WatchConnectivity.
/// Running them concurrently races those singletons, so they go one at a time.
@MainActor
@Suite(.serialized)
struct SupersetSessionTests {

    private func withManager(_ body: (WorkoutManager, ModelContext) throws -> Void) throws {
        let schema = Schema([Exercise.self, WorkoutSession.self, ExerciseSet.self, PRRecord.self, Walk.self, Activity.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let manager = WorkoutManager(context: container.mainContext)
        try body(manager, container.mainContext)
        manager.stopRest()
        withExtendedLifetime(container) {}
    }

    /// Grouping two movements holds the rest timer until the round's last partner
    /// finishes, then fires once with the longer of the two rests.
    @Test func sharedRestIsSuppressedBetweenPartners() throws {
        try withManager { manager, context in
            let bench = Exercise(name: "Bench", muscleGroup: "Chest", defaultRestSeconds: 90)
            let row = Exercise(name: "Row", muscleGroup: "Lats", defaultRestSeconds: 120)
            [bench, row].forEach(context.insert)

            manager.startSession(named: "SS", exercises: [bench, row])
            manager.groupWithNextInSession(bench)
            #expect(manager.supersetTag(for: bench) != nil)
            #expect(manager.supersetTag(for: bench) == manager.supersetTag(for: row))

            // First partner: rest holds because the other partner is still up.
            manager.logSet(exercise: bench, weight: 135, reps: 8)
            #expect(manager.isResting == false)

            // Round complete: rest fires with the longer partner's value.
            manager.logSet(exercise: row, weight: 95, reps: 8)
            #expect(manager.restTotal == 120)
        }
    }

    /// Ungrouping dissolves a two-member superset entirely and restores each
    /// movement's own rest.
    @Test func ungroupRestoresStandaloneRest() throws {
        try withManager { manager, context in
            let bench = Exercise(name: "Bench", muscleGroup: "Chest", defaultRestSeconds: 90)
            let row = Exercise(name: "Row", muscleGroup: "Lats", defaultRestSeconds: 120)
            [bench, row].forEach(context.insert)

            manager.startSession(named: "SS", exercises: [bench, row])
            manager.groupWithNextInSession(bench)
            manager.ungroupSuperset(bench)
            #expect(manager.supersetTag(for: bench) == nil)
            #expect(manager.supersetTag(for: row) == nil)

            manager.logSet(exercise: bench, weight: 135, reps: 8)
            #expect(manager.restTotal == 90)
        }
    }

    /// A routine's supersets stamp onto every logged set and round-trip into the
    /// session's history grouping.
    @Test func routineSupersetsStampSetsAndGroupHistory() throws {
        try withManager { manager, context in
            let bench = Exercise(name: "Bench", muscleGroup: "Chest", defaultRestSeconds: 0)
            let row = Exercise(name: "Row", muscleGroup: "Lats", defaultRestSeconds: 0)
            [bench, row].forEach(context.insert)

            manager.startSession(named: "SS", exercises: [bench, row], supersets: [bench.id: 1, row.id: 1])
            manager.logSet(exercise: bench, weight: 135, reps: 8)
            manager.logSet(exercise: row, weight: 95, reps: 8)

            #expect(manager.sets(for: bench).first?.supersetGroup == 1)
            let session = try #require(manager.activeSession)
            #expect(session.exerciseGroups.count == 1)
            #expect(session.exerciseGroups.first?.count == 2)
        }
    }
}
