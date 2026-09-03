import Foundation

/// Settings service backed by UserDefaults (cache budget, preheat behavior).
///
/// Only non-secret values live here — credentials stay in the Keychain
/// (AGENTS.md rule 4). Every mutation notifies observers registered via
/// `addChangeObserver`; interested services re-apply their policy live.
@MainActor
final class SettingsService {
    /// Observers invoked on the main actor after any setting changes.
    private var changeObservers: [@MainActor () -> Void] = []

    private enum Keys {
        static let cacheCapacityGB = "cove.settings.cacheCapacityGB"
        static let cacheTTLDays = "cove.settings.cacheTTLDays"
        static let preheatEnabled = "cove.settings.preheatEnabled"
        static let preheatRateLimitMBps = "cove.settings.preheatRateLimitMBps"
        static let preheatFolders = "cove.settings.preheatFolders"
        static let vaultRootBookmark = "cove.settings.vaultRootBookmark"
        static let readerModeComic = "cove.settings.readerMode.comic"
        static let readerModeDirectory = "cove.settings.readerMode.directory"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
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

    /// Security-scoped bookmark of the user-chosen vault root; nil means
    /// the default container location (`Application Support/Cove/Vault`).
    /// Stored instead of a plain path so a sandboxed relaunch keeps access
    /// to a user-selected directory.
    var vaultRootBookmark: Data? {
        get { defaults.data(forKey: Keys.vaultRootBookmark) }
        set { defaults.set(newValue, forKey: Keys.vaultRootBookmark); post() }
    }

    /// The user's last-chosen reader mode ("paged"/"strip") for one content
    /// kind; nil means no override and the kind's default applies. Raw
    /// strings only — mapping to `ReaderMode` stays at the coordinator so
    /// Services never depends on a Features type (dependency direction).
    func readerModeRawValue(forComic comic: Bool) -> String? {
        defaults.string(forKey: comic ? Keys.readerModeComic : Keys.readerModeDirectory)
    }

    func setReaderModeRawValue(_ rawValue: String, forComic comic: Bool) {
        defaults.set(rawValue, forKey: comic ? Keys.readerModeComic : Keys.readerModeDirectory)
        post()
    }

    var cacheCapacityBytes: Int64 { Int64(cacheCapacityGB) * 1024 * 1024 * 1024 }
    var cacheTTL: TimeInterval { TimeInterval(cacheTTLDays) * 24 * 60 * 60 }

    /// Registers an observer called on the main actor after any setting
    /// mutation. Retained for the lifetime of this service; observers
    /// should capture their owner weakly.
    func addChangeObserver(_ observer: @escaping @MainActor () -> Void) {
        changeObservers.append(observer)
    }

    private func post() {
        for observer in changeObservers {
            observer()
        }
    }
}
