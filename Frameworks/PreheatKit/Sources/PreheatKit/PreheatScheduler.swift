import CacheKit
import CoreGraphics
import Foundation
import ImagePipeline
import SourceKit
import TraceKit

/// Ways a preheat job can fail beyond the underlying source error.
private enum PreheatError: Error {
    /// Original bytes were read but are not a decodable image.
    case undecodable
}

/// Schedules "fetch ahead into the disk cache" work for one content source.
///
/// One job per image: read the original bytes (`ContentSource.read`) into
/// CacheKit's original pool, then downsample + JPEG-encode into the display
/// pool under the same `w<width>` variant the reader uses, so a preheated
/// page opens straight from the display pool. Jobs run at three priorities
/// (immediate > currentDirectory > userFolder), FIFO within a priority, at
/// most `maxConcurrent` at a time, optionally throttled by a token bucket.
///
/// The scheduler is bound to one source instance: when the app reconnects
/// or switches shares, the owning service discards it (after `cancelAll()`)
/// and builds a new one for the new connection.
public actor PreheatScheduler {
    /// Work priority; lower raw value runs first. (Raw-value enums get no
    /// synthesized Comparable, hence the manual `<`.)
    public enum Priority: Int, Sendable, Comparable {
        /// The user is looking at these right now (reader just opened).
        case immediate = 0
        /// Directory currently on screen in the browser.
        case currentDirectory
        /// Background folders from the settings page.
        case userFolder

        public static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// One unit of preheat work: the item plus its precomputed cache keys
    /// (key fields never change once queued).
    private struct Job: Sendable {
        let item: ContentItem
        let originalKey: CacheKey
        let displayKey: CacheKey
        /// Target width of the display variant, in pixels.
        let displayWidth: Int
    }

    /// JPEG quality for display-pool payloads; matches the reader.
    private static let displayJPEGQuality = 0.85
    /// Sliding window for the throughput estimate, in seconds.
    private static let throughputWindow: TimeInterval = 5

    private let source: any ContentSource
    private let cache: CacheStore
    private let displayWidthProvider: @Sendable () -> Int
    private let maxConcurrent: Int
    /// Time source, injected for tests (seconds since 1970).
    private let now: @Sendable () -> TimeInterval
    private let logger = TraceLogger(category: "preheat")

    /// FIFO queues per priority; empty queues stay in the map, harmlessly.
    private var queues: [Priority: [Job]] = [:]
    /// Dedup index for waiting jobs: original cache key → queue position.
    private var queueIndex: [CacheKey: Priority] = [:]
    /// Dedup index for running jobs. A job leaves both indexes on finish, so
    /// a resubmitted finished/failed job re-evaluates against the cache.
    private var inFlightKeys: Set<CacheKey> = []
    /// In-flight job tasks, so `cancelAll` can reach them.
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var paused = false
    private var rateLimiter: RateLimiter?
    private var completed = 0
    private var failed = 0
    /// Recent network-read samples (timestamp, bytes) behind the throughput
    /// estimate. Local cache hits are not counted.
    private var samples: [(at: TimeInterval, bytes: Int64)] = []
    /// Set when any job stored payload; an eviction pass runs once the
    /// scheduler goes idle.
    private var needsEviction = false

    /// - Parameters:
    ///   - source: connection the jobs read from (for SMB: the dedicated
    ///     preheat connection, so bulk reads never queue behind browsing).
    ///   - cache: shared two-pool disk cache.
    ///   - displayWidthProvider: display-variant width in pixels (the
    ///     screen's backing width). Injected so the package never touches
    ///     NSScreen; evaluated once per `submit` call.
    ///   - maxConcurrent: parallel jobs; clamped to ≥ 1.
    ///   - rateLimitBytesPerSecond: network read budget; `nil` or ≤ 0 means
    ///     unlimited.
    ///   - now: time source, injectable for deterministic tests.
    public init(
        source: any ContentSource,
        cache: CacheStore,
        displayWidthProvider: @escaping @Sendable () -> Int,
        maxConcurrent: Int = 2,
        rateLimitBytesPerSecond: Int64? = nil,
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.source = source
        self.cache = cache
        self.displayWidthProvider = displayWidthProvider
        self.maxConcurrent = max(1, maxConcurrent)
        self.now = now
        if let rateLimitBytesPerSecond, rateLimitBytesPerSecond > 0 {
            rateLimiter = RateLimiter(bytesPerSecond: rateLimitBytesPerSecond, now: now())
        }
    }

    // MARK: - Public API

    /// Enqueues image items at `priority`. Skips directories, non-images,
    /// items already fully warm in the cache, and items already queued or
    /// running. Resubmitting a queued item at a higher priority moves it up
    /// (this is how opening the reader jumps the queue).
    public func submit(_ items: [ContentItem], priority: Priority) {
        let width = max(1, displayWidthProvider())
        var accepted = false
        for item in items where !item.isDirectory && item.fileType == .image {
            let job = makeJob(item: item, width: width)
            if inFlightKeys.contains(job.originalKey) { continue }
            if let existing = queueIndex[job.originalKey] {
                if priority < existing, var queue = queues[existing] {
                    queue.removeAll { $0.originalKey == job.originalKey }
                    queues[existing] = queue
                    queues[priority, default: []].append(job)
                    queueIndex[job.originalKey] = priority
                    accepted = true
                }
                continue
            }
            // Fully warm = display variant cached; nothing to do. A warm
            // original with a cold display still runs: the read then comes
            // from the original pool instead of the network.
            if cache.contains(forKey: job.displayKey, pool: .display) { continue }
            queues[priority, default: []].append(job)
            queueIndex[job.originalKey] = priority
            accepted = true
        }
        if accepted { pump() }
    }

    /// Stops starting new jobs; in-flight jobs run to completion.
    public func pause() {
        paused = true
    }

    /// Resumes starting jobs after `pause`.
    public func resume() {
        guard paused else { return }
        paused = false
        pump()
    }

    /// Drops every queued job and cancels in-flight reads.
    public func cancelAll() {
        queues.removeAll()
        queueIndex.removeAll()
        inFlightKeys.removeAll()
        let tasks = runningTasks
        runningTasks.removeAll()
        for task in tasks.values { task.cancel() }
    }

    /// Replaces the rate limit; `nil` or ≤ 0 disables it. The bucket starts
    /// fresh, so raising the limit takes effect immediately.
    public func setRateLimit(bytesPerSecond: Int64?) {
        if let bytesPerSecond, bytesPerSecond > 0 {
            rateLimiter = RateLimiter(bytesPerSecond: bytesPerSecond, now: now())
        } else {
            rateLimiter = nil
        }
    }

    public var isPaused: Bool { paused }
    /// Jobs waiting in queue; in-flight jobs are not counted.
    public var pendingCount: Int {
        queues.values.reduce(0) { $0 + $1.count }
    }
    /// Jobs finished successfully since creation.
    public var completedCount: Int { completed }
    /// Jobs that failed (and were not retried) since creation.
    public var failedCount: Int { failed }
    /// Network bytes read per second, averaged over a trailing
    /// `throughputWindow`-second window. Zero while idle or serving from
    /// the local cache.
    public var throughputBytesPerSecond: Double {
        let cutoff = now() - Self.throughputWindow
        let bytes = samples.reduce(Int64(0)) { $0 + ($1.at >= cutoff ? $1.bytes : 0) }
        return Double(bytes) / Self.throughputWindow
    }

    // MARK: - Queue machinery

    private func makeJob(item: ContentItem, width: Int) -> Job {
        // Keys go through the CacheKey factory so the reader computes the
        // identical keys and a preheated page opens straight from the cache.
        return Job(
            item: item,
            originalKey: CacheKey.sourceFile(
                sourceID: source.sourceID, path: item.path, fileSize: item.size,
                modified: item.modifiedDate, variant: CacheKey.rawVariant
            ),
            displayKey: CacheKey.sourceFile(
                sourceID: source.sourceID, path: item.path, fileSize: item.size,
                modified: item.modifiedDate, variant: CacheKey.displayWidthVariant(width)
            ),
            displayWidth: width
        )
    }

    /// Starts jobs until the concurrency budget is spent. Every finishing
    /// job re-enters here, so the queue drains itself.
    private func pump() {
        guard !paused else { return }
        while runningTasks.count < maxConcurrent, let job = dequeueNext() {
            let id = UUID()
            let task = Task.detached(priority: .utility) { [self] in
                await execute(job)
                await finish(id: id, job: job)
            }
            runningTasks[id] = task
        }
    }

    private func dequeueNext() -> Job? {
        for priority in [Priority.immediate, .currentDirectory, .userFolder] {
            guard var queue = queues[priority], !queue.isEmpty else { continue }
            let job = queue.removeFirst()
            queues[priority] = queue
            queueIndex.removeValue(forKey: job.originalKey)
            inFlightKeys.insert(job.originalKey)
            return job
        }
        return nil
    }

    /// One job: original pool → network, then display pool fill. Every step
    /// is best-effort — a failed store just means the next reader visit
    /// redoes the work. Cancellation is honored between steps.
    private func execute(_ job: Job) async {
        do {
            try Task.checkCancellation()

            let original: Data
            if let cached = try? cache.data(forKey: job.originalKey, pool: .original) {
                original = cached
            } else {
                // Only network reads are throttled; local cache hits are free.
                if rateLimiter != nil {
                    let delay = rateLimiter!.charge(job.item.size, now: now())
                    if delay > 0 {
                        try await sleep(seconds: delay)
                    }
                }
                let data = try await source.read(at: job.item.path)
                try Task.checkCancellation()
                try? cache.store(data, forKey: job.originalKey, pool: .original)
                needsEviction = true
                original = data
                recordBytes(Int64(data.count))
            }

            if !cache.contains(forKey: job.displayKey, pool: .display) {
                guard let displaySize = ImagePipeline.displayDimensions(of: original),
                      let image = ImagePipeline.decode(
                        original,
                        maxPixelSize: ImagePipeline.maxPixelSize(
                            forDisplaySize: displaySize,
                            targetWidth: job.displayWidth
                        )
                      )
                else {
                    throw PreheatError.undecodable
                }
                try Task.checkCancellation()
                if let payload = ImagePipeline.encodeJPEG(image, quality: Self.displayJPEGQuality) {
                    try? cache.store(payload, forKey: job.displayKey, pool: .display)
                    needsEviction = true
                }
            }
            completed += 1
        } catch {
            if error is CancellationError { return }
            failed += 1
            logger.error(
                "Preheat failed for \(job.item.path): \(error.localizedDescription)",
                privacy: .private
            )
        }
    }

    private func finish(id: UUID, job: Job) {
        runningTasks.removeValue(forKey: id)
        inFlightKeys.remove(job.originalKey)
        pump()
        evictIfIdle()
    }

    /// LRU/TTL sweep, deferred until the queues drain: eviction scans the
    /// whole cache directory, which is too expensive to run per file.
    private func evictIfIdle() {
        guard needsEviction, runningTasks.isEmpty, queues.values.allSatisfy(\.isEmpty)
        else { return }
        needsEviction = false
        let cache = cache
        Task.detached(priority: .utility) { try? cache.evictIfNeeded() }
    }

    private func recordBytes(_ bytes: Int64) {
        let timestamp = now()
        samples.append((timestamp, bytes))
        let cutoff = timestamp - Self.throughputWindow
        samples.removeAll { $0.at < cutoff }
    }

    private func sleep(seconds: TimeInterval) async throws {
        // Clamp the wait so a miscalculated charge can never stall a job for
        // longer than an hour; normal delays are sub-second.
        let nanos = Int64(min(seconds, 3600) * 1_000_000_000)
        try await Task.sleep(for: .nanoseconds(nanos))
    }
}
