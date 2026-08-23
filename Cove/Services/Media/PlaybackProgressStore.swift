import Foundation

/// Progress persistence boundary for the player. The view model holds this
/// protocol so tests can substitute an in-memory recorder.
@MainActor
protocol PlaybackProgressStoring: AnyObject {
    /// Seconds into the video, or nil when nothing was recorded.
    func position(forKey key: String) -> Double?
    func savePosition(_ position: Double, forKey key: String)
    func removePosition(forKey key: String)
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

    func savePosition(_ position: Double, forKey key: String) {
        var entries = entries()
        entries[key] = [Field.position: position, Field.lastWatched: now().timeIntervalSince1970]
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

    private func entries() -> [String: [String: Double]] {
        defaults.dictionary(forKey: Keys.entries) as? [String: [String: Double]] ?? [:]
    }
}
