import AppKit
import CacheKit
import Foundation
import PreheatKit
import SourceKit
import Testing
@testable import Cove

@Suite("Directory preheat service")
@MainActor
struct PreheatServiceTests {
    /// Isolated settings + temp cache + the service under test.
    private func makeService(
        cacheRoot: URL,
        preheatFolders: [String] = [],
        suiteName: String = "PreheatServiceTests-\(UUID().uuidString)"
    ) -> PreheatService {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsService(defaults: defaults)
        settings.preheatFolders = preheatFolders
        return PreheatService(
            settings: settings,
            cacheStore: CacheStore(rootDirectory: cacheRoot, capacityBytes: 1_000_000_000, ttl: 3600)
        )
    }

    private func makeCacheRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("preheat-service-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func image(_ name: String, at directory: String, size: Int64) -> ContentItem {
        ContentItem(
            name: name, path: "\(directory)/\(name)",
            isDirectory: false, size: size, modifiedDate: nil
        )
    }

    @Test("directory preheat jumps ahead of queued userFolder jobs", .timeLimit(.minutes(1)))
    func directoryJobsJumpUserFolderQueue() async throws {
        let cacheRoot = makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let service = makeService(cacheRoot: cacheRoot, preheatFolders: ["media/folderA"])
        let png = makeTestPNG()
        let size = Int64(png.count)
        let source = FakeSource(
            files: [
                "/folderA/a1.jpg": png, "/folderA/a2.jpg": png, "/folderA/a3.jpg": png,
                "/dirB/b1.jpg": png,
            ],
            listings: [
                "/folderA": (1...3).map { image("a\($0).jpg", at: "/folderA", size: size) },
                "/dirB": [image("b1.jpg", at: "/dirB", size: size)],
            ],
            readDelayNanoseconds: 250_000_000
        )
        service.connectionReady(source: source, share: "media")

        // maxConcurrent is 2: a1/a2 go in flight, a3 waits at .userFolder.
        try await waitUntil("userFolder jobs did not start") { await source.readCount == 2 }

        service.preheatDirectory(path: "/dirB")

        try await waitUntil("not all jobs finished") { await source.readCount == 4 }
        let reads = await source.readPaths
        // The directory job (.currentDirectory) runs before the queued
        // userFolder job once a slot frees up.
        #expect(reads[2] == "/dirB/b1.jpg")
        #expect(reads[3] == "/folderA/a3.jpg")
    }

    @Test("cancelling the directory preheat leaves the userFolder queue intact", .timeLimit(.minutes(1)))
    func cancelKeepsUserFolderQueue() async throws {
        let cacheRoot = makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let service = makeService(cacheRoot: cacheRoot, preheatFolders: ["media/folderA"])
        let png = makeTestPNG()
        let size = Int64(png.count)
        let source = FakeSource(
            files: [
                "/folderA/a1.jpg": png, "/folderA/a2.jpg": png, "/folderA/a3.jpg": png,
                "/dirB/b1.jpg": png, "/dirB/b2.jpg": png, "/dirB/b3.jpg": png, "/dirB/b4.jpg": png,
            ],
            listings: [
                "/folderA": (1...3).map { image("a\($0).jpg", at: "/folderA", size: size) },
                "/dirB": (1...4).map { image("b\($0).jpg", at: "/dirB", size: size) },
            ],
            readDelayNanoseconds: 250_000_000
        )
        service.connectionReady(source: source, share: "media")
        try await waitUntil("userFolder jobs did not start") { await source.readCount == 2 }

        service.preheatDirectory(path: "/dirB")
        try await waitUntil("directory images were not enumerated") {
            await service.directoryPreheatProgress()?.total == 4
        }

        service.cancelDirectoryPreheat()

        #expect(!service.isDirectoryPreheatActive)
        #expect(await service.directoryPreheatProgress() == nil)

        // a1/a2 were in flight, a3 was queued at .userFolder: exactly those
        // three run; the cancelled directory jobs never start.
        try await waitUntil("userFolder queue did not drain") { await source.readCount == 3 }
        try await Task.sleep(for: .milliseconds(500))
        let reads = await source.readPaths
        #expect(reads.count == 3)
        #expect(reads.allSatisfy { $0.hasPrefix("/folderA/") })
    }

    @Test("directory preheat without a connection is a safe no-op")
    func noConnectionIsNoOp() async throws {
        let cacheRoot = makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let service = makeService(cacheRoot: cacheRoot)

        service.preheatDirectory(path: "/dirB")
        service.cancelDirectoryPreheat()

        #expect(!service.isDirectoryPreheatActive)
        #expect(await service.directoryPreheatProgress() == nil)
    }

    @Test("directory preheat recurses into subdirectories", .timeLimit(.minutes(1)))
    func preheatRecursesSubdirectories() async throws {
        let cacheRoot = makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let service = makeService(cacheRoot: cacheRoot)
        let png = makeTestPNG()
        let size = Int64(png.count)
        let subdirectory = ContentItem(
            name: "sub", path: "/dirB/sub",
            isDirectory: true, size: 0, modifiedDate: nil
        )
        let source = FakeSource(
            files: ["/dirB/b1.jpg": png, "/dirB/sub/s1.jpg": png],
            listings: [
                "/dirB": [image("b1.jpg", at: "/dirB", size: size), subdirectory],
                "/dirB/sub": [image("s1.jpg", at: "/dirB/sub", size: size)],
            ]
        )
        service.connectionReady(source: source, share: "media")

        service.preheatDirectory(path: "/dirB")

        // The subdirectory image is enumerated and submitted too.
        try await waitUntil("subdirectory images were not enumerated") {
            await service.directoryPreheatProgress()?.total == 2
        }
        try await waitUntil("directory preheat did not complete") {
            await service.directoryPreheatProgress()?.isComplete == true
        }
        let reads = await source.readPaths
        #expect(reads.contains("/dirB/b1.jpg"))
        #expect(reads.contains("/dirB/sub/s1.jpg"))
        let progress = await service.directoryPreheatProgress()
        #expect(progress?.truncatedAtCap == nil)
    }

    @Test("hitting the file cap marks the progress as truncated", .timeLimit(.minutes(1)))
    func hittingFileCapMarksTruncated() async throws {
        let cacheRoot = makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let service = makeService(cacheRoot: cacheRoot)
        // Exactly the cap's worth of images; no payloads needed — the
        // preheat is cancelled as soon as the truncated flag is observed.
        let cap = FolderEnumerator.defaultMaxFiles
        let source = FakeSource(
            files: [:],
            listings: [
                "/big": (1...cap).map { image("img\($0).jpg", at: "/big", size: 10) },
            ]
        )
        service.connectionReady(source: source, share: "media")

        service.preheatDirectory(path: "/big")

        try await waitUntil("enumeration did not hit the cap") {
            await service.directoryPreheatProgress()?.total == cap
        }
        #expect(await service.directoryPreheatProgress()?.truncatedAtCap == cap)

        service.cancelDirectoryPreheat()
        #expect(!service.isDirectoryPreheatActive)
    }

    @Test("progress tracks the directory batch through completion", .timeLimit(.minutes(1)))
    func progressTracksCompletion() async throws {
        let cacheRoot = makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let service = makeService(cacheRoot: cacheRoot)
        let png = makeTestPNG()
        let size = Int64(png.count)
        let source = FakeSource(
            files: ["/dirB/b1.jpg": png, "/dirB/b2.jpg": png],
            listings: [
                "/dirB": (1...2).map { image("b\($0).jpg", at: "/dirB", size: size) },
            ]
        )
        service.connectionReady(source: source, share: "media")

        service.preheatDirectory(path: "/dirB")

        try await waitUntil("directory images were not enumerated") {
            await service.directoryPreheatProgress()?.total == 2
        }
        try await waitUntil("directory preheat did not complete") {
            await service.directoryPreheatProgress()?.isComplete == true
        }
        let progress = await service.directoryPreheatProgress()
        #expect(progress?.total == 2)
        #expect(progress?.remaining == 0)
        #expect(progress?.failed == 0)
    }
}

/// Polls `condition` until it holds, yielding so queued continuations can
/// run. Throws (and thus fails the test) on timeout instead of hanging.
@MainActor
private func waitUntil(
    _ message: @autoclosure () -> String = "condition not met before timeout",
    _ condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while await !condition() {
        if ContinuousClock.now > deadline {
            throw PreheatWaitTimeout(message: message())
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private struct PreheatWaitTimeout: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// A genuine tiny PNG: scheduler jobs decode the payload, so test files
/// must be real images.
private func makeTestPNG() -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 8,
        pixelsHigh: 8,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    return rep.representation(using: .png, properties: [:])!
}

/// In-memory `ContentSource`: serves fixed payloads and listings, records
/// read-start order, optionally delays each read so priority assertions
/// stay deterministic. The path is recorded *before* the delay, so tests
/// can observe "in flight" (started but not finished) jobs.
private actor FakeSource: ContentSource {
    let sourceID = "fake://preheat-service-tests"

    private let files: [String: Data]
    private let listings: [String: [ContentItem]]
    private let readDelayNanoseconds: UInt64
    private(set) var readPaths: [String] = []

    init(
        files: [String: Data],
        listings: [String: [ContentItem]],
        readDelayNanoseconds: UInt64 = 0
    ) {
        self.files = files
        self.listings = listings
        self.readDelayNanoseconds = readDelayNanoseconds
    }

    var readCount: Int { readPaths.count }

    func connect() async throws {}
    func disconnect() async {}

    func list(at path: String) async throws -> [ContentItem] {
        guard let entries = listings[path] else { throw SourceError.pathNotFound(path) }
        return entries
    }

    func metadata(at path: String) async throws -> ContentItem {
        guard let data = files[path] else { throw SourceError.pathNotFound(path) }
        return ContentItem(
            name: (path as NSString).lastPathComponent,
            path: path,
            isDirectory: false,
            size: Int64(data.count),
            modifiedDate: nil
        )
    }

    func read(at path: String, range: Range<Int64>) async throws -> Data {
        guard let data = files[path] else { throw SourceError.pathNotFound(path) }
        readPaths.append(path)
        if readDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: readDelayNanoseconds)
        }
        return data
    }
}
