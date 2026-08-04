import CoreData
import Foundation
import SwiftData

/// Reconciles the duplicates that CloudKit mirroring can introduce.
///
/// Almost every record carries a stable UUID minted once at creation, so it
/// syncs as the *same* row on every device. Two kinds of data are instead
/// recreated independently on each device, and so can double up once two
/// devices sync the same iCloud account:
///
/// - The bundled exercise catalog, seeded on first launch (`ExerciseCatalog`).
///   A fresh install seeds its ~265 defaults immediately, which can happen
///   before the initial CloudKit import of the other device's catalog lands —
///   leaving two same-named copies with different ids.
/// - The singleton `TrainingProfile`, created on demand on each device.
///
/// This collapses each back down to one. It's safe to run repeatedly and it
/// converges without coordination: every synced device sees the same full set
/// of duplicates and picks the same survivor by a device-independent rule (the
/// lowest id), so they all delete the same losers.
@MainActor
enum CloudSyncDedupe {

    /// Merge duplicate default exercises and training profiles into one each.
    static func run(context: ModelContext) {
        dedupeExercises(context: context)
        dedupeProfiles(context: context)
    }

    /// Re-run `run(context:)` shortly after CloudKit merges remote changes, so
    /// the seeding race self-heals within the session instead of waiting for the
    /// next launch. Bursts of change notifications during the initial import are
    /// coalesced into a single pass. Installing the observer is idempotent.
    static func startObserving(context: ModelContext) {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard !passScheduled else { return }
                passScheduled = true
                Task { @MainActor in
                    // Let a burst of import batches settle before reconciling.
                    try? await Task.sleep(for: .seconds(2))
                    passScheduled = false
                    run(context: context)
                }
            }
        }
    }

    private static var observing = false
    private static var passScheduled = false

    // MARK: - Exercises

    private static func dedupeExercises(context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<Exercise>())) ?? []
        // Only catalog defaults are seeded on every device; custom exercises are
        // user-made and one-of-a-kind, so they're never touched.
        var byName: [String: [Exercise]] = [:]
        for exercise in all where !exercise.isCustom {
            byName[exercise.name.lowercased(), default: []].append(exercise)
        }

        var changed = false
        for group in byName.values where group.count > 1 {
            // Canonical survivor: the lowest id string — identical on every
            // synced device, so all devices converge on the same winner.
            let ordered = group.sorted { $0.id.uuidString < $1.id.uuidString }
            let winner = ordered[0]
            for loser in ordered.dropFirst() {
                // Repoint history onto the survivor before deleting the loser so
                // no logged set, record, or routine slot is orphaned.
                for set in loser.sets { set.exercise = winner }
                for record in loser.prRecords { record.exercise = winner }
                for item in loser.routineItems { item.exercise = winner }
                context.delete(loser)
                changed = true
            }
        }
        if changed { try? context.save() }
    }

    // MARK: - Training profile

    private static func dedupeProfiles(context: ModelContext) {
        let profiles = (try? context.fetch(FetchDescriptor<TrainingProfile>())) ?? []
        guard profiles.count > 1 else { return }
        // Keep the most recently edited profile so the lifter's latest settings
        // win; break ties by id so every device keeps the same one.
        let survivor = profiles.sorted {
            ($0.updatedAt, $0.id.uuidString) > ($1.updatedAt, $1.id.uuidString)
        }[0]
        for profile in profiles where profile !== survivor {
            context.delete(profile)
        }
        try? context.save()
    }
}
