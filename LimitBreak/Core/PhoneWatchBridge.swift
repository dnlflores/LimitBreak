import Foundation
import SwiftData
import WatchConnectivity

/// Phone side of the watch link. The watch is a thin remote: it sends commands
/// here, this bridge executes them on the WorkoutManager, and the resulting
/// state snapshot flows back (as the message reply and via application context).
final class PhoneWatchBridge: NSObject, WCSessionDelegate {
    @MainActor static let shared = PhoneWatchBridge()

    private var modelContext: ModelContext?

    @MainActor
    func configure(context: ModelContext) {
        modelContext = context
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - Outbound state

    @MainActor
    func push(state: WatchStateSnapshot) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        var contextPayload: [String: Any] = [:]
        if let stateData = WatchLink.encode(state) {
            contextPayload[WatchLink.stateKey] = stateData
        }
        if let routinesData = WatchLink.encode(routineSummaries()) {
            contextPayload[WatchLink.routinesKey] = routinesData
        }
        try? WCSession.default.updateApplicationContext(contextPayload)
    }

    @MainActor
    private func routineSummaries() -> [WatchRoutineSummary] {
        guard let modelContext else { return [] }
        let routines = (try? modelContext.fetch(FetchDescriptor<Routine>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        ))) ?? []
        return routines.map {
            WatchRoutineSummary(
                id: $0.id,
                name: $0.name,
                exerciseCount: $0.orderedItems.count,
                isAIGenerated: $0.isAIGenerated
            )
        }
    }

    // MARK: - Command handling

    @MainActor
    private func handle(_ command: WatchCommand) async {
        guard let manager = WorkoutManager.shared else { return }
        switch command.kind {
        case .requestState:
            break // reply carries the snapshot
        case .startRoutine:
            guard manager.activeSession == nil,
                  let routineID = command.routineID,
                  let modelContext else { break }
            let routines = (try? modelContext.fetch(FetchDescriptor<Routine>())) ?? []
            if let routine = routines.first(where: { $0.id == routineID }) {
                manager.startSession(from: routine)
            }
        case .startAIWorkout:
            guard manager.activeSession == nil else { break }
            await startAIWorkout(manager: manager)
        case .logNextSet:
            manager.logNextSetInOrder()
        case .nextExercise:
            manager.advanceToNextExercise()
        case .endSession:
            manager.endSession()
        }
    }

    /// One-tap AI workout from the wrist: a full-body plan built on-device.
    @MainActor
    private func startAIWorkout(manager: WorkoutManager) async {
        guard let modelContext else { return }
        let all = (try? modelContext.fetch(FetchDescriptor<Exercise>())) ?? []
        guard !all.isEmpty else { return }

        let catalog = all.map {
            ExerciseBrief(name: $0.name, muscleGroups: $0.allMuscleGroups.map(\.rawValue), equipment: $0.equipmentType)
        }
        let plan = await WorkoutAI.generatePlan(
            focusLabel: "Full Body",
            targetMuscleGroups: MuscleGroup.allCases.map(\.rawValue),
            exerciseCount: 5,
            durationMinutes: nil,
            catalog: catalog
        )

        var exercises: [Exercise] = []
        var targets: [UUID: Int] = [:]
        for planned in plan.exercises {
            guard let match = all.first(where: { $0.name == planned.name }) else { continue }
            exercises.append(match)
            targets[match.id] = max(1, planned.sets)
        }
        guard !exercises.isEmpty else { return }
        manager.startSession(named: plan.title, exercises: exercises, targets: targets)
    }

    // MARK: - WCSessionDelegate

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated else { return }
        Task { @MainActor in
            if let manager = WorkoutManager.shared {
                self.push(state: SessionSync.shared.snapshot(from: manager))
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let commandData = message[WatchLink.commandKey] as? Data
        Task { @MainActor in
            if let command = WatchLink.decode(WatchCommand.self, from: commandData) {
                await self.handle(command)
            }
            var reply: [String: Any] = [:]
            if let manager = WorkoutManager.shared,
               let data = WatchLink.encode(SessionSync.shared.snapshot(from: manager)) {
                reply[WatchLink.stateKey] = data
            }
            if let routinesData = WatchLink.encode(self.routineSummaries()) {
                reply[WatchLink.routinesKey] = routinesData
            }
            replyHandler(reply)
        }
    }
}
