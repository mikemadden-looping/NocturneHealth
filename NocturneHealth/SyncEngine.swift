import Foundation
import HealthKit

extension Notification.Name {
    static let syncStatusChanged = Notification.Name("NocturneHealthSyncStatusChanged")
}

/// Copies Apple Health steps, heart rate and workouts into Nocturne.
///
/// Every record carries a stable sync identifier (the bucket start for steps and
/// heart rate, the HealthKit UUID for workouts), and Nocturne updates a record it
/// already has instead of adding another. So re-sending overlapping time is safe,
/// and the app re-sends the last few hours each time to pick up late Watch data.
actor SyncEngine {
    static let shared = SyncEngine()

    /// Data source name Nocturne stores with each record.
    static let dataSource = "apple-health"
    static let appName = "NocturneHealth"

    /// Re-read this much time before the last sync, for Watch data that syncs late.
    private let overlap: TimeInterval = 6 * 3600
    /// Work through history one day at a time, saving progress after each.
    private let chunk: TimeInterval = 24 * 3600

    private var running = false
    private var rerunRequested = false

    /// Runs a sync, or if one is already running, asks it to run once more when done.
    func sync() async {
        if running {
            rerunRequested = true
            return
        }
        running = true
        defer { running = false }
        repeat {
            rerunRequested = false
            await runOnce()
        } while rerunRequested
    }

    private func runOnce() async {
        let reader = HealthReader.shared
        guard Prefs.healthRequested, reader.isAvailable else { return }
        let api: NocturneAPI
        do { api = try NocturneAPI.configured() } catch { return }

        let now = Date()
        let backfillStart = now.addingTimeInterval(-Double(Prefs.backfillDays) * 86400)
        var steps = 0, heartRates = 0, workouts = 0

        do {
            // Steps and heart rate, a day at a time from where the last sync got to.
            var cursor = Self.floorToBucket(
                max(backfillStart, (Prefs.syncedThrough ?? backfillStart).addingTimeInterval(-overlap))
            )
            while cursor < now {
                let end = min(cursor.addingTimeInterval(chunk), now)
                let stepRecords = try await reader.stepBuckets(from: cursor, to: end)
                    .filter { $0.value >= 1 }
                    .map(Self.stepRecord)
                let hrRecords = try await reader.heartRateBuckets(from: cursor, to: end)
                    .filter { $0.value > 0 }
                    .map(Self.heartRateRecord)
                steps += try await api.post("api/v4/StepCount", stepRecords)
                heartRates += try await api.post("api/v4/HeartRate", hrRecords)
                Prefs.syncedThrough = end
                cursor = end
            }

            // Workouts: only ones added since the last sync.
            let changes = try await reader.workoutChanges(
                since: backfillStart,
                anchor: HealthReader.unarchiveAnchor(Prefs.workoutAnchor)
            )
            let workoutRecords = changes.added.map(Self.workoutRecord)
            workouts = try await api.post("api/v1/activity", workoutRecords)
            Prefs.workoutAnchor = HealthReader.archive(changes.anchor)

            Prefs.lastSyncAt = Date()
            Prefs.lastSummary = "Sent \(steps) step, \(heartRates) heart rate and \(workouts) workout records."
            Prefs.lastError = nil
        } catch HealthReaderError.locked {
            // Normal in the background; the next unlock or Health update will catch up.
            Prefs.lastSummary = steps + heartRates > 0
                ? "Sent \(steps) step and \(heartRates) heart rate records, then paused while the iPhone was locked."
                : Prefs.lastSummary
        } catch {
            Prefs.lastError = error.localizedDescription
        }
        await MainActor.run {
            NotificationCenter.default.post(name: .syncStatusChanged, object: nil)
        }
    }

    // MARK: Records

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func floorToBucket(_ date: Date) -> Date {
        let size = Double(HealthReader.bucketMinutes * 60)
        return Date(timeIntervalSince1970: (date.timeIntervalSince1970 / size).rounded(.down) * size)
    }

    private static func utcOffsetMinutes(_ date: Date) -> Int {
        TimeZone.current.secondsFromGMT(for: date) / 60
    }

    private static func bucketKey(_ prefix: String, _ date: Date) -> String {
        "\(prefix):\(Int(date.timeIntervalSince1970))"
    }

    /// Nocturne StepCount: `metric` is the steps in this 5-minute bucket (source 0 = a delta).
    private static func stepRecord(_ bucket: HealthBucket) -> [String: Any] {
        [
            "timestamp": iso.string(from: bucket.start),
            "utcOffset": utcOffsetMinutes(bucket.start),
            "metric": Int(bucket.value.rounded()),
            "source": 0,
            "device": "Apple Health",
            "app": appName,
            "dataSource": dataSource,
            "syncIdentifier": bucketKey("steps", bucket.start),
        ]
    }

    /// Nocturne HeartRate: average bpm over the 5-minute bucket.
    private static func heartRateRecord(_ bucket: HealthBucket) -> [String: Any] {
        [
            "timestamp": iso.string(from: bucket.start),
            "utcOffset": utcOffsetMinutes(bucket.start),
            "bpm": Int(bucket.value.rounded()),
            "accuracy": 0,
            "device": "Apple Health",
            "app": appName,
            "dataSource": dataSource,
            "syncIdentifier": bucketKey("hr", bucket.start),
        ]
    }

    /// Nightscout-style activity. Nocturne files these as exercise periods, and
    /// uses `_id` to update the same workout instead of adding a duplicate.
    private static func workoutRecord(_ workout: HKWorkout) -> [String: Any] {
        var record: [String: Any] = [
            "_id": "healthkit-\(workout.uuid.uuidString.lowercased())",
            "mills": Int64(workout.startDate.timeIntervalSince1970 * 1000),
            "created_at": iso.string(from: workout.startDate),
            "utcOffset": utcOffsetMinutes(workout.startDate),
            "type": workout.workoutActivityType.displayName,
            "duration": (workout.duration / 60 * 10).rounded() / 10,
            "enteredBy": appName,
            "data_source": dataSource,
        ]
        if let kcal = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
            .sumQuantity()?.doubleValue(for: .kilocalorie()), kcal > 0 {
            record["energy"] = kcal.rounded()
            record["energyUnits"] = "kcal"
        }
        for type in [HKQuantityType(.distanceWalkingRunning),
                     HKQuantityType(.distanceCycling),
                     HKQuantityType(.distanceSwimming)] {
            if let meters = workout.statistics(for: type)?.sumQuantity()?.doubleValue(for: .meter()),
               meters > 0 {
                record["distance"] = (meters / 10).rounded() / 100 // km, 2 decimals
                record["distanceUnits"] = "km"
                break
            }
        }
        record["notes"] = "From \(workout.sourceRevision.source.name)"
        return record
    }
}
