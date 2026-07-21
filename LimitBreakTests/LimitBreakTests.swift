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
        let event = harness.manager.logSet(exercise: pullUp, weight: 0, reps: 12)

        #expect(event?.recordType == "Max Reps")
        #expect(event?.newValue == 12)
    }
}
