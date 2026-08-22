import CacheKit
import Foundation
import SourceKit
import XCTest
@testable import PreheatKit

final class PreheatSchedulerTests: XCTestCase {
    private var cacheRoot: URL!
    private var cache: CacheStore!
    private var pngData: Data!

    /// Matches the width provider injected below; display keys use `w<width>`.
    private static let displayWidth = 1000
    private static let mtime = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("preheatkit-tests-\(UUID().uuidString)")
        cache = CacheStore(rootDirectory: cacheRoot, capacityBytes: 1_000_000_000, ttl: 3600)
        pngData = try makePNG(width: 64, height: 96)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: cacheRoot)
    }

    // MARK: - Helpers

    private func item(_ path: String) -> ContentItem {
        ContentItem(
            name: (path as NSString).lastPathComponent,
            path: path,
            isDirectory: false,
            size: Int64(pngData.count),
            modifiedDate: Self.mtime
        )
    }

    private func makeScheduler(source: MockSource, maxConcurrent: Int = 2) -> PreheatScheduler {
        PreheatScheduler(
            source: source,
            cache: cache,
            displayWidthProvider: { Self.displayWidth },
            maxConcurrent: maxConcurrent
        )
    }

    private func originalKey(_ path: String) -> CacheKey {
        CacheKey(
            sourceID: "mock://preheat", path: path, fileSize: Int64(pngData.count),
            modifiedTimestamp: Self.mtime, variant: "raw"
        )
    }

    private func displayKey(_ path: String) -> CacheKey {
        CacheKey(
            sourceID: "mock://preheat", path: path, fileSize: Int64(pngData.count),
            modifiedTimestamp: Self.mtime, variant: "w\(Self.displayWidth)"
        )
    }

    /// Polls `condition` until it holds or the timeout expires.
    private func waitUntil(
        timeout: TimeInterval = 10,
        _ condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    // MARK: - Priority ordering

    func testPriorityOrderingAndFIFOWithinPriority() async throws {
        let source = MockSource(files: [
            "/i1.jpg": pngData, "/c1.jpg": pngData, "/u1.jpg": pngData, "/u2.jpg": pngData,
        ])
        // Paused + maxConcurrent 1: the drain order is fully deterministic.
        let scheduler = makeScheduler(source: source, maxConcurrent: 1)
        await scheduler.pause()
        await scheduler.submit([item("/u1.jpg"), item("/u2.jpg")], priority: .userFolder)
        await scheduler.submit([item("/c1.jpg")], priority: .currentDirectory)
        await scheduler.submit([item("/i1.jpg")], priority: .immediate)
        await scheduler.resume()

        let done = await waitUntil { await scheduler.completedCount == 4 }
        XCTAssertTrue(done, "all jobs should complete")
        let order = await source.readPaths
        XCTAssertEqual(order, ["/i1.jpg", "/c1.jpg", "/u1.jpg", "/u2.jpg"])
    }

    func testResubmitAtHigherPriorityUpgradesQueuedJob() async throws {
        let source = MockSource(files: ["/a.jpg": pngData, "/b.jpg": pngData])
        let scheduler = makeScheduler(source: source, maxConcurrent: 1)
        await scheduler.pause()
        await scheduler.submit([item("/a.jpg"), item("/b.jpg")], priority: .userFolder)
        // Opening the reader resubmits at .immediate: b jumps ahead of a.
        await scheduler.submit([item("/b.jpg")], priority: .immediate)
        await scheduler.resume()

        let done = await waitUntil { await scheduler.completedCount == 2 }
        XCTAssertTrue(done)
        let order = await source.readPaths
        XCTAssertEqual(order, ["/b.jpg", "/a.jpg"])
    }

    // MARK: - Dedup

    func testSubmitDeduplicatesQueuedAndInFlightItems() async throws {
        let source = MockSource(files: ["/a.jpg": pngData], readDelayNanoseconds: 100_000_000)
        let scheduler = makeScheduler(source: source)
        await scheduler.submit([item("/a.jpg"), item("/a.jpg")], priority: .currentDirectory)
        // Same item again while queued/in flight: no duplicate work.
        await scheduler.submit([item("/a.jpg")], priority: .immediate)

        let done = await waitUntil { await scheduler.completedCount == 1 }
        XCTAssertTrue(done)
        let reads = await source.readPaths
        XCTAssertEqual(reads, ["/a.jpg"])
        let pending = await scheduler.pendingCount
        XCTAssertEqual(pending, 0)
    }

    func testSubmitSkipsFullyWarmEntries() async throws {
        // Payload content is irrelevant here — only presence is checked.
        try cache.store(Data([0xFF]), forKey: displayKey("/warm.jpg"), pool: .display)
        let source = MockSource(files: ["/warm.jpg": pngData])
        let scheduler = makeScheduler(source: source)
        await scheduler.submit([item("/warm.jpg")], priority: .currentDirectory)

        // Give a wrongly-queued job a chance to run.
        try await Task.sleep(nanoseconds: 200_000_000)
        let completed = await scheduler.completedCount
        let pending = await scheduler.pendingCount
        let reads = await source.readPaths
        XCTAssertEqual(completed, 0)
        XCTAssertEqual(pending, 0)
        XCTAssertTrue(reads.isEmpty, "fully warm entries must not be fetched")
    }

    func testOriginalPoolHitAvoidsNetworkButFillsDisplay() async throws {
        try cache.store(pngData, forKey: originalKey("/half.jpg"), pool: .original)
        let source = MockSource(files: ["/half.jpg": pngData])
        let scheduler = makeScheduler(source: source)
        await scheduler.submit([item("/half.jpg")], priority: .currentDirectory)

        let done = await waitUntil { await scheduler.completedCount == 1 }
        XCTAssertTrue(done)
        let reads = await source.readPaths
        XCTAssertTrue(reads.isEmpty, "original-pool hit must not hit the network")
        let warm = try cache.contains(forKey: displayKey("/half.jpg"), pool: .display)
        XCTAssertTrue(warm, "the display pool must be filled from the cached original")
    }

    // MARK: - Pause / resume / cancel

    func testPauseBlocksNewJobsUntilResume() async throws {
        let source = MockSource(files: ["/a.jpg": pngData])
        let scheduler = makeScheduler(source: source)
        await scheduler.pause()
        await scheduler.submit([item("/a.jpg")], priority: .currentDirectory)

        try await Task.sleep(nanoseconds: 200_000_000)
        var reads = await source.readPaths
        XCTAssertTrue(reads.isEmpty, "a paused scheduler must not start jobs")
        var pending = await scheduler.pendingCount
        XCTAssertEqual(pending, 1)
        var paused = await scheduler.isPaused
        XCTAssertTrue(paused)

        await scheduler.resume()
        let done = await waitUntil { await scheduler.completedCount == 1 }
        XCTAssertTrue(done)
        reads = await source.readPaths
        XCTAssertEqual(reads, ["/a.jpg"])
        pending = await scheduler.pendingCount
        XCTAssertEqual(pending, 0)
        paused = await scheduler.isPaused
        XCTAssertFalse(paused)
    }

    func testCancelAllDropsQueueAndStopsInFlight() async throws {
        var files: [String: Data] = [:]
        for index in 0..<10 { files["/f\(index).jpg"] = pngData }
        let source = MockSource(files: files, readDelayNanoseconds: 100_000_000)
        let scheduler = makeScheduler(source: source, maxConcurrent: 2)
        await scheduler.submit((0..<10).map { item("/f\($0).jpg") }, priority: .currentDirectory)

        // Wait until the first read finished (the second is in flight now),
        // then cancel everything.
        let started = await waitUntil { await source.readCount >= 1 }
        XCTAssertTrue(started)
        await scheduler.cancelAll()

        // Long enough that the whole queue would have drained uncancelled.
        try await Task.sleep(nanoseconds: 400_000_000)
        let pending = await scheduler.pendingCount
        let completed = await scheduler.completedCount
        XCTAssertEqual(pending, 0)
        XCTAssertLessThan(completed, 10, "cancelAll must stop the queue")
    }

    // MARK: - Priority-scoped cancel

    func testCancelPriorityDropsOnlyThatQueue() async throws {
        let source = MockSource(files: [
            "/c1.jpg": pngData, "/c2.jpg": pngData, "/u1.jpg": pngData,
        ])
        let scheduler = makeScheduler(source: source, maxConcurrent: 1)
        await scheduler.pause()
        await scheduler.submit([item("/u1.jpg")], priority: .userFolder)
        await scheduler.submit([item("/c1.jpg"), item("/c2.jpg")], priority: .currentDirectory)

        await scheduler.cancel(priority: .currentDirectory)

        var pending = await scheduler.pendingCount(priority: .currentDirectory)
        XCTAssertEqual(pending, 0)
        pending = await scheduler.pendingCount(priority: .userFolder)
        XCTAssertEqual(pending, 1, "other priorities must keep their queue")

        await scheduler.resume()
        let done = await waitUntil { await scheduler.completedCount == 1 }
        XCTAssertTrue(done)
        let reads = await source.readPaths
        XCTAssertEqual(reads, ["/u1.jpg"], "cancelled jobs must never run")
    }

    func testCancelPriorityLetsInFlightJobsFinish() async throws {
        let source = MockSource(
            files: ["/c1.jpg": pngData, "/c2.jpg": pngData],
            readDelayNanoseconds: 100_000_000
        )
        let scheduler = makeScheduler(source: source, maxConcurrent: 1)
        await scheduler.submit([item("/c1.jpg"), item("/c2.jpg")], priority: .currentDirectory)

        // c1 is in flight, c2 still queued; cancel drops only c2.
        let started = await waitUntil { await source.readCount >= 1 }
        XCTAssertTrue(started)
        await scheduler.cancel(priority: .currentDirectory)

        let pending = await scheduler.pendingCount(priority: .currentDirectory)
        XCTAssertEqual(pending, 0)
        let done = await waitUntil { await scheduler.completedCount == 1 }
        XCTAssertTrue(done, "the in-flight job runs to completion")
        let reads = await source.readPaths
        XCTAssertEqual(reads, ["/c1.jpg"])
    }

    func testCancelledItemCanBeResubmitted() async throws {
        let source = MockSource(files: ["/c1.jpg": pngData])
        let scheduler = makeScheduler(source: source, maxConcurrent: 1)
        await scheduler.pause()
        await scheduler.submit([item("/c1.jpg")], priority: .currentDirectory)
        await scheduler.cancel(priority: .currentDirectory)

        // The dedup index must be cleaned: resubmitting re-queues the item.
        await scheduler.submit([item("/c1.jpg")], priority: .currentDirectory)
        let pending = await scheduler.pendingCount(priority: .currentDirectory)
        XCTAssertEqual(pending, 1)

        await scheduler.resume()
        let done = await waitUntil { await scheduler.completedCount == 1 }
        XCTAssertTrue(done)
    }

    // MARK: - Rate limiter

    func testRateLimiterChargesWithinBudgetWithoutDelay() {
        var limiter = RateLimiter(bytesPerSecond: 1000, now: 0)
        XCTAssertEqual(limiter.charge(500, now: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(limiter.allowance, 500, accuracy: 1e-9)
    }

    func testRateLimiterDebtProducesProportionalDelay() {
        var limiter = RateLimiter(bytesPerSecond: 1000, now: 0)
        _ = limiter.charge(500, now: 0)
        // 600 more bytes → 100 bytes of debt at 1000 B/s → 0.1 s wait.
        XCTAssertEqual(limiter.charge(600, now: 0), 0.1, accuracy: 1e-9)
    }

    func testRateLimiterRefillsOverTimeCappedAtOneSecondOfBudget() {
        var limiter = RateLimiter(bytesPerSecond: 1000, now: 0)
        _ = limiter.charge(1000, now: 0) // drain the initial burst budget
        // Two idle seconds refill the bucket, capped at one second of budget.
        XCTAssertEqual(limiter.charge(100, now: 2), 0, accuracy: 1e-9)
        XCTAssertEqual(limiter.allowance, 900, accuracy: 1e-9)
        // Overspending goes into debt: 900 - 1900 = -1000 → 1 s at 1000 B/s.
        XCTAssertEqual(limiter.charge(1900, now: 2), 1.0, accuracy: 1e-9)
    }

    // MARK: - Stats

    func testStatsTrackCompletionFailuresAndThroughput() async throws {
        // "/missing.jpg" is deliberately absent from the mock's files.
        let source = MockSource(files: ["/a.jpg": pngData, "/b.jpg": pngData])
        let scheduler = makeScheduler(source: source, maxConcurrent: 1)
        await scheduler.submit(
            [item("/missing.jpg"), item("/a.jpg"), item("/b.jpg")],
            priority: .currentDirectory
        )

        let done = await waitUntil { await scheduler.completedCount == 2 }
        XCTAssertTrue(done, "a failed job must not block the queue")
        let failed = await scheduler.failedCount
        XCTAssertEqual(failed, 1)
        let pending = await scheduler.pendingCount
        XCTAssertEqual(pending, 0)
        let throughput = await scheduler.throughputBytesPerSecond
        XCTAssertGreaterThan(throughput, 0)
        // Both pools are warm for the successful jobs.
        XCTAssertTrue(try cache.contains(forKey: originalKey("/a.jpg"), pool: .original))
        XCTAssertTrue(try cache.contains(forKey: displayKey("/b.jpg"), pool: .display))
    }
}
