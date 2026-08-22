import Foundation
import Synchronization
import TraceKit

/// On-disk two-pool cache with LRU eviction and TTL expiry.
///
/// Layout: `root/original/<sha256>` + `root/original/<sha256>.meta`, same
/// for the `display` pool. The `<sha256>` file holds the payload; the
/// `.meta` sidecar is a JSON `CacheMeta` carrying the original key fields,
/// storage/access timestamps and byte count — everything TTL/LRU decisions
/// need without touching the payload.
///
/// The store keeps no in-memory index: meta files are the single source of
/// truth, so cache state survives relaunches. All public entry points are
/// serialized through a mutex and safe to call from any thread.
public final class CacheStore: Sendable {
    /// Storage pools. `original` holds full payloads, `display` holds
    /// downsampled display variants. The raw value is the directory name.
    public enum Pool: String, Sendable, CaseIterable {
        case original
        case display
    }

    /// Capacity/TTL policy, updatable at runtime from the settings page via
    /// `setPolicy`. Carried inside the lock so the class keeps its checked
    /// `Sendable` conformance while the values stay mutable.
    private struct Policy: Sendable {
        var capacityBytes: Int64
        var ttl: TimeInterval
    }

    private let rootDirectory: URL
    private let logger: TraceLogger
    /// Serializes file operations and guards the policy; the on-disk meta
    /// files are the only other mutable state.
    private let lock: Mutex<Policy>

    /// - Parameters:
    ///   - rootDirectory: cache root; pool directories are created lazily on
    ///     first `store`.
    ///   - capacityBytes: total payload byte budget across both pools.
    ///     Negative values are clamped to zero, which lets `evictIfNeeded`
    ///     remove everything.
    ///   - ttl: seconds an entry may live, counted from when it was stored.
    ///     Expired entries count as misses and are removed on eviction.
    public init(rootDirectory: URL, capacityBytes: Int64, ttl: TimeInterval) {
        self.rootDirectory = rootDirectory
        self.lock = Mutex(Policy(capacityBytes: max(0, capacityBytes), ttl: ttl))
        self.logger = TraceLogger(category: "cache")
    }

    /// Returns the cached payload, or `nil` on a miss.
    ///
    /// A hit refreshes the entry's last-access time (LRU). Entries past
    /// their TTL, and entries whose meta sidecar is missing or corrupt,
    /// count as misses and are cleaned up eagerly.
    public func data(forKey key: CacheKey, pool: Pool) throws -> Data? {
        try lock.withLock { policy in
            let dataURL = dataURL(for: key, pool: pool)
            let metaURL = metaURL(for: key, pool: pool)
            guard FileManager.default.fileExists(atPath: dataURL.path) else {
                // A stray meta without payload is garbage; sweep it.
                try? FileManager.default.removeItem(at: metaURL)
                return nil
            }
            guard let meta = loadMeta(at: metaURL), !isExpired(meta, now: Date(), ttl: policy.ttl) else {
                removeEntry(dataURL: dataURL, metaURL: metaURL)
                return nil
            }
            let payload = try Data(contentsOf: dataURL)
            // Refresh the LRU timestamp. A failed rewrite must not fail the
            // read — worst case the entry is evicted a little earlier.
            var refreshed = meta
            refreshed.lastAccessAt = Date().timeIntervalSince1970
            try? saveMeta(refreshed, at: metaURL)
            return payload
        }
    }

    /// Writes (or overwrites) the payload for `key` in `pool`.
    ///
    /// Does not check capacity itself — call `evictIfNeeded()` after bulk
    /// stores to bring the cache back within budget.
    public func store(_ data: Data, forKey key: CacheKey, pool: Pool) throws {
        try lock.withLock { _ in
            let poolDir = poolDirectory(pool)
            try FileManager.default.createDirectory(at: poolDir, withIntermediateDirectories: true)
            try data.write(to: dataURL(for: key, pool: pool), options: .atomic)
            let now = Date().timeIntervalSince1970
            let meta = CacheMeta(
                sourceID: key.sourceID,
                path: key.path,
                fileSize: key.fileSize,
                modifiedTimestamp: key.modifiedTimestamp.timeIntervalSince1970,
                variant: key.variant,
                storedAt: now,
                lastAccessAt: now,
                byteCount: data.count
            )
            try saveMeta(meta, at: metaURL(for: key, pool: pool))
        }
    }

    /// Removes expired entries first, then evicts least-recently-used
    /// entries until the total size fits `capacityBytes`. The LRU ordering
    /// spans both pools, and missing/corrupt meta files are swept along the
    /// way.
    ///
    /// Cheap enough to run periodically from a background queue; the P3
    /// integration is expected to call this on a timer and after bulk stores.
    public func evictIfNeeded() throws {
        try lock.withLock { policy in
            let now = Date()
            var removedCount = 0
            var freedBytes: Int64 = 0
            var survivors: [(dataURL: URL, metaURL: URL, lastAccessAt: TimeInterval, byteCount: Int64)] = []
            var total: Int64 = 0

            for pool in Pool.allCases {
                let poolDir = poolDirectory(pool)
                guard let urls = try contentsOfDirectoryIfPresent(poolDir) else { continue }
                var dataNames: Set<String> = []
                var metaNames: Set<String> = []
                for url in urls {
                    if url.pathExtension == "meta" {
                        metaNames.insert(url.deletingPathExtension().lastPathComponent)
                    } else {
                        dataNames.insert(url.lastPathComponent)
                    }
                }

                for name in dataNames {
                    let dataURL = poolDir.appendingPathComponent(name)
                    let metaURL = dataURL.appendingPathExtension("meta")
                    let size = Int64(
                        (try? dataURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    )
                    guard let meta = loadMeta(at: metaURL), !isExpired(meta, now: now, ttl: policy.ttl) else {
                        removeEntry(dataURL: dataURL, metaURL: metaURL)
                        removedCount += 1
                        freedBytes += size
                        continue
                    }
                    survivors.append((dataURL, metaURL, meta.lastAccessAt, size))
                    total += size
                }

                // Orphan metas whose payload is gone.
                for name in metaNames.subtracting(dataNames) {
                    try? FileManager.default.removeItem(
                        at: poolDir.appendingPathComponent(name + ".meta")
                    )
                }
            }

            if total > policy.capacityBytes {
                survivors.sort { $0.lastAccessAt < $1.lastAccessAt }
                for entry in survivors {
                    guard total > policy.capacityBytes else { break }
                    removeEntry(dataURL: entry.dataURL, metaURL: entry.metaURL)
                    total -= entry.byteCount
                    removedCount += 1
                    freedBytes += entry.byteCount
                }
            }

            if removedCount > 0 {
                logger.info("eviction removed \(removedCount) entries, freed \(freedBytes) bytes")
            }
        }
    }

    /// Total bytes of cached payloads. `pool == nil` sums both pools.
    /// Meta sidecar files are not counted.
    public func currentSize(pool: Pool?) throws -> Int64 {
        try lock.withLock { _ in
            let pools = pool.map { [$0] } ?? Pool.allCases
            var total: Int64 = 0
            for entryPool in pools {
                let poolDir = poolDirectory(entryPool)
                guard let urls = try contentsOfDirectoryIfPresent(poolDir) else { continue }
                for url in urls where url.pathExtension != "meta" {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    total += Int64(size)
                }
            }
            return total
        }
    }

    /// Reports whether a valid (present, unexpired, meta intact) entry
    /// exists for `key` in `pool` — without reading the payload and without
    /// refreshing LRU. Stale entries are swept eagerly, same as a read miss.
    /// Intended for cheap "already warm?" checks by the preheat scheduler.
    public func contains(forKey key: CacheKey, pool: Pool) -> Bool {
        lock.withLock { policy in
            let dataURL = dataURL(for: key, pool: pool)
            let metaURL = metaURL(for: key, pool: pool)
            guard FileManager.default.fileExists(atPath: dataURL.path) else {
                // A stray meta without payload is garbage; sweep it.
                try? FileManager.default.removeItem(at: metaURL)
                return false
            }
            guard let meta = loadMeta(at: metaURL), !isExpired(meta, now: Date(), ttl: policy.ttl) else {
                removeEntry(dataURL: dataURL, metaURL: metaURL)
                return false
            }
            return true
        }
    }

    /// Updates the capacity/TTL policy at runtime (settings page). Shrinking
    /// the budget or TTL does not evict by itself — call `evictIfNeeded()`
    /// afterwards to apply it.
    public func setPolicy(capacityBytes: Int64, ttl: TimeInterval) {
        lock.withLock { policy in
            policy.capacityBytes = max(0, capacityBytes)
            policy.ttl = ttl
        }
    }

    /// Deletes every entry in both pools (settings page "clear now"). The
    /// pool directories are recreated lazily by the next `store`.
    public func removeAll() throws {
        try lock.withLock { _ in
            for pool in Pool.allCases {
                let directory = poolDirectory(pool)
                guard FileManager.default.fileExists(atPath: directory.path) else { continue }
                try FileManager.default.removeItem(at: directory)
            }
        }
    }

    // MARK: - Private

    private func poolDirectory(_ pool: Pool) -> URL {
        rootDirectory.appendingPathComponent(pool.rawValue)
    }

    private func dataURL(for key: CacheKey, pool: Pool) -> URL {
        poolDirectory(pool).appendingPathComponent(key.fileName)
    }

    private func metaURL(for key: CacheKey, pool: Pool) -> URL {
        dataURL(for: key, pool: pool).appendingPathExtension("meta")
    }

    /// Directory listing, or `nil` when the pool directory does not exist
    /// yet (an empty pool, not an error).
    private func contentsOfDirectoryIfPresent(_ directory: URL) throws -> [URL]? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return nil
        }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )
    }

    /// Loads a meta sidecar. Missing or unreadable/corrupt content yields
    /// `nil` — callers treat that as a miss and sweep the entry.
    private func loadMeta(at url: URL) -> CacheMeta? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(CacheMeta.self, from: Data(contentsOf: url))
        } catch {
            logger.error("unreadable cache meta, treating as miss: \(url.lastPathComponent)")
            return nil
        }
    }

    private func saveMeta(_ meta: CacheMeta, at url: URL) throws {
        try JSONEncoder().encode(meta).write(to: url, options: .atomic)
    }

    private func isExpired(_ meta: CacheMeta, now: Date, ttl: TimeInterval) -> Bool {
        now.timeIntervalSince1970 - meta.storedAt > ttl
    }

    /// Best-effort removal; a failure here must not fail the caller —
    /// the next `evictIfNeeded` gets another chance.
    private func removeEntry(dataURL: URL, metaURL: URL) {
        try? FileManager.default.removeItem(at: dataURL)
        try? FileManager.default.removeItem(at: metaURL)
    }
}

/// Sidecar JSON stored next to each cached payload as `<sha256>.meta`.
/// Internal on purpose: the format may evolve, and tests exercise it through
/// `@testable`. Timestamps are seconds since 1970 for stable encoding.
struct CacheMeta: Codable {
    var sourceID: String
    var path: String
    var fileSize: Int64
    var modifiedTimestamp: TimeInterval
    var variant: String
    /// When the entry was stored; TTL counts from here.
    var storedAt: TimeInterval
    /// Last read hit; drives LRU eviction order.
    var lastAccessAt: TimeInterval
    var byteCount: Int
}
