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
    /// File size in bytes and the source's modification date at watch time;
    /// nil on records written before the store kept them (TASK-video-
    /// thumbnails). They pin the video-thumbnail cache key, so a missing
    /// pair degrades the home card to the film icon instead of a stale
    /// cover.
    let fileSize: Int64?
    let modifiedDate: Date?
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
        static let fileSize = "fileSize"
        static let modified = "modified"
    }

    private let defaults: UserDefaults
    private let capacity: Int
    /// Clock injection so eviction tests can order entries deterministically.
    private let now: () -> Date
    /// File facts for the key the live player session has open, supplied by
    /// the player coordinator when it builds a session (it owns the
    /// `ContentItem`; the view model's persistence protocol stays three
    /// methods). Merged into the record by `savePosition`; keyed so a stale
    /// annotation from a dead session can never relabel another key's save.
    private var annotatedFacts: [String: (size: Int64, modified: Date?)] = [:]

    init(
        defaults: UserDefaults = .standard,
        capacity: Int = PlaybackProgressStore.defaultCapacity,
        now: @escaping () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.capacity = capacity
        self.now = now
    }

    /// Records the file facts of the video the player is about to open.
    /// Purely an in-memory annotation: the next `savePosition` under this
    /// key persists them (and an already-stored record is upgraded in
    /// place, so a resumed legacy record gains the fields during the very
    /// session that opened it).
    func setFileFacts(size: Int64, modified: Date?, forKey key: String) {
        annotatedFacts[key] = (size, modified)
        var entries = entries()
        guard entries[key]?[Field.position] != nil else { return }
        entries[key]?[Field.fileSize] = Double(size)
        if let modified {
            entries[key]?[Field.modified] = modified.timeIntervalSince1970
        }
        defaults.set(entries, forKey: Keys.entries)
    }

    func position(forKey key: String) -> Double? {
        entries()[key]?[Field.position]
    }

    func savePosition(_ position: Double, forKey key: String, duration: Double) {
        var entries = entries()
        var fields: [String: Double] = [
            Field.position: position,
            Field.duration: duration,
            Field.lastWatched: now().timeIntervalSince1970,
        ]
        if let facts = annotatedFacts[key] {
            fields[Field.fileSize] = Double(facts.size)
            if let modified = facts.modified {
                fields[Field.modified] = modified.timeIntervalSince1970
            }
        } else if let existing = entries[key] {
            // Keep facts across throttled rewrites of the same record when
            // no live session re-annotated them (defensive; the coordinator
            // annotates every open).
            if let size = existing[Field.fileSize] { fields[Field.fileSize] = size }
            if let modified = existing[Field.modified] { fields[Field.modified] = modified }
        }
        entries[key] = fields
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
    /// pre-duration and pre-facts formats (nil fields — decision 1,
    /// TASK-video-thumbnails) and skips entries with no position field, so
    /// one malformed entry can never hide the rest of the history.
    func allEntries() -> [PlaybackProgressEntry] {
        entries().compactMap { key, fields in
            guard let position = fields[Field.position] else { return nil }
            return PlaybackProgressEntry(
                key: key,
                position: position,
                duration: fields[Field.duration],
                fileSize: fields[Field.fileSize].map(Int64.init),
                modifiedDate: fields[Field.modified].map(Date.init(timeIntervalSince1970:)),
                lastWatched: Date(timeIntervalSince1970: fields[Field.lastWatched] ?? 0)
            )
        }
    }

    private func entries() -> [String: [String: Double]] {
        defaults.dictionary(forKey: Keys.entries) as? [String: [String: Double]] ?? [:]
    }
}
