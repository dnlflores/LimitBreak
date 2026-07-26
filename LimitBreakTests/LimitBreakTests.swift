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
        let entries: [(exercise: Exercise, sets: [PastSetEntry])] = [
            (bench, (0..<5).map { _ in PastSetEntry(weight: 200, reps: 5) })
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

        let entries: [(exercise: Exercise, sets: [PastSetEntry])] = [
            (bench, [PastSetEntry(weight: 185, reps: 5)])
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
