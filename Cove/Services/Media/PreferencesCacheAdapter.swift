import CacheKit
import Foundation

/// CacheKit-backed `PreferencesCacheManaging` for the Preferences feature.
/// Lives in the media services layer so the feature itself stays free of
/// CacheKit; injected at the composition root (AppDelegate).
struct PreferencesCacheAdapter: PreferencesCacheManaging {
    let store: CacheStore

    func usage() throws -> (original: Int64, display: Int64) {
        (try store.currentSize(pool: .original), try store.currentSize(pool: .display))
    }

    func clearAll() throws {
        try store.removeAll()
    }
}
