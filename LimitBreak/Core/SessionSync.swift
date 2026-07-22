import Foundation
import OSLog
import SwiftData

#if canImport(ActivityKit)
import ActivityKit
#endif

private let laLog = Logger(subsystem: "limitbreak", category: "liveactivity")

/// Fans session-state changes out to every remote surface: the Live Activity
/// on the lock screen / Dynamic Island, and the watch app via WatchConnectivity.
@MainActor
final class SessionSync {
    static let shared = SessionSync()

    private init() {}

    // MARK: - Snapshot

    /// One source of truth for what remotes display, derived from the manager.
    func snapshot(from manager: WorkoutManager) -> WatchStateSnapshot {
        guard let session = manager.activeSession else { return .idle }

        let exercises = manager.sessionExercises.map { exercise in
            WatchExerciseSnapshot(
                id: exercise.id,
                name: exercise.name,
                muscle: exercise.muscleGroupRaw,
                done: manager.sets(for: exercise).count,
                target: manager.targetSets(for: exercise),
                nextLabel: nextLabel(for: exercise, manager: manager),
                isSkipped: manager.skippedExercises.contains(exercise.id)
            )
        }

        return WatchStateSnapshot(
            isActive: true,
            sessionName: session.name,
            exercises: exercises,
            currentExerciseID: manager.currentExercise?.id,
            restEndsAt: manager.restEndsAt,
            totalVolume: session.totalVolume,
            prCount: session.prCount
        )
    }

    /// What one-tap logging would record for this exercise, humanized.
    private func nextLabel(for exercise: Exercise, manager: WorkoutManager) -> String {
        let template = manager.lastSet(for: exercise)
            ?? exercise.sets.max(by: { $0.timestamp < $1.timestamp })
        switch exercise.trackingType {
        case .weightAndReps:
            return "\((template?.weight ?? 45).cleanWeight) lbs × \(template?.reps ?? 8)"
        case .bodyweightAndReps:
            let added = template?.weight ?? 0
            if added > 0 { return "BW+\(added.cleanWeight) × \(template?.reps ?? 8)" }
            if added < 0 { return "BW\(added.cleanWeight) × \(template?.reps ?? 8)" }
            return "BW × \(template?.reps ?? 8)"
        case .durationAndReps:
            return "\((template?.durationSeconds ?? 30).clockString) × \(template?.reps ?? 8)"
        case .timeAndDistance:
            return "\(Int(template?.distanceMeters ?? 1600)) m"
        case .customMetric:
            return "\((template?.weight ?? 0).cleanWeight) \(exercise.customMetricUnit ?? "") × \(template?.reps ?? 8)"
        }
    }

    // MARK: - Broadcast

    func broadcast(from manager: WorkoutManager) {
        let state = snapshot(from: manager)
        PhoneWatchBridge.shared.push(state: state)
        updateLiveActivity(with: state)
        WidgetSnapshotter.shared.refresh()
    }

    // MARK: - Live Activity

    #if canImport(ActivityKit)
    private var activity: ActivityKit.Activity<SessionActivityAttributes>?

    private func updateLiveActivity(with state: WatchStateSnapshot) {
        guard state.isActive else {
            endLiveActivity()
            return
        }

        let current = state.exercises.first { $0.id == state.currentExerciseID }
        let remaining = state.exercises.filter { !$0.isSkipped }
        let contentState = SessionActivityAttributes.ContentState(
            exerciseName: current?.name ?? "Session complete",
            exerciseDone: current?.done ?? 0,
            exerciseTarget: current?.target ?? 0,
            totalDone: remaining.reduce(0) { $0 + min($1.done, $1.target) },
            totalTarget: remaining.reduce(0) { $0 + $1.target },
            totalVolume: state.totalVolume,
            restEndsAt: state.restEndsAt,
            isComplete: state.currentExerciseID == nil
        )
        let content = ActivityContent(state: contentState, staleDate: nil)

        if let activity {
            Task { await activity.update(content) }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            do {
                activity = try ActivityKit.Activity.request(
                    attributes: SessionActivityAttributes(sessionName: state.sessionName),
                    content: content
                )
                laLog.info("Live Activity started: \(self.activity?.id ?? "nil", privacy: .public)")
            } catch {
                laLog.error("Live Activity request failed: \(error, privacy: .public)")
            }
        } else {
            laLog.error("Live Activities are not enabled on this device")
        }
    }

    private func endLiveActivity() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
    #else
    private func updateLiveActivity(with state: WatchStateSnapshot) {}
    #endif
}
