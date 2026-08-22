import CacheKit
import Foundation

/// Media service owning the app-wide on-disk image cache.
///
/// Capacity and TTL come from the settings page (`SettingsService`) and are
/// re-applied live whenever they change; a change that shrinks the budget or
/// TTL is followed by an eviction pass off the main thread. The store itself
/// is `Sendable` and safe to hand to background pipelines from anywhere.
///
/// Rooted in the user's Caches directory under the app bundle identifier.
/// (Sandboxed, so this resolves to the app container's Caches directory.)
@MainActor
final class CacheService: NSObject {
    static let shared = CacheService()

    /// The cache root directory; exposed for tests/debugging.
    static let rootDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("com.biboyang.cove", isDirectory: true)
    }()

    let store: CacheStore

    private override init() {
        let settings = SettingsService.shared
        store = CacheStore(
            rootDirectory: Self.rootDirectory,
            capacityBytes: settings.cacheCapacityBytes,
            ttl: settings.cacheTTL
        )
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: SettingsService.didChange,
            object: nil
        )
        // Sweep expired entries and LRU overflow off the critical path.
        sweepInBackground()
    }

    @objc private func settingsDidChange() {
        let settings = SettingsService.shared
        store.setPolicy(capacityBytes: settings.cacheCapacityBytes, ttl: settings.cacheTTL)
        // A shrunken budget/TTL only takes effect on disk after eviction.
        sweepInBackground()
    }

    private func sweepInBackground() {
        let store = store
        Task.detached(priority: .utility) {
            try? store.evictIfNeeded()
        }
    }
}
