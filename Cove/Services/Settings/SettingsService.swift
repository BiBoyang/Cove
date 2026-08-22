import Foundation

/// Settings service backed by UserDefaults (cache budget, preheat behavior).
///
/// Only non-secret values live here — credentials stay in the Keychain
/// (AGENTS.md rule 4). Every mutation posts `SettingsService.didChange`;
/// interested services observe it and re-apply their policy live.
@MainActor
final class SettingsService {
    static let shared = SettingsService()

    /// Posted on the main actor after any setting changes.
    static let didChange = Notification.Name("CoveSettingsDidChange")

    private enum Keys {
        static let cacheCapacityGB = "cove.settings.cacheCapacityGB"
        static let cacheTTLDays = "cove.settings.cacheTTLDays"
        static let preheatEnabled = "cove.settings.preheatEnabled"
        static let preheatRateLimitMBps = "cove.settings.preheatRateLimitMBps"
        static let preheatFolders = "cove.settings.preheatFolders"
    }

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.cacheCapacityGB: 20,
            Keys.cacheTTLDays: 7,
            Keys.preheatEnabled: true,
            Keys.preheatRateLimitMBps: 0.0,
            Keys.preheatFolders: [String](),
        ])
    }

    /// Cache budget in GB, clamped to ≥ 1.
    var cacheCapacityGB: Int {
        get { max(1, defaults.integer(forKey: Keys.cacheCapacityGB)) }
        set { defaults.set(max(1, newValue), forKey: Keys.cacheCapacityGB); post() }
    }

    /// Cache entry lifetime in days, clamped to ≥ 1.
    var cacheTTLDays: Int {
        get { max(1, defaults.integer(forKey: Keys.cacheTTLDays)) }
        set { defaults.set(max(1, newValue), forKey: Keys.cacheTTLDays); post() }
    }

    var preheatEnabled: Bool {
        get { defaults.bool(forKey: Keys.preheatEnabled) }
        set { defaults.set(newValue, forKey: Keys.preheatEnabled); post() }
    }

    /// Network read budget for preheating in MB/s; 0 means unlimited.
    var preheatRateLimitMBps: Double {
        get { max(0, defaults.double(forKey: Keys.preheatRateLimitMBps)) }
        set { defaults.set(max(0, newValue), forKey: Keys.preheatRateLimitMBps); post() }
    }

    /// Folders to preheat, written share name first: "share/sub/dir".
    /// Only entries matching the currently connected share are preheated.
    var preheatFolders: [String] {
        get { defaults.stringArray(forKey: Keys.preheatFolders) ?? [] }
        set { defaults.set(newValue, forKey: Keys.preheatFolders); post() }
    }

    var cacheCapacityBytes: Int64 { Int64(cacheCapacityGB) * 1024 * 1024 * 1024 }
    var cacheTTL: TimeInterval { TimeInterval(cacheTTLDays) * 24 * 60 * 60 }

    private func post() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
