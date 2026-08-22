import XCTest
@testable import CacheKit

final class CacheStoreTests: XCTestCase {
    private var root: URL!
    private var store: CacheStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cachekit-tests-\(UUID().uuidString)")
        store = CacheStore(rootDirectory: root, capacityBytes: 1_000_000, ttl: 3600)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func key(_ path: String = "/photos/a.jpg", variant: String = "raw") -> CacheKey {
        CacheKey(
            sourceID: "smb://nas/photos",
            path: path,
            fileSize: 1234,
            modifiedTimestamp: Date(timeIntervalSince1970: 1_700_000_000),
            variant: variant
        )
    }

    private func dataURL(_ key: CacheKey, _ pool: CacheStore.Pool) -> URL {
        root.appendingPathComponent(pool.rawValue).appendingPathComponent(key.fileName)
    }

    private func metaURL(_ key: CacheKey, _ pool: CacheStore.Pool) -> URL {
        dataURL(key, pool).appendingPathExtension("meta")
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Rewrites the sidecar with controlled timestamps so TTL/LRU tests stay
    /// deterministic (no sleeping).
    private func rewriteMeta(
        _ key: CacheKey,
        _ pool: CacheStore.Pool,
        storedAt: Date,
        lastAccessAt: Date,
        byteCount: Int
    ) throws {
        let meta = CacheMeta(
            sourceID: key.sourceID,
            path: key.path,
            fileSize: key.fileSize,
            modifiedTimestamp: key.modifiedTimestamp.timeIntervalSince1970,
            variant: key.variant,
            storedAt: storedAt.timeIntervalSince1970,
            lastAccessAt: lastAccessAt.timeIntervalSince1970,
            byteCount: byteCount
        )
        try JSONEncoder().encode(meta).write(to: metaURL(key, pool))
    }

    private func readMeta(_ key: CacheKey, _ pool: CacheStore.Pool) throws -> CacheMeta? {
        guard exists(metaURL(key, pool)) else { return nil }
        return try JSONDecoder().decode(CacheMeta.self, from: Data(contentsOf: metaURL(key, pool)))
    }

    // MARK: - Round trip

    func testStoreAndReadRoundTrip() throws {
        let key = key()
        try store.store(Data("hello".utf8), forKey: key, pool: .original)
        XCTAssertEqual(try store.data(forKey: key, pool: .original), Data("hello".utf8))
    }

    func testReadMissReturnsNil() throws {
        XCTAssertNil(try store.data(forKey: key(), pool: .original))
    }

    func testPoolsAreIndependent() throws {
        let key = key()
        try store.store(Data("full".utf8), forKey: key, pool: .original)
        try store.store(Data("thumb".utf8), forKey: key, pool: .display)
        XCTAssertEqual(try store.data(forKey: key, pool: .original), Data("full".utf8))
        XCTAssertEqual(try store.data(forKey: key, pool: .display), Data("thumb".utf8))
    }

    func testStoreSameKeyOverwrites() throws {
        let key = key()
        try store.store(Data("v1".utf8), forKey: key, pool: .original)
        try store.store(Data("version-two".utf8), forKey: key, pool: .original)
        XCTAssertEqual(try store.data(forKey: key, pool: .original), Data("version-two".utf8))
        XCTAssertEqual(try store.currentSize(pool: .original), Int64(Data("version-two".utf8).count))
    }

    func testDistinctVariantsAreDistinctEntries() throws {
        let raw = key(variant: "raw")
        let thumb = key(variant: "2048px")
        try store.store(Data("raw-bytes".utf8), forKey: raw, pool: .display)
        try store.store(Data("t".utf8), forKey: thumb, pool: .display)
        XCTAssertEqual(try store.data(forKey: raw, pool: .display), Data("raw-bytes".utf8))
        XCTAssertEqual(try store.data(forKey: thumb, pool: .display), Data("t".utf8))
    }

    // MARK: - LRU semantics

    func testReadHitRefreshesLastAccess() throws {
        let key = key()
        let now = Date()
        try store.store(Data("hello".utf8), forKey: key, pool: .original)
        try rewriteMeta(key, .original, storedAt: now, lastAccessAt: now.addingTimeInterval(-600), byteCount: 5)

        XCTAssertNotNil(try store.data(forKey: key, pool: .original))

        let meta = try XCTUnwrap(readMeta(key, .original))
        XCTAssertGreaterThan(meta.lastAccessAt, now.addingTimeInterval(-600).timeIntervalSince1970)
    }

    // MARK: - TTL

    func testExpiredReadIsMissAndCleansUp() throws {
        let key = key()
        try store.store(Data("stale".utf8), forKey: key, pool: .original)
        // TTL is 3600s; pretend the entry was stored two hours ago.
        try rewriteMeta(
            key, .original,
            storedAt: Date().addingTimeInterval(-7200),
            lastAccessAt: Date(),
            byteCount: 5
        )

        XCTAssertNil(try store.data(forKey: key, pool: .original))
        XCTAssertFalse(exists(dataURL(key, .original)))
        XCTAssertFalse(exists(metaURL(key, .original)))
    }

    func testEvictRemovesExpiredEntries() throws {
        let stale = key("/photos/stale.jpg")
        let fresh = key("/photos/fresh.jpg")
        try store.store(Data("stale".utf8), forKey: stale, pool: .original)
        try store.store(Data("fresh".utf8), forKey: fresh, pool: .original)
        try rewriteMeta(
            stale, .original,
            storedAt: Date().addingTimeInterval(-7200),
            lastAccessAt: Date(),
            byteCount: 5
        )

        try store.evictIfNeeded()

        XCTAssertFalse(exists(dataURL(stale, .original)))
        XCTAssertFalse(exists(metaURL(stale, .original)))
        XCTAssertEqual(try store.data(forKey: fresh, pool: .original), Data("fresh".utf8))
    }

    // MARK: - Capacity / LRU eviction

    func testEvictEnforcesCapacityOldestFirst() throws {
        let small = CacheStore(rootDirectory: root, capacityBytes: 8, ttl: 3600)
        let now = Date()
        let oldest = key("/photos/1.jpg")
        let middle = key("/photos/2.jpg")
        let newest = key("/photos/3.jpg")
        for (index, key) in [oldest, middle, newest].enumerated() {
            try small.store(Data("abcd".utf8), forKey: key, pool: .original)
            try rewriteMeta(
                key, .original,
                storedAt: now,
                lastAccessAt: now.addingTimeInterval(TimeInterval(index)),
                byteCount: 4
            )
        }

        try small.evictIfNeeded()

        XCTAssertFalse(exists(dataURL(oldest, .original)))
        XCTAssertTrue(exists(dataURL(middle, .original)))
        XCTAssertTrue(exists(dataURL(newest, .original)))
        XCTAssertEqual(try small.currentSize(pool: nil), 8)
    }

    func testLRUEvictionSpansPools() throws {
        let small = CacheStore(rootDirectory: root, capacityBytes: 6, ttl: 3600)
        let now = Date()
        let oldOriginal = key("/photos/old.jpg")
        let recentDisplay = key("/photos/recent.jpg", variant: "2048px")
        try small.store(Data("aaaaa".utf8), forKey: oldOriginal, pool: .original)
        try small.store(Data("bbbbb".utf8), forKey: recentDisplay, pool: .display)
        try rewriteMeta(oldOriginal, .original, storedAt: now, lastAccessAt: now.addingTimeInterval(-100), byteCount: 5)
        try rewriteMeta(recentDisplay, .display, storedAt: now, lastAccessAt: now, byteCount: 5)

        try small.evictIfNeeded()

        // The globally oldest entry goes first, regardless of pool.
        XCTAssertFalse(exists(dataURL(oldOriginal, .original)))
        XCTAssertTrue(exists(dataURL(recentDisplay, .display)))
        XCTAssertEqual(try small.currentSize(pool: nil), 5)
    }

    func testZeroCapacityEvictsEverything() throws {
        let zero = CacheStore(rootDirectory: root, capacityBytes: 0, ttl: 3600)
        let key = key()
        try zero.store(Data("abcd".utf8), forKey: key, pool: .original)
        try zero.evictIfNeeded()
        XCTAssertFalse(exists(dataURL(key, .original)))
        XCTAssertEqual(try zero.currentSize(pool: nil), 0)
    }

    // MARK: - currentSize

    func testCurrentSizeSumsPoolsAndIgnoresMetaFiles() throws {
        try store.store(Data("12345".utf8), forKey: key("/a.jpg"), pool: .original)
        try store.store(Data("1234567".utf8), forKey: key("/b.jpg"), pool: .display)
        XCTAssertEqual(try store.currentSize(pool: .original), 5)
        XCTAssertEqual(try store.currentSize(pool: .display), 7)
        XCTAssertEqual(try store.currentSize(pool: nil), 12)
    }

    func testCurrentSizeOfMissingRootIsZero() throws {
        let untouched = CacheStore(
            rootDirectory: root.appendingPathComponent("never-created"),
            capacityBytes: 100,
            ttl: 60
        )
        XCTAssertEqual(try untouched.currentSize(pool: nil), 0)
        try untouched.evictIfNeeded() // Must not throw on missing directories.
    }

    // MARK: - Corrupt / missing meta tolerance

    func testCorruptMetaIsMissAndCleanedUp() throws {
        let key = key()
        try store.store(Data("hello".utf8), forKey: key, pool: .original)
        try Data("not json".utf8).write(to: metaURL(key, .original))

        XCTAssertNil(try store.data(forKey: key, pool: .original))
        XCTAssertFalse(exists(dataURL(key, .original)))
        XCTAssertFalse(exists(metaURL(key, .original)))
        XCTAssertEqual(try store.currentSize(pool: nil), 0)
    }

    func testMissingMetaIsMissAndCleanedUp() throws {
        let key = key()
        try store.store(Data("hello".utf8), forKey: key, pool: .original)
        try FileManager.default.removeItem(at: metaURL(key, .original))

        XCTAssertNil(try store.data(forKey: key, pool: .original))
        XCTAssertFalse(exists(dataURL(key, .original)))
    }

    func testOrphanMetaWithoutPayloadIsSweptOnEvict() throws {
        let key = key()
        try store.store(Data("hello".utf8), forKey: key, pool: .original)
        try FileManager.default.removeItem(at: dataURL(key, .original))
        XCTAssertTrue(exists(metaURL(key, .original)))

        try store.evictIfNeeded()

        XCTAssertFalse(exists(metaURL(key, .original)))
    }

    // MARK: - contains

    func testContainsHitAndMiss() throws {
        let key = key()
        XCTAssertFalse(store.contains(forKey: key, pool: .original))
        try store.store(Data("hello".utf8), forKey: key, pool: .original)
        XCTAssertTrue(store.contains(forKey: key, pool: .original))
        XCTAssertFalse(store.contains(forKey: key, pool: .display))
    }

    func testContainsDoesNotRefreshLRUTimestamp() throws {
        let key = key()
        try store.store(Data("hello".utf8), forKey: key, pool: .original)
        let old = Date(timeIntervalSince1970: 1_000)
        try rewriteMeta(key, .original, storedAt: Date(), lastAccessAt: old, byteCount: 5)

        XCTAssertTrue(store.contains(forKey: key, pool: .original))
        XCTAssertEqual(try readMeta(key, .original)?.lastAccessAt, old.timeIntervalSince1970)
    }

    func testContainsExpiredEntryCountsAsMissingAndIsSwept() throws {
        let key = key()
        try store.store(Data("hello".utf8), forKey: key, pool: .original)
        let longAgo = Date(timeIntervalSince1970: 0)
        try rewriteMeta(key, .original, storedAt: longAgo, lastAccessAt: longAgo, byteCount: 5)

        XCTAssertFalse(store.contains(forKey: key, pool: .original))
        XCTAssertFalse(exists(dataURL(key, .original)))
        XCTAssertFalse(exists(metaURL(key, .original)))
    }

    // MARK: - setPolicy

    func testSetPolicyShrinksBudgetAndEvictionApplies() throws {
        let old = key("/old.jpg")
        let recent = key("/recent.jpg")
        try store.store(Data(repeating: 1, count: 400_000), forKey: old, pool: .original)
        try store.store(Data(repeating: 2, count: 400_000), forKey: recent, pool: .original)
        let now = Date()
        try rewriteMeta(old, .original, storedAt: now, lastAccessAt: now.addingTimeInterval(-100), byteCount: 400_000)
        try rewriteMeta(recent, .original, storedAt: now, lastAccessAt: now, byteCount: 400_000)

        store.setPolicy(capacityBytes: 500_000, ttl: 3600)
        try store.evictIfNeeded()

        XCTAssertFalse(store.contains(forKey: old, pool: .original))
        XCTAssertTrue(store.contains(forKey: recent, pool: .original))
    }

    func testSetPolicyShortensTTL() throws {
        let key = key()
        try store.store(Data("hello".utf8), forKey: key, pool: .original)

        // A negative TTL makes every existing entry expired.
        store.setPolicy(capacityBytes: 1_000_000, ttl: -1)
        XCTAssertFalse(store.contains(forKey: key, pool: .original))
    }

    // MARK: - removeAll

    func testRemoveAllClearsBothPools() throws {
        try store.store(Data("aaaaa".utf8), forKey: key("/a.jpg", variant: "raw"), pool: .original)
        try store.store(Data("bbb".utf8), forKey: key("/a.jpg", variant: "w1000"), pool: .display)

        try store.removeAll()

        XCTAssertEqual(try store.currentSize(pool: .original), 0)
        XCTAssertEqual(try store.currentSize(pool: .display), 0)
        XCTAssertFalse(store.contains(forKey: key("/a.jpg", variant: "raw"), pool: .original))
        // The store keeps working after a wipe.
        try store.store(Data("cc".utf8), forKey: key("/b.jpg"), pool: .original)
        XCTAssertTrue(store.contains(forKey: key("/b.jpg"), pool: .original))
    }

    func testRemoveAllOnEmptyCacheSucceeds() throws {
        XCTAssertNoThrow(try store.removeAll())
    }
}
