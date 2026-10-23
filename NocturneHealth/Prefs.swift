import Foundation
import Security

/// Small settings store shared by the UI and background syncs.
enum Prefs {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let baseURL = "baseURL"
        static let backfillDays = "backfillDays"
        static let healthRequested = "healthRequested"
        static let syncedThrough = "syncedThrough"
        static let workoutAnchor = "workoutAnchor"
        static let lastSyncAt = "lastSyncAt"
        static let lastSummary = "lastSummary"
        static let lastError = "lastError"
        static let lastErrorAt = "lastErrorAt"
    }

    static var baseURL: URL? {
        get { defaults.string(forKey: Key.baseURL).flatMap(URL.init(string:)) }
        set { defaults.set(newValue?.absoluteString, forKey: Key.baseURL) }
    }

    /// How far back the very first sync reaches.
    static var backfillDays: Int {
        get { let v = defaults.integer(forKey: Key.backfillDays); return v == 0 ? 30 : v }
        set { defaults.set(newValue, forKey: Key.backfillDays) }
    }

    /// Whether the Health permission sheet has been shown. HealthKit never says
    /// whether read access was granted, only that the person was asked.
    static var healthRequested: Bool {
        get { defaults.bool(forKey: Key.healthRequested) }
        set { defaults.set(newValue, forKey: Key.healthRequested) }
    }

    /// Steps and heart rate are uploaded up to this time.
    static var syncedThrough: Date? {
        get { defaults.object(forKey: Key.syncedThrough) as? Date }
        set { defaults.set(newValue, forKey: Key.syncedThrough) }
    }

    /// Archived HKQueryAnchor for workouts, so each sync only reads new ones.
    static var workoutAnchor: Data? {
        get { defaults.data(forKey: Key.workoutAnchor) }
        set { defaults.set(newValue, forKey: Key.workoutAnchor) }
    }

    static var lastSyncAt: Date? {
        get { defaults.object(forKey: Key.lastSyncAt) as? Date }
        set { defaults.set(newValue, forKey: Key.lastSyncAt) }
    }

    static var lastSummary: String? {
        get { defaults.string(forKey: Key.lastSummary) }
        set { defaults.set(newValue, forKey: Key.lastSummary) }
    }

    static var lastError: String? {
        get { defaults.string(forKey: Key.lastError) }
        set {
            defaults.set(newValue, forKey: Key.lastError)
            defaults.set(newValue == nil ? nil : Date(), forKey: Key.lastErrorAt)
        }
    }

    static var lastErrorAt: Date? { defaults.object(forKey: Key.lastErrorAt) as? Date }

    /// Forget sync progress so the next sync re-sends everything in the backfill
    /// window. Safe: Nocturne updates records it already has instead of duplicating.
    static func resetSyncProgress() {
        syncedThrough = nil
        workoutAnchor = nil
        lastSummary = nil
        lastError = nil
    }
}

/// Stores the Nocturne token in the iOS Keychain on this device only.
enum Keychain {
    private static let service = "NocturneHealth"
    private static let account = "apiToken"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func save(_ value: String) {
        SecItemDelete(baseQuery as CFDictionary)
        guard !value.isEmpty else { return }
        var add = baseQuery
        add[kSecValueData as String] = Data(value.utf8)
        // AfterFirstUnlock so background syncs can read it while the phone is locked.
        // ThisDeviceOnly: never synced to iCloud Keychain or restored to another phone.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
