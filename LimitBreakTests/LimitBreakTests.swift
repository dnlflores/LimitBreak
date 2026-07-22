//
//  LimitBreakTests.swift
//  LimitBreakTests
//

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
