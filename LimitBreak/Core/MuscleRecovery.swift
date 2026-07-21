import Foundation
import SwiftUI

/// How "fresh" a muscle group is, based on when it was last trained.
enum FreshnessState: String {
    case needsRest = "Needs Rest"   // trained < 24h ago
    case recovering = "Recovering"  // trained 24-48h ago
    case ready = "Ready"            // trained 48h-7d ago, recovered
    case dormant = "Dormant"        // not trained in the last 7 days

    var color: Color {
        switch self {
        case .needsRest:  Theme.crimson
        case .recovering: Theme.coral
        case .ready:      Theme.teal
        case .dormant:    Theme.cobalt.opacity(0.45)
        }
    }
}

/// Aggregated recent-training telemetry for one muscle group.
struct MuscleStatus {
    let group: MuscleGroup
    var lastTrained: Date?
    var weeklySets: Int = 0
    var weeklyVolume: Double = 0

    func state(now: Date = Date()) -> FreshnessState {
        guard let lastTrained else { return .dormant }
        let hours = now.timeIntervalSince(lastTrained) / 3600
        if hours < 24 { return .needsRest }
        if hours < 48 { return .recovering }
        if hours < 24 * 7 { return .ready }
        return .dormant
    }
}

/// Computes per-muscle-group freshness from the last week of logged sets.
/// A set counts toward its exercise's primary muscle group and all secondaries.
enum MuscleRecovery {
    static func statuses(sessions: [WorkoutSession], now: Date = Date()) -> [MuscleGroup: MuscleStatus] {
        var result: [MuscleGroup: MuscleStatus] = [:]
        for group in MuscleGroup.allCases {
            result[group] = MuscleStatus(group: group)
        }

        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        for session in sessions where session.startDate >= weekAgo {
            for set in session.sets where !set.isWarmup {
                guard let exercise = set.exercise, set.timestamp <= now else { continue }
                for group in exercise.allMuscleGroups {
                    var status = result[group] ?? MuscleStatus(group: group)
                    status.weeklySets += 1
                    status.weeklyVolume += set.weight * Double(set.reps)
                    if status.lastTrained.map({ set.timestamp > $0 }) ?? true {
                        status.lastTrained = set.timestamp
                    }
                    result[group] = status
                }
            }
        }
        return result
    }

    /// Share of muscle groups that have been trained this week and are recovered.
    static func readyFraction(statuses: [MuscleGroup: MuscleStatus], now: Date = Date()) -> Double {
        let trained = statuses.values.filter { $0.lastTrained != nil }
        guard !trained.isEmpty else { return 1 }
        let ready = trained.filter { $0.state(now: now) == .ready }.count
        return Double(ready) / Double(trained.count)
    }
}
