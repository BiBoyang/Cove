import Foundation

/// Progress persistence boundary for the player. The view model holds this
/// protocol so tests can substitute an in-memory recorder. Three methods
/// only by decision: the recent-watches read API (`allEntries`) lives on
/// the concrete store, not here.
@MainActor
protocol PlaybackProgressStoring: AnyObject {
    /// Seconds into the video, or nil when nothing was recorded.
    func position(forKey key: String) -> Double?
    /// `duration` (total seconds) rides along so the continue-watching
    /// strip can render a progress bar without reopening the file.
    func savePosition(_ position: Double, forKey key: String, duration: Double)
    func removePosition(forKey key: String)
}

/// One stored resume record, the read model for the recent-watches list.
/// Pure values, no platform types (AGENTS.md rule 16).
struct PlaybackProgressEntry: Equatable, Sendable {
    /// Store key, "sourceID|path"; cleanup removes records by this key.
    let key: String
    /// Resume point in seconds.
    let position: Double
    /// Total seconds; nil on records written before the store kept
    /// durations, so old entries degrade gracefully (decision 1).
    let duration: Double?
    let lastWatched: Date
}

/// Remembers how far each video was watched, keyed by "sourceID|path" so
/// same-named files on different servers never collide. Backed by a
/// UserDefaults dictionary (small non-secret values, AGENTS.md rule 5).
///
/// Entries carry a `lastWatched` timestamp; once the store exceeds
/// `capacity` entries the least recently written one is evicted (the
/// simplest LRU that covers a watch history). Records for finished videos
/// are deleted by the caller, so the 200-entry cap is a backstop, not the
/// primary cleanup path.
@MainActor
final class PlaybackProgressStore: PlaybackProgressStoring {
    static let defaultCapacity = 200

    private enum Keys {
        static let entries = "cove.playbackProgress.entries"
    }

    private enum Field {
        static let position = "position"
        static let duration = "duration"
        static let lastWatched = "lastWatched"
    }

    private let defaults: UserDefaults
    private let capacity: Int
    /// Clock injection so eviction tests can order entries deterministically.
    private let now: () -> Date

    init(
        defaults: UserDefaults = .standard,
        capacity: Int = PlaybackProgressStore.defaultCapacity,
        now: @escaping () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.capacity = capacity
        self.now = now
    }

    func position(forKey key: String) -> Double? {
        entries()[key]?[Field.position]
    }

    func savePosition(_ position: Double, forKey key: String, duration: Double) {
        var entries = entries()
        entries[key] = [
            Field.position: position,
            Field.duration: duration,
            Field.lastWatched: now().timeIntervalSince1970,
        ]
        while entries.count > capacity {
            guard let oldest = entries.min(by: { ($0.value[Field.lastWatched] ?? 0) < ($1.value[Field.lastWatched] ?? 0) })?.key else {
                break
            }
            entries.removeValue(forKey: oldest)
        }
        defaults.set(entries, forKey: Keys.entries)
    }

    func removePosition(forKey key: String) {
        var entries = entries()
        guard entries.removeValue(forKey: key) != nil else { return }
        defaults.set(entries, forKey: Keys.entries)
    }

    /// Every stored record, for the recent-watches list. Tolerates the
    /// pre-duration format (duration reads as nil — decision 1) and skips
    /// entries with no position field, so one malformed entry can never
    /// hide the rest of the history.
    func allEntries() -> [PlaybackProgressEntry] {
        entries().compactMap { key, fields in
            guard let position = fields[Field.position] else { return nil }
            return PlaybackProgressEntry(
                key: key,
                position: position,
                duration: fields[Field.duration],
                lastWatched: Date(timeIntervalSince1970: fields[Field.lastWatched] ?? 0)
            )
        }
    }

    private func entries() -> [String: [String: Double]] {
        defaults.dictionary(forKey: Keys.entries) as? [String: [String: Double]] ?? [:]
    }
}
