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
final class CacheService {
    /// The cache root directory; exposed for tests/debugging.
    static let rootDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("com.biboyang.cove", isDirectory: true)
    }()

    /// Default cadence of the periodic background sweep.
    private static let defaultSweepInterval: TimeInterval = 15 * 60

    let store: CacheStore
    private let settings: SettingsService
    /// Handle of the repeating sweep; nothing cancels it (the service lives
    /// for the process lifetime), it exits on its own once the service
    /// deallocates. Kept for future teardown.
    private var periodicSweepTask: Task<Void, Never>?

    /// `sweepInterval` and `rootDirectory` are internal injection seams for
    /// tests; production callers get 15 minutes and the standard Caches
    /// location.
    init(
        settings: SettingsService,
        sweepInterval: TimeInterval = CacheService.defaultSweepInterval,
        rootDirectory: URL = CacheService.rootDirectory
    ) {
        self.settings = settings
        store = CacheStore(
            rootDirectory: rootDirectory,
            capacityBytes: settings.cacheCapacityBytes,
            ttl: settings.cacheTTL
        )
        settings.addChangeObserver { [weak self] in
            self?.settingsDidChange()
        }
        // Sweep expired entries and LRU overflow off the critical path.
        sweepInBackground()
        startPeriodicSweep(interval: sweepInterval)
    }

    private func settingsDidChange() {
        store.setPolicy(capacityBytes: settings.cacheCapacityBytes, ttl: settings.cacheTTL)
        // A shrunken budget/TTL only takes effect on disk after eviction.
        sweepInBackground()
    }

    /// Sweeps on a fixed cadence so the eviction triggers that only fire on
    /// events (init, settings change, preheat batches) cannot leave the
    /// cache over budget for a whole session — with preheating off or in
    /// vault-only sessions none of them may fire again after launch.
    /// `evictIfNeeded` is idempotent and the store is locked, so running
    /// concurrently with the event-driven sweeps is harmless.
    private func startPeriodicSweep(interval: TimeInterval) {
        periodicSweepTask = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return  // cancelled while sleeping
                }
                guard let self else { return }
                sweepInBackground()
            }
        }
    }

    private func sweepInBackground() {
        let store = store
        Task.detached(priority: .utility) {
            try? store.evictIfNeeded()
        }
    }
}
