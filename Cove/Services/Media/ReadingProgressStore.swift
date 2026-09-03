import Foundation

/// Progress persistence boundary for the reader. The view model holds this
/// protocol so tests can substitute an in-memory recorder.
@MainActor
protocol ReadingProgressStoring: AnyObject {
    /// Last-remembered page index, or nil when nothing was recorded.
    func page(forKey key: String) -> Int?
    func savePage(_ page: Int, forKey key: String)
    func removePage(forKey key: String)
}

/// Remembers the last-read page per comic/directory, keyed by "sourceID|path"
/// so same-named folders on different servers never collide. Backed by a
/// UserDefaults dictionary (small non-secret values, AGENTS.md rule 5).
///
/// Entries carry a `lastWatched` timestamp; once the store exceeds
/// `capacity` entries the least recently written one is evicted (the
/// simplest LRU that covers a reading history). Records for comics the
/// user finished (reached the last page) are deleted by the caller, so the
/// 200-entry cap is a backstop, not the primary cleanup path.
@MainActor
final class ReadingProgressStore: ReadingProgressStoring {
    static let defaultCapacity = 200

    private enum Keys {
        static let entries = "cove.readingProgress.entries"
    }

    private enum Field {
        static let page = "page"
        static let lastWatched = "lastWatched"
    }

    private let defaults: UserDefaults
    private let capacity: Int
    /// Clock injection so eviction tests can order entries deterministically.
    private let now: () -> Date

    init(
        defaults: UserDefaults = .standard,
        capacity: Int = ReadingProgressStore.defaultCapacity,
        now: @escaping () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.capacity = capacity
        self.now = now
    }

    func page(forKey key: String) -> Int? {
        entries()[key]?[Field.page].map { Int($0) }
    }

    func savePage(_ page: Int, forKey key: String) {
        var entries = entries()
        entries[key] = [Field.page: Double(page), Field.lastWatched: now().timeIntervalSince1970]
        while entries.count > capacity {
            guard let oldest = entries.min(by: { ($0.value[Field.lastWatched] ?? 0) < ($1.value[Field.lastWatched] ?? 0) })?.key else {
                break
            }
            entries.removeValue(forKey: oldest)
        }
        defaults.set(entries, forKey: Keys.entries)
    }

    func removePage(forKey key: String) {
        var entries = entries()
        guard entries.removeValue(forKey: key) != nil else { return }
        defaults.set(entries, forKey: Keys.entries)
    }

    private func entries() -> [String: [String: Double]] {
        defaults.dictionary(forKey: Keys.entries) as? [String: [String: Double]] ?? [:]
    }
}
