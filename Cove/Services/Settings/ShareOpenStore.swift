import Foundation

/// Local "last opened" timestamps for shares, keyed by server id + share
/// name so same-named shares on different servers never collide. Pure
/// value layer factored out of the UserDefaults shell for unit testing
/// (same discipline as `LibraryNavigationPath`).
///
/// Entries are display-level data only (share name + timestamp, no
/// secrets), so `UserDefaults` is the sanctioned home (AGENTS.md rule 5).
struct ShareOpenRecords: Equatable, Sendable {
    private(set) var entries: [String: Date] = [:]

    init() {}

    /// Rebuilds from the persisted plist form (epoch seconds per key).
    init(dictionary: [String: Double]) {
        entries = dictionary.mapValues { Date(timeIntervalSince1970: $0) }
    }

    /// Persisted plist form: epoch seconds per key.
    var dictionary: [String: Double] {
        entries.mapValues(\.timeIntervalSince1970)
    }

    /// Stable record key: the server UUID can never contain "|", so the
    /// server segment is unambiguous when pruning by prefix.
    static func key(serverID: UUID, share: String) -> String {
        "\(serverID.uuidString)|\(share)"
    }

    func lastOpened(serverID: UUID, share: String) -> Date? {
        entries[Self.key(serverID: serverID, share: share)]
    }

    mutating func recordOpen(serverID: UUID, share: String, at date: Date) {
        entries[Self.key(serverID: serverID, share: share)] = date
    }

    /// Drops every entry of a removed server: once the id is gone the
    /// records can never be shown again, so they are pruned eagerly
    /// instead of rotting in the defaults.
    mutating func removeServer(_ serverID: UUID) {
        let prefix = "\(serverID.uuidString)|"
        entries = entries.filter { !$0.key.hasPrefix(prefix) }
    }
}

/// UserDefaults persistence shell over `ShareOpenRecords`; same pattern
/// as `SettingsService` / `PlaybackProgressStore` (injected defaults and
/// clock so tests run on isolated suites with deterministic timestamps).
@MainActor
final class ShareOpenStore {
    private enum Keys {
        static let entries = "cove.shareOpenRecords.entries"
    }

    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
    }

    func lastOpened(forServer serverID: UUID, share: String) -> Date? {
        load().lastOpened(serverID: serverID, share: share)
    }

    func recordOpen(forServer serverID: UUID, share: String) {
        var records = load()
        records.recordOpen(serverID: serverID, share: share, at: now())
        save(records)
    }

    func removeRecords(forServer serverID: UUID) {
        var records = load()
        records.removeServer(serverID)
        save(records)
    }

    private func load() -> ShareOpenRecords {
        ShareOpenRecords(dictionary: defaults.dictionary(forKey: Keys.entries) as? [String: Double] ?? [:])
    }

    private func save(_ records: ShareOpenRecords) {
        defaults.set(records.dictionary, forKey: Keys.entries)
    }
}
