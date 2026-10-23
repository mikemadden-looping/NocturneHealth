import Foundation
import HealthKit

/// One fixed-length bucket of a quantity (steps summed, heart rate averaged).
struct HealthBucket {
    let start: Date
    let value: Double
}

/// New and removed workouts since the last sync.
struct WorkoutChanges {
    let added: [HKWorkout]
    let deletedIDs: [UUID]
    let anchor: HKQueryAnchor
}

enum HealthReaderError: LocalizedError {
    case unavailable
    case locked

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Apple Health isn't available on this device."
        case .locked: return "Apple Health is locked until the iPhone is unlocked."
        }
    }
}

/// Reads steps, heart rate and workouts from Apple Health.
final class HealthReader {
    static let shared = HealthReader()

    let store = HKHealthStore()
    let stepType = HKQuantityType(.stepCount)
    let heartRateType = HKQuantityType(.heartRate)
    let workoutType = HKObjectType.workoutType()

    /// Bucket length for steps and heart rate. Buckets start on fixed 5-minute
    /// boundaries so re-reading the same time range produces the same records.
    static let bucketMinutes = 5

    private var observing = false

    private var readTypes: Set<HKObjectType> {
        [
            stepType,
            heartRateType,
            workoutType,
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling),
            HKQuantityType(.distanceSwimming),
        ]
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization() async throws {
        guard isAvailable else { throw HealthReaderError.unavailable }
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    /// Step totals per bucket. Health merges iPhone and Watch so steps aren't double-counted.
    func stepBuckets(from: Date, to: Date) async throws -> [HealthBucket] {
        try await buckets(stepType, options: .cumulativeSum, unit: .count(), from: from, to: to)
    }

    /// Average heart rate per bucket.
    func heartRateBuckets(from: Date, to: Date) async throws -> [HealthBucket] {
        try await buckets(heartRateType, options: .discreteAverage,
                          unit: HKUnit.count().unitDivided(by: .minute()), from: from, to: to)
    }

    private func buckets(_ type: HKQuantityType, options: HKStatisticsOptions, unit: HKUnit,
                         from: Date, to: Date) async throws -> [HealthBucket] {
        let predicate = HKSamplePredicate.quantitySample(
            type: type,
            predicate: HKQuery.predicateForSamples(withStart: from, end: to)
        )
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: predicate,
            options: options,
            anchorDate: Date(timeIntervalSince1970: 0),
            intervalComponents: DateComponents(minute: Self.bucketMinutes)
        )
        let collection = try await run { try await descriptor.result(for: self.store) }
        return collection.statistics().compactMap { stats in
            let quantity = options.contains(.cumulativeSum) ? stats.sumQuantity() : stats.averageQuantity()
            guard let quantity else { return nil }
            return HealthBucket(start: stats.startDate, value: quantity.doubleValue(for: unit))
        }
    }

    /// Workouts added or deleted since `anchor`. With no anchor, every workout
    /// that started on or after `since`.
    func workoutChanges(since: Date, anchor: HKQueryAnchor?) async throws -> WorkoutChanges {
        let predicate = HKQuery.predicateForSamples(withStart: since, end: nil)
        let descriptor = HKAnchoredObjectQueryDescriptor(
            predicates: [.workout(predicate)],
            anchor: anchor
        )
        let result = try await run { try await descriptor.result(for: self.store) }
        return WorkoutChanges(
            added: result.addedSamples,
            deletedIDs: result.deletedObjects.map(\.uuid),
            anchor: result.newAnchor
        )
    }

    /// Turns HealthKit's "protected data" error into a clear locked-phone error.
    private func run<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as HKError where error.code == .errorDatabaseInaccessible {
            throw HealthReaderError.locked
        }
    }

    // MARK: Background delivery

    /// Asks HealthKit to wake the app when new steps, heart rate or workouts arrive.
    /// Must run on every launch, including background launches.
    func startObserving(onChange: @escaping () async -> Void) {
        guard isAvailable, !observing else { return }
        observing = true
        for type in [stepType, heartRateType, workoutType] as [HKSampleType] {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                guard error == nil else { completion(); return }
                Task {
                    await onChange()
                    completion()
                }
            }
            store.execute(query)
            // Workouts wake the app right away. Steps and heart rate arrive in a steady
            // trickle from the Watch, so hourly keeps background wake-ups (and battery) low;
            // HealthKit caps steps at hourly anyway. Opening the app always syncs fully.
            let frequency: HKUpdateFrequency = type == workoutType ? .immediate : .hourly
            store.enableBackgroundDelivery(for: type, frequency: frequency) { _, _ in }
        }
    }

    // MARK: Anchor storage

    static func archive(_ anchor: HKQueryAnchor) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    }

    static func unarchiveAnchor(_ data: Data?) -> HKQueryAnchor? {
        guard let data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }
}

extension HKWorkoutActivityType {
    /// A readable name for the activity, used as the Nocturne activity type.
    var displayName: String {
        switch self {
        case .walking: return "Walking"
        case .running: return "Running"
        case .cycling: return "Cycling"
        case .swimming: return "Swimming"
        case .hiking: return "Hiking"
        case .yoga: return "Yoga"
        case .pilates: return "Pilates"
        case .traditionalStrengthTraining: return "Strength Training"
        case .functionalStrengthTraining: return "Functional Strength Training"
        case .highIntensityIntervalTraining: return "HIIT"
        case .crossTraining: return "Cross Training"
        case .coreTraining: return "Core Training"
        case .elliptical: return "Elliptical"
        case .rowing: return "Rowing"
        case .stairClimbing, .stairs, .stepTraining: return "Stairs"
        case .socialDance, .cardioDance: return "Dance"
        case .tennis: return "Tennis"
        case .pickleball: return "Pickleball"
        case .golf: return "Golf"
        case .basketball: return "Basketball"
        case .soccer: return "Soccer"
        case .baseball, .softball: return "Baseball"
        case .americanFootball: return "Football"
        case .downhillSkiing: return "Skiing"
        case .snowboarding: return "Snowboarding"
        case .crossCountrySkiing: return "Cross-Country Skiing"
        case .paddleSports: return "Paddling"
        case .surfingSports: return "Surfing"
        case .climbing: return "Climbing"
        case .martialArts, .boxing, .kickboxing: return "Martial Arts"
        case .mindAndBody, .flexibility, .cooldown, .preparationAndRecovery: return "Mobility"
        case .mixedCardio: return "Mixed Cardio"
        case .wheelchairWalkPace, .wheelchairRunPace: return "Wheelchair"
        case .handCycling: return "Hand Cycling"
        default: return "Workout"
        }
    }
}
