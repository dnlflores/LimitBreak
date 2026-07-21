import Foundation
import HealthKit
import CoreLocation
import Observation

/// Bridges LimitBreak to Apple Health: writes strength sessions and walks
/// (with hand-drawn routes) to HealthKit, and reads daily activity stats.
@MainActor
@Observable
final class HealthKitManager {
    static let shared = HealthKitManager()

    private let store = HKHealthStore()
    private static let connectedKey = "healthKitConnected"
    private static let autoSyncKey = "healthKitAutoSync"

    var isConnected: Bool
    var autoSync: Bool {
        didSet { UserDefaults.standard.set(autoSync, forKey: Self.autoSyncKey) }
    }
    var todaySteps: Double?
    var todayActiveEnergy: Double?
    var lastError: String?

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private init() {
        isConnected = UserDefaults.standard.bool(forKey: Self.connectedKey)
        autoSync = UserDefaults.standard.object(forKey: Self.autoSyncKey) as? Bool ?? true
    }

    // MARK: - Authorization

    func connect() async {
        guard isAvailable else {
            lastError = "Health data isn't available on this device."
            return
        }
        let share: Set<HKSampleType> = [
            .workoutType(),
            HKSeriesType.workoutRoute(),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.activeEnergyBurned),
        ]
        let read: Set<HKObjectType> = [
            .workoutType(),
            HKQuantityType(.stepCount),
            HKQuantityType(.activeEnergyBurned),
        ]
        do {
            try await store.requestAuthorization(toShare: share, read: read)
            isConnected = true
            UserDefaults.standard.set(true, forKey: Self.connectedKey)
            lastError = nil
            await refreshTodayStats()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Reading daily activity

    func refreshTodayStats() async {
        guard isConnected else { return }
        todaySteps = await todaySum(for: HKQuantityType(.stepCount), unit: .count())
        todayActiveEnergy = await todaySum(for: HKQuantityType(.activeEnergyBurned), unit: .kilocalorie())
    }

    private func todaySum(for type: HKQuantityType, unit: HKUnit) async -> Double? {
        let start = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date())
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, statistics, _ in
                continuation.resume(returning: statistics?.sumQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    // MARK: - Writing workouts

    /// Fire-and-forget sync used by WorkoutManager when a session ends.
    func syncIfEnabled(session: WorkoutSession) {
        guard isConnected, autoSync else { return }
        Task { await saveStrengthSession(session) }
    }

    func syncIfEnabled(walk: Walk) {
        guard isConnected, autoSync else { return }
        Task { await saveWalk(walk) }
    }

    func saveStrengthSession(_ session: WorkoutSession) async {
        let start = session.startDate
        let end = session.endDate ?? start.addingTimeInterval(max(session.duration, 60))

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining

        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        do {
            try await builder.beginCollection(at: start)
            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func saveWalk(_ walk: Walk) async {
        let start = walk.date
        // Fall back to a 20 min/mile pace when the user didn't enter a duration.
        let duration = walk.durationSeconds > 0
            ? walk.durationSeconds
            : max(walk.distanceMiles * 20 * 60, 60)
        let end = start.addingTimeInterval(duration)

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .walking

        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        do {
            try await builder.beginCollection(at: start)
            if walk.distanceMeters > 0 {
                let sample = HKQuantitySample(
                    type: HKQuantityType(.distanceWalkingRunning),
                    quantity: HKQuantity(unit: .meter(), doubleValue: walk.distanceMeters),
                    start: start,
                    end: end
                )
                try await builder.addSamples([sample])
            }
            try await builder.endCollection(at: end)
            let workout = try await builder.finishWorkout()

            if walk.routePoints.count >= 2, let workout {
                // Spread the drawn points across the walk's duration so the
                // route timestamps line up with the workout interval.
                let step = duration / Double(walk.routePoints.count - 1)
                let locations = walk.routePoints.enumerated().map { index, point in
                    CLLocation(
                        coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                        altitude: 0,
                        horizontalAccuracy: 10,
                        verticalAccuracy: -1,
                        timestamp: start.addingTimeInterval(Double(index) * step)
                    )
                }
                let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: nil)
                try await routeBuilder.insertRouteData(locations)
                _ = try await routeBuilder.finishRoute(with: workout, metadata: nil)
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
