import CoreGraphics
import Foundation
import ReaderKit
import SourceKit
import Synchronization
import Testing
import TraceKit
@testable import Cove

@Suite("Browser presentation")
@MainActor
struct BrowserViewModelTests {
    @Test("filters metadata and sorts directories before files")
    func visibleItems() {
        let items = [
            ContentItem(name: "10.jpg", path: "/10.jpg", isDirectory: false, size: 10, modifiedDate: nil),
            ContentItem(name: "._2.jpg", path: "/._2.jpg", isDirectory: false, size: 1, modifiedDate: nil),
            ContentItem(name: "Folder", path: "/Folder", isDirectory: true, size: 0, modifiedDate: nil),
            ContentItem(name: ".DS_Store", path: "/.DS_Store", isDirectory: false, size: 1, modifiedDate: nil),
            ContentItem(name: "__MACOSX", path: "/__MACOSX", isDirectory: true, size: 0, modifiedDate: nil),
            ContentItem(name: "2.jpg", path: "/2.jpg", isDirectory: false, size: 2, modifiedDate: nil),
        ]

        let visible = BrowserViewModel.visibleItems(from: items)

        #expect(visible.map(\.name) == ["Folder", "2.jpg", "10.jpg"])
    }

    @Test("exposes images and item lookup from displayed state")
    func projections() {
        let viewModel = BrowserViewModel()
        let image = ContentItem(name: "1.jpg", path: "/1.jpg", isDirectory: false, size: 1, modifiedDate: nil)
        let comic = ContentItem(name: "book.cbz", path: "/book.cbz", isDirectory: false, size: 2, modifiedDate: nil)

        viewModel.display(items: [comic, image], path: "/", title: "share")

        #expect(viewModel.imageItems == [image])
        #expect(viewModel.item(atPath: comic.path) == comic)
    }
}

@Suite("Server presentation")
@MainActor
struct ServerViewModelTests {
    @Test("table rows account for the section header")
    func serverRows() {
        let server = ServerConfig(id: UUID(), host: "nas", username: "user")
        let viewModel = ServerListViewModel()
        viewModel.update(servers: [server])

        #expect(viewModel.server(atTableRow: 0) == nil)
        #expect(viewModel.server(atTableRow: 1) == server)
        #expect(viewModel.server(atTableRow: 2) == nil)
    }

    @Test("share placeholders reflect loading, empty, and content states")
    func shareStates() {
        let viewModel = ShareGridViewModel()
        viewModel.showLoading()
        #expect(viewModel.state.placeholder == "正在获取共享列表…")

        viewModel.display(shares: [])
        #expect(viewModel.state.placeholder == "该服务器没有可用共享")

        let share = SMBShareInfo(name: "media", comment: "")
        viewModel.display(shares: [share])
        #expect(viewModel.state.shares == [share])
        #expect(viewModel.state.placeholder == nil)
    }
}

@Suite("Preferences presentation")
@MainActor
struct PreferencesViewModelTests {
    @Test("validates numeric settings and deduplicates folders")
    func settingsMapping() {
        let settings = MockPreferencesSettings()
        let viewModel = PreferencesViewModel(settings: settings, cache: EmptyPreferencesCache())

        #expect(viewModel.setCapacity(text: "40"))
        #expect(!viewModel.setCapacity(text: "0"))
        #expect(viewModel.setTTL(text: "14"))
        #expect(viewModel.setRateLimit(text: "2.5"))
        #expect(!viewModel.setRateLimit(text: "-1"))
        #expect(viewModel.addFolder(" share/books "))
        #expect(!viewModel.addFolder("share/books"))
        #expect(viewModel.removeFolder(at: 0))
        #expect(!viewModel.removeFolder(at: 0))

        #expect(settings.cacheCapacityGB == 40)
        #expect(settings.cacheTTLDays == 14)
        #expect(settings.preheatRateLimitMBps == 2.5)
        #expect(settings.preheatFolders.isEmpty)
    }

    @Test("a stale refresh cannot overwrite the result of a newer clear", .timeLimit(.minutes(1)))
    func staleUsageIsDiscardedAfterClear() async throws {
        let cache = ScriptedUsageCache()
        let viewModel = PreferencesViewModel(settings: MockPreferencesSettings(), cache: cache)

        // Old refresh parks inside its first usage() read (a semaphore
        // block that, like real disk IO, ignores task cancellation).
        viewModel.reload()
        await cache.waitForFirstUsageToStart()

        // The clear supersedes it: cancels the refresh task, wipes the
        // store, and reads 0/0 back.
        viewModel.clearCache()
        try await waitUntil {
            viewModel.state.originalUsageBytes == 0 && viewModel.state.displayUsageBytes == 0
        }

        // Release the stale refresh; it finishes with the old numbers
        // (111/222) after the clear already landed.
        cache.releaseFirstUsage()
        try await waitUntil { cache.firstUsageFinished }

        // Let any queued main-actor continuation from the stale task run.
        for _ in 0..<10 { await Task.yield() }

        #expect(viewModel.state.originalUsageBytes == 0)
        #expect(viewModel.state.displayUsageBytes == 0)
    }

    @Test("a stale clear failure cannot surface after a newer clear succeeded", .timeLimit(.minutes(1)))
    func staleClearErrorIsDiscarded() async throws {
        let cache = TwoPhaseClearCache()
        let errors = Mutex<[String]>([])
        let viewModel = PreferencesViewModel(settings: MockPreferencesSettings(), cache: cache)
        viewModel.onClearError = { message in
            errors.withLock { $0.append(message) }
        }

        // First clear parks inside clearAll() and is destined to fail.
        viewModel.clearCache()
        await cache.waitForFirstClearToStart()

        // A second clear supersedes it and succeeds.
        viewModel.clearCache()
        try await waitUntil {
            viewModel.state.originalUsageBytes == 0 && viewModel.state.displayUsageBytes == 0
        }

        // Release the stale failing clear after the new one landed.
        cache.releaseFirstClear()
        try await waitUntil { cache.firstClearFailed }
        for _ in 0..<10 { await Task.yield() }

        #expect(errors.withLock { $0 }.isEmpty)
        #expect(viewModel.state.originalUsageBytes == 0)
        #expect(viewModel.state.displayUsageBytes == 0)
    }

    @Test("a failed clear reports its error and refreshes usage", .timeLimit(.minutes(1)))
    func clearFailureSurfacesError() async throws {
        let errors = Mutex<[String]>([])
        let viewModel = PreferencesViewModel(settings: MockPreferencesSettings(), cache: FailingClearCache())
        viewModel.onClearError = { message in
            errors.withLock { $0.append(message) }
        }

        viewModel.clearCache()

        try await waitUntil { !errors.withLock { $0 }.isEmpty }
        #expect(errors.withLock { $0 } == ["清空失败"])
        // Usage still refreshed after the failure (real remaining bytes).
        try await waitUntil { viewModel.state.originalUsageBytes == 5 }
        #expect(viewModel.state.displayUsageBytes == 6)
    }
}

/// Polls `condition` on the main actor until it holds, yielding between
/// checks so queued main-actor continuations can run. Throws (and thus
/// fails the test) on timeout instead of hanging.
@MainActor
private func waitUntil(
    _ message: @autoclosure () -> String = "condition not met before timeout",
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
        if ContinuousClock.now > deadline {
            throw WaitTimeout(message: message())
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private struct WaitTimeout: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

@Suite("Reader presentation")
@MainActor
struct ReaderViewModelTests {
    @Test("clamps the start index and exposes paging boundaries")
    func boundaryState() {
        let pages = [ReaderPage(id: "1", title: "1"), ReaderPage(id: "2", title: "2")]
        let viewModel = ReaderViewModel(
            pages: pages,
            startIndex: 99,
            loader: DelayedReaderLoader(),
            logger: TraceLogger(category: "ReaderTests")
        )

        #expect(viewModel.state.pageTitle == "2")
        #expect(viewModel.state.canGoPrevious)
        #expect(!viewModel.state.canGoNext)
    }

    @Test("a slow stale page cannot replace the latest requested page", .timeLimit(.minutes(1)))
    func staleResultIsDiscarded() async throws {
        let pages = [ReaderPage(id: "1", title: "1"), ReaderPage(id: "2", title: "2")]
        let viewModel = ReaderViewModel(
            pages: pages,
            startIndex: 0,
            loader: DelayedReaderLoader(),
            logger: TraceLogger(category: "ReaderTests")
        )

        viewModel.start()
        viewModel.goNext()
        try await Task.sleep(for: .milliseconds(100))
        #expect(viewModel.state.image?.width == 2)

        try await Task.sleep(for: .milliseconds(180))
        #expect(viewModel.state.pageTitle == "2")
        #expect(viewModel.state.image?.width == 2)
    }
}

@MainActor
private final class MockPreferencesSettings: PreferencesSettingsManaging {
    var cacheCapacityGB = 20
    var cacheTTLDays = 7
    var preheatEnabled = true
    var preheatRateLimitMBps = 0.0
    var preheatFolders: [String] = []
}

private struct EmptyPreferencesCache: PreferencesCacheManaging {
    func usage() throws -> (original: Int64, display: Int64) { (0, 0) }
    func clearAll() throws {}
}

/// Cache double whose first `usage()` read parks until the test releases
/// it — modelling a slow disk scan that, like real IO, ignores task
/// cancellation. Later reads return the post-clear numbers.
private final class ScriptedUsageCache: PreferencesCacheManaging, Sendable {
    private let firstUsageStarted = DispatchSemaphore(value: 0)
    private let releaseGate = DispatchSemaphore(value: 0)
    private let usageCount = Mutex(0)
    private let finished = Mutex(false)

    var firstUsageFinished: Bool { finished.withLock { $0 } }

    func waitForFirstUsageToStart() async {
        await Task.detached(priority: .utility) { self.firstUsageStarted.wait() }.value
    }

    func releaseFirstUsage() {
        releaseGate.signal()
    }

    func usage() throws -> (original: Int64, display: Int64) {
        let n = usageCount.withLock { $0 += 1; return $0 }
        if n == 1 {
            firstUsageStarted.signal()
            releaseGate.wait()
            finished.withLock { $0 = true }
            return (111, 222)
        }
        return (0, 0)
    }

    func clearAll() throws {}
}

/// Cache double whose first `clearAll()` parks and then fails; later
/// clears succeed. Usage returns distinct values per call so a stale
/// write would be observable.
private final class TwoPhaseClearCache: PreferencesCacheManaging, Sendable {
    private let firstClearStarted = DispatchSemaphore(value: 0)
    private let releaseGate = DispatchSemaphore(value: 0)
    private let clearCount = Mutex(0)
    private let usageCount = Mutex(0)
    private let failed = Mutex(false)

    var firstClearFailed: Bool { failed.withLock { $0 } }

    func waitForFirstClearToStart() async {
        await Task.detached(priority: .utility) { self.firstClearStarted.wait() }.value
    }

    func releaseFirstClear() {
        releaseGate.signal()
    }

    func usage() throws -> (original: Int64, display: Int64) {
        let n = usageCount.withLock { $0 += 1; return $0 }
        return n == 1 ? (0, 0) : (99, 99)
    }

    func clearAll() throws {
        let n = clearCount.withLock { $0 += 1; return $0 }
        if n == 1 {
            firstClearStarted.signal()
            releaseGate.wait()
            failed.withLock { $0 = true }
            throw ClearFailed()
        }
    }

    private struct ClearFailed: LocalizedError {
        var errorDescription: String? { "旧任务清空失败" }
    }
}

private struct FailingClearCache: PreferencesCacheManaging {
    private struct ClearFailed: LocalizedError {
        var errorDescription: String? { "清空失败" }
    }

    func usage() throws -> (original: Int64, display: Int64) { (5, 6) }

    func clearAll() throws { throw ClearFailed() }
}

private actor DelayedReaderLoader: ReaderPageLoading {
    func load(pageAt index: Int) async throws -> ReaderLoadedImage {
        if index == 0 {
            try? await Task.sleep(for: .milliseconds(220))
        } else {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return ReaderLoadedImage(image: makeImage(width: index + 1), size: CGSize(width: index + 1, height: 1))
    }

    private func makeImage(width: Int) -> CGImage {
        let bytes = [UInt8](repeating: 0xFF, count: width * 4)
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }
}
