import CacheKit
import CoreGraphics
import Foundation
import ImageIO
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

@Suite("Browser preheat button")
@MainActor
struct BrowserPreheatTests {
    private func progress(
        total: Int, remaining: Int, failed: Int = 0, truncatedAtCap: Int? = nil, rate: Double = 1024
    ) -> PreheatService.DirectoryPreheatProgress {
        PreheatService.DirectoryPreheatProgress(
            total: total, remaining: remaining, failed: failed,
            truncatedAtCap: truncatedAtCap, throughputBytesPerSecond: rate
        )
    }

    @Test("the button is unavailable until a directory is displayed")
    func initialState() {
        let viewModel = BrowserViewModel()
        #expect(viewModel.state.preheat == .unavailable)

        viewModel.display(items: [], path: "/", title: "share")
        #expect(viewModel.state.preheat == .ready)
    }

    @Test("monitoring reflects progress and stops once complete", .timeLimit(.minutes(1)))
    func progressToFinished() async throws {
        let viewModel = BrowserViewModel()
        viewModel.display(items: [], path: "/", title: "share")
        let script = ScriptedPreheatProgress([
            progress(total: 4, remaining: 3),
            progress(total: 4, remaining: 0),
        ])
        viewModel.preheatProgressProvider = { script.next() }

        viewModel.startPreheatMonitoring()

        try await waitUntil {
            viewModel.state.preheat == .preheating(completed: 1, total: 4, bytesPerSecond: 1024)
        }
        try await waitUntil { viewModel.state.preheat == .finished(failed: 0, truncatedAtCap: nil) }

        // Completion stops the polling loop.
        let callsAtCompletion = script.callCount
        try await Task.sleep(for: .milliseconds(700))
        #expect(script.callCount == callsAtCompletion)
    }

    @Test("a truncated completion carries the cap into the finished state", .timeLimit(.minutes(1)))
    func finishedCarriesTruncatedCap() async throws {
        let viewModel = BrowserViewModel()
        viewModel.display(items: [], path: "/", title: "share")
        let script = ScriptedPreheatProgress([
            progress(total: 5000, remaining: 0, truncatedAtCap: 5000),
        ])
        viewModel.preheatProgressProvider = { script.next() }

        viewModel.startPreheatMonitoring()

        try await waitUntil {
            viewModel.state.preheat == .finished(failed: 0, truncatedAtCap: 5000)
        }
    }

    @Test("cancelling via the button returns to ready")
    func cancelReturnsToReady() async throws {
        let viewModel = BrowserViewModel()
        viewModel.display(items: [], path: "/", title: "share")
        let script = ScriptedPreheatProgress([progress(total: 4, remaining: 2)])
        viewModel.preheatProgressProvider = { script.next() }
        viewModel.startPreheatMonitoring()
        try await waitUntil {
            viewModel.state.preheat == .preheating(completed: 2, total: 4, bytesPerSecond: 1024)
        }

        viewModel.stopPreheatMonitoring()

        #expect(viewModel.state.preheat == .ready)
    }

    @Test("a nil progress (service-side cancel) returns to ready and stops polling", .timeLimit(.minutes(1)))
    func nilProgressStopsMonitoring() async throws {
        let viewModel = BrowserViewModel()
        viewModel.display(items: [], path: "/", title: "share")
        let script = ScriptedPreheatProgress([progress(total: 4, remaining: 2), nil])
        viewModel.preheatProgressProvider = { script.next() }
        viewModel.startPreheatMonitoring()
        try await waitUntil {
            viewModel.state.preheat == .preheating(completed: 2, total: 4, bytesPerSecond: 1024)
        }

        try await waitUntil { viewModel.state.preheat == .ready }
        let callsAtStop = script.callCount
        try await Task.sleep(for: .milliseconds(700))
        #expect(script.callCount == callsAtStop)
    }

    @Test("displaying a directory resets an active preheat and stops polling", .timeLimit(.minutes(1)))
    func displayResetsPreheat() async throws {
        let viewModel = BrowserViewModel()
        viewModel.display(items: [], path: "/", title: "share")
        let script = ScriptedPreheatProgress([progress(total: 4, remaining: 2)])
        viewModel.preheatProgressProvider = { script.next() }
        viewModel.startPreheatMonitoring()
        try await waitUntil {
            viewModel.state.preheat == .preheating(completed: 2, total: 4, bytesPerSecond: 1024)
        }

        viewModel.display(items: [], path: "/sub", title: "sub")

        #expect(viewModel.state.preheat == .ready)
        let callsAtReset = script.callCount
        try await Task.sleep(for: .milliseconds(700))
        #expect(script.callCount == callsAtReset)
    }
}

/// Progress-provider double: answers with the scripted responses in order,
/// repeating the last one, and counts calls so tests can assert the
/// polling loop stopped.
@MainActor
private final class ScriptedPreheatProgress {
    private var responses: [PreheatService.DirectoryPreheatProgress?]
    private(set) var callCount = 0

    init(_ responses: [PreheatService.DirectoryPreheatProgress?]) {
        self.responses = responses
    }

    func next() -> PreheatService.DirectoryPreheatProgress? {
        callCount += 1
        guard responses.count > 1 else { return responses.first ?? nil }
        return responses.removeFirst()
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

@Suite("Add server validation")
@MainActor
struct AddServerViewModelTests {
    @Test("trims host and username, passes the password through")
    func trimsInput() {
        let viewModel = AddServerViewModel()
        let result = viewModel.submit(host: "  nas.local\n", username: "\tuser ", password: " p ")

        #expect(result == .success(.init(host: "nas.local", username: "user", password: " p ")))
    }

    @Test("rejects an empty or whitespace-only host")
    func emptyHost() {
        let viewModel = AddServerViewModel()

        #expect(viewModel.submit(host: "", username: "user", password: "") == .failure(.emptyHost))
        #expect(viewModel.submit(host: "  \n ", username: "user", password: "") == .failure(.emptyHost))
    }

    @Test("rejects an empty or whitespace-only username")
    func emptyUsername() {
        let viewModel = AddServerViewModel()

        #expect(viewModel.submit(host: "nas", username: "", password: "") == .failure(.emptyUsername))
        #expect(viewModel.submit(host: "nas", username: "  ", password: "") == .failure(.emptyUsername))
    }

    @Test("accepts a fully filled form")
    func valid() {
        let viewModel = AddServerViewModel()
        let result = viewModel.submit(host: "192.168.1.10", username: "admin", password: "secret")

        #expect(result == .success(.init(host: "192.168.1.10", username: "admin", password: "secret")))
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

    @Test("page turns report the new index via onPageChanged")
    func pageTurnsReportIndex() {
        let pages = (1...3).map { ReaderPage(id: "\($0)", title: "\($0)") }
        let viewModel = ReaderViewModel(
            pages: pages,
            startIndex: 0,
            loader: DelayedReaderLoader(),
            logger: TraceLogger(category: "ReaderTests")
        )
        var indices: [Int] = []
        viewModel.onPageChanged = { indices.append($0) }

        viewModel.goNext()
        viewModel.goNext()
        viewModel.goPrevious()
        // Every landed move reports; out-of-range moves do not.
        viewModel.goPrevious()
        viewModel.goPrevious()

        #expect(indices == [1, 2, 1, 0])
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

@Suite("Library navigation path")
struct LibraryNavigationPathTests {
    @Test("navigateInto pushes optimistically and rolls back on failure")
    func navigateIntoRollback() {
        var path = LibraryNavigationPath()
        path.navigateInto("/docs")
        #expect(path.currentPath == "/docs")
        #expect(path.backDestination == .directory("/"))

        path.rollbackInto()
        #expect(path.stack == ["/"])
    }

    @Test("goBack pops to the parent and restores the pop on failure")
    func goBackRestore() {
        var path = LibraryNavigationPath()
        path.navigateInto("/a")
        path.navigateInto("/a/b")
        #expect(path.backDestination == .directory("/a"))

        let popped = path.goBack()
        #expect(popped == "/a/b")
        #expect(path.currentPath == "/a")

        path.restoreAfterFailedGoBack(popped)
        #expect(path.stack == ["/", "/a", "/a/b"])
    }

    @Test("goBack at the share root means leaving to the share grid")
    func goBackAtRoot() {
        let path = LibraryNavigationPath()
        #expect(path.backDestination == .shareGrid)
    }

    @Test("reset returns to the share root")
    func resetToRoot() {
        var path = LibraryNavigationPath()
        path.navigateInto("/a")
        path.reset()
        #expect(path.stack == ["/"])
        #expect(path.backDestination == .shareGrid)
    }

    @Test("browser title is the share name at the root, folder name below")
    func browserTitle() {
        #expect(LibraryNavigationPath.browserTitle(forPath: "/", shareName: "media") == "media")
        #expect(LibraryNavigationPath.browserTitle(forPath: "/", shareName: nil) == "/")
        #expect(LibraryNavigationPath.browserTitle(forPath: "/docs/comics", shareName: "media") == "comics")
    }
}

@Suite("Reader open coordination")
@MainActor
struct ReaderCoordinatorTests {
    private func comicItem(_ name: String, size: Int64) -> ContentItem {
        ContentItem(name: name, path: "/\(name)", isDirectory: false, size: size, modifiedDate: nil)
    }

    /// Coordinator with an isolated (connection-less) preheat service; the
    /// `submitPrefetch` seam is what tests actually observe.
    private func makeReaderCoordinator() -> ReaderCoordinator {
        let defaults = UserDefaults(suiteName: "ReaderCoordinatorTests-\(UUID().uuidString)")!
        return ReaderCoordinator(
            cache: makeTestCache(),
            preheatService: PreheatService(
                settings: SettingsService(defaults: defaults),
                cacheStore: makeTestCache()
            )
        )
    }

    @Test("opening a directory prefetches the two following pages")
    func openPrefetchesNextTwo() {
        let coordinator = makeReaderCoordinator()
        let submitted = Mutex<[[String]]>([])
        coordinator.submitPrefetch = { items in
            submitted.withLock { $0.append(items.map(\.path)) }
        }
        coordinator.presentContent = { _, _, _ in }
        let items = (1...4).map { comicItem("p\($0).jpg", size: 10) }

        coordinator.openDirectory(
            items: items, selectedPath: "/p2.jpg", sourceID: "s", fileReader: { _ in Data() }
        )

        #expect(submitted.withLock { $0 } == [["/p3.jpg", "/p4.jpg"]])
    }

    @Test("prefetch stops at the last page")
    func prefetchStopsAtEnd() {
        let coordinator = makeReaderCoordinator()
        let submitted = Mutex<[[String]]>([])
        coordinator.submitPrefetch = { items in
            submitted.withLock { $0.append(items.map(\.path)) }
        }
        coordinator.presentContent = { _, _, _ in }
        let items = (1...3).map { comicItem("p\($0).jpg", size: 10) }

        // Only one page remains after index 1.
        coordinator.openDirectory(
            items: items, selectedPath: "/p2.jpg", sourceID: "s", fileReader: { _ in Data() }
        )
        #expect(submitted.withLock { $0 } == [["/p3.jpg"]])

        // Nothing follows the last page: no new submission.
        coordinator.openDirectory(
            items: items, selectedPath: "/p3.jpg", sourceID: "s", fileReader: { _ in Data() }
        )
        #expect(submitted.withLock { $0 } == [["/p3.jpg"]])
    }

    @Test("opening a comic does not prefetch", .timeLimit(.minutes(1)))
    func comicOpenDoesNotPrefetch() async throws {
        let coordinator = makeReaderCoordinator()
        let submitted = Mutex<[[String]]>([])
        let presented = Mutex(false)
        coordinator.submitPrefetch = { items in
            submitted.withLock { $0.append(items.map(\.path)) }
        }
        coordinator.presentContent = { _, _, _ in presented.withLock { $0 = true } }
        let bytes = makeTestCBZBytes(pages: ["a1.jpg"])

        coordinator.openComic(
            item: comicItem("a.cbz", size: Int64(bytes.count)),
            sourceID: "s",
            fileReader: { _ in bytes },
            isSourceCurrent: { true }
        )

        try await waitUntil { presented.withLock { $0 } }
        #expect(submitted.withLock { $0 }.isEmpty)
    }

    @Test("a rapid re-open presents only the newer comic", .timeLimit(.minutes(1)))
    func rapidReopenPresentsOnlyNewer() async throws {
        let coordinator = makeReaderCoordinator()
        let presented = Mutex<[[String]]>([])
        coordinator.presentContent = { content, _, _ in
            presented.withLock { $0.append(content.pages.map(\.id)) }
        }

        // Old open parks inside its archive read (a slow network fetch that,
        // like real IO, ignores task cancellation); the new open is instant.
        let slowA = GatedFileReader(payload: makeTestCBZBytes(pages: ["a1.jpg"]))
        let bytesB = makeTestCBZBytes(pages: ["b1.jpg"])
        coordinator.openComic(
            item: comicItem("a.cbz", size: Int64(slowA.payload.count)),
            sourceID: "s",
            fileReader: { path in try await slowA.read(path) },
            isSourceCurrent: { true }
        )
        await slowA.waitUntilStarted()
        coordinator.openComic(
            item: comicItem("b.cbz", size: Int64(bytesB.count)),
            sourceID: "s",
            fileReader: { _ in bytesB },
            isSourceCurrent: { true }
        )

        try await waitUntil { !presented.withLock { $0 }.isEmpty }
        #expect(presented.withLock { $0 } == [["/b.cbz!b1.jpg"]])

        // The stale read finishes after the newer open already landed; its
        // content must never be presented.
        slowA.release()
        try await Task.sleep(for: .milliseconds(100))
        for _ in 0 ..< 10 { await Task.yield() }
        #expect(presented.withLock { $0 } == [["/b.cbz!b1.jpg"]])
    }

    @Test("a cancelled open never presents once its slow read finishes", .timeLimit(.minutes(1)))
    func cancelledOpenDoesNotPresent() async throws {
        let coordinator = makeReaderCoordinator()
        let presented = Mutex<[[String]]>([])
        let errors = Mutex<[String]>([])
        coordinator.presentContent = { content, _, _ in
            presented.withLock { $0.append(content.pages.map(\.id)) }
        }
        coordinator.onError = { _, title in
            errors.withLock { $0.append(title) }
        }

        let slow = GatedFileReader(payload: makeTestCBZBytes(pages: ["a1.jpg"]))
        coordinator.openComic(
            item: comicItem("a.cbz", size: Int64(slow.payload.count)),
            sourceID: "s",
            fileReader: { path in try await slow.read(path) },
            isSourceCurrent: { true }
        )
        await slow.waitUntilStarted()

        coordinator.cancelPendingOpen()
        slow.release()

        // Give the stale task every chance to run to completion.
        try await Task.sleep(for: .milliseconds(100))
        for _ in 0 ..< 10 { await Task.yield() }

        #expect(presented.withLock { $0 }.isEmpty)
        // Cancellation is silent: no error surfaces for a cancelled open.
        #expect(errors.withLock { $0 }.isEmpty)
    }

    @Test("opening a comic warms the two following pages", .timeLimit(.minutes(1)))
    func comicOpenWarmsNextTwo() async throws {
        let coordinator = makeReaderCoordinator()
        let warmed = Mutex<[[Int]]>([])
        coordinator.presentContent = { _, _, _ in }
        coordinator.warmPages = { indices in warmed.withLock { $0.append(indices) } }
        let bytes = makeTestCBZBytes(pages: ["a1.jpg", "a2.jpg", "a3.jpg", "a4.jpg"])

        coordinator.openComic(
            item: comicItem("a.cbz", size: Int64(bytes.count)),
            sourceID: "s",
            fileReader: { _ in bytes },
            isSourceCurrent: { true }
        )

        try await waitUntil { !warmed.withLock { $0 }.isEmpty }
        #expect(warmed.withLock { $0 } == [[1, 2]])
    }

    @Test("a comic page turn warms the following pages", .timeLimit(.minutes(1)))
    func comicPageTurnWarmsFollowing() async throws {
        let coordinator = makeReaderCoordinator()
        let warmed = Mutex<[[Int]]>([])
        coordinator.presentContent = { _, _, _ in }
        coordinator.warmPages = { indices in warmed.withLock { $0.append(indices) } }
        let bytes = makeTestCBZBytes(pages: ["a1.jpg", "a2.jpg", "a3.jpg", "a4.jpg"])

        coordinator.openComic(
            item: comicItem("a.cbz", size: Int64(bytes.count)),
            sourceID: "s",
            fileReader: { _ in bytes },
            isSourceCurrent: { true }
        )
        try await waitUntil { !warmed.withLock { $0 }.isEmpty }

        coordinator.pageDidChange(at: 1)

        #expect(warmed.withLock { $0 } == [[1, 2], [2, 3]])
    }

    @Test("directory mode prefetches and never warms")
    func directoryModeNeverWarms() {
        let coordinator = makeReaderCoordinator()
        let submitted = Mutex<[[String]]>([])
        let warmed = Mutex<[[Int]]>([])
        coordinator.submitPrefetch = { items in
            submitted.withLock { $0.append(items.map(\.path)) }
        }
        coordinator.warmPages = { indices in warmed.withLock { $0.append(indices) } }
        coordinator.presentContent = { _, _, _ in }
        let items = (1...4).map { comicItem("p\($0).jpg", size: 10) }

        coordinator.openDirectory(
            items: items, selectedPath: "/p1.jpg", sourceID: "s", fileReader: { _ in Data() }
        )
        coordinator.pageDidChange(at: 1)

        // Directory turns keep prefetching original bytes…
        #expect(submitted.withLock { $0 } == [["/p2.jpg", "/p3.jpg"], ["/p3.jpg", "/p4.jpg"]])
        // …and never trigger display warm (warm would re-download them).
        #expect(warmed.withLock { $0 }.isEmpty)
    }

    @Test("warm shortens to existing pages near the end", .timeLimit(.minutes(1)))
    func warmStopsAtEnd() async throws {
        let coordinator = makeReaderCoordinator()
        let warmed = Mutex<[[Int]]>([])
        coordinator.presentContent = { _, _, _ in }
        coordinator.warmPages = { indices in warmed.withLock { $0.append(indices) } }
        let bytes = makeTestCBZBytes(pages: ["a1.jpg", "a2.jpg", "a3.jpg"])

        coordinator.openComic(
            item: comicItem("a.cbz", size: Int64(bytes.count)),
            sourceID: "s",
            fileReader: { _ in bytes },
            isSourceCurrent: { true }
        )
        try await waitUntil { !warmed.withLock { $0 }.isEmpty }

        coordinator.pageDidChange(at: 1)
        coordinator.pageDidChange(at: 2)

        // One page remains after 1; nothing remains after the last page.
        #expect(warmed.withLock { $0 } == [[1, 2], [2], []])
    }
}

@Suite("Reader image warm")
struct ReaderImageLoaderWarmTests {
    private let targetWidth = 1024

    /// Comic-mode loader over a real in-memory CBZ (real ComicArchive,
    /// real entry extraction), so warm exercises the production path.
    private func makeComicLoader(
        cache: CacheStore, pages: [String], payload: Data
    ) async throws -> (loader: ReaderImageLoader, archiveSize: Int64) {
        let bytes = makeTestCBZBytes(pages: pages, payload: payload)
        let item = ContentItem(
            name: "a.cbz", path: "/a.cbz", isDirectory: false,
            size: Int64(bytes.count), modifiedDate: nil
        )
        let content = try await ReaderContent.comic(
            item: item, fileReader: { _ in bytes }, cache: cache, sourceID: "s"
        )
        let loader = ReaderImageLoader(
            cache: cache, sourceID: "s", targetWidth: targetWidth,
            logger: TraceLogger(category: "ReaderWarmTests"), content: content
        )
        return (loader, Int64(bytes.count))
    }

    /// Probes the display pool with the production key factory.
    private func comicDisplayKey(archiveSize: Int64, entry: String) -> CacheKey {
        CacheKey.sourceFile(
            sourceID: "s", path: "/a.cbz!\(entry)", fileSize: archiveSize,
            modified: nil, variant: CacheKey.displayWidthVariant(targetWidth)
        )
    }

    @Test("warm decodes a cold comic page into the display pool", .timeLimit(.minutes(1)))
    func warmStoresDisplayVariant() async throws {
        let cache = makeTestCache()
        let (loader, archiveSize) = try await makeComicLoader(
            cache: cache, pages: ["a1.jpg", "a2.jpg", "a3.jpg"], payload: makeTestJPEGData()
        )
        let key = comicDisplayKey(archiveSize: archiveSize, entry: "a2.jpg")
        #expect((try? cache.data(forKey: key, pool: .display)) == nil)

        await loader.warm(pageAt: 1)

        #expect((try? cache.data(forKey: key, pool: .display)) != nil)
    }

    @Test("warm skips an already-warm page before decoding", .timeLimit(.minutes(1)))
    func warmSkipsExistingVariant() async throws {
        let cache = makeTestCache()
        let jpeg = makeTestJPEGData()
        let reads = Mutex(0)
        let item = ContentItem(
            name: "p1.jpg", path: "/p1.jpg", isDirectory: false,
            size: Int64(jpeg.count), modifiedDate: nil
        )
        let content = ReaderContent.directory(
            items: [item],
            fileReader: { _ in
                reads.withLock { $0 += 1 }
                return jpeg
            },
            cache: cache,
            sourceID: "s"
        )
        let loader = ReaderImageLoader(
            cache: cache, sourceID: "s", targetWidth: targetWidth,
            logger: TraceLogger(category: "ReaderWarmTests"), content: content
        )
        // Seed a display variant by hand. Its payload is garbage on
        // purpose: a plain `load` would decode it, fail, and fall through
        // to the original pool (incrementing `reads`). A correct warm
        // returns at the existence check — no decode, no fall-through.
        let key = CacheKey.sourceFile(
            sourceID: "s", path: "/p1.jpg", fileSize: Int64(jpeg.count),
            modified: nil, variant: CacheKey.displayWidthVariant(targetWidth)
        )
        try cache.store(Data("not a jpeg".utf8), forKey: key, pool: .display)

        await loader.warm(pageAt: 0)

        #expect(reads.withLock { $0 } == 0)
    }

    @Test("warm tolerates undecodable pages and out-of-range indices", .timeLimit(.minutes(1)))
    func warmToleratesBadPages() async throws {
        let cache = makeTestCache()
        // The dummy payload parses as a ZIP entry but not as an image.
        let (loader, archiveSize) = try await makeComicLoader(
            cache: cache, pages: ["a1.jpg"], payload: Data("page".utf8)
        )

        await loader.warm(pageAt: 0)
        await loader.warm(pageAt: 7)
        await loader.warm(pageAt: -1)

        let key = comicDisplayKey(archiveSize: archiveSize, entry: "a1.jpg")
        #expect((try? cache.data(forKey: key, pool: .display)) == nil)
    }
}

/// Cache store rooted at a fresh temp directory, for coordinator tests.
private func makeTestCache() -> CacheStore {
    CacheStore(
        rootDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("CoveTests-\(UUID().uuidString)", isDirectory: true),
        capacityBytes: 16 * 1024 * 1024,
        ttl: 3600
    )
}

/// Solid-color CGImage, built the same way the loader double builds its
/// test images.
private func makeSolidImage(width: Int, height: Int) -> CGImage {
    let bytes = [UInt8](repeating: 0xFF, count: width * height * 4)
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    )!
}

/// Real JPEG bytes, so ImagePipeline's decode path is genuinely exercised.
private func makeTestJPEGData(width: Int = 8, height: Int = 8) -> Data {
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
        output, "public.jpeg" as CFString, 1, nil
    )!
    CGImageDestinationAddImage(destination, makeSolidImage(width: width, height: height), nil)
    precondition(CGImageDestinationFinalize(destination), "test JPEG encode failed")
    return output as Data
}

/// Builds genuine CBZ bytes (a minimal ZIP of stored entries) by hand —
/// CoveTests may not import ZIPFoundation, so ComicKit's real parser is
/// exercised against archive bytes it did not write. All entries share
/// one payload; only entry names differ.
private func makeTestCBZBytes(pages: [String], payload: Data = Data("page".utf8)) -> Data {
    let crc = crc32(payload)

    var zip = Data()
    for page in pages {
        let name = Data(page.utf8)
        // Local file header (stored, no compression, no data descriptor).
        zip.appendLE32(0x0403_4B50)
        zip.appendLE16(20)
        zip.appendLE16(0)
        zip.appendLE16(0)
        zip.appendLE16(0)
        zip.appendLE16(0)
        zip.appendLE32(crc)
        zip.appendLE32(UInt32(payload.count))
        zip.appendLE32(UInt32(payload.count))
        zip.appendLE16(UInt16(name.count))
        zip.appendLE16(0)
        zip.append(name)
        zip.append(payload)
    }

    let centralOffset = UInt32(zip.count)
    var central = Data()
    for page in pages {
        let name = Data(page.utf8)
        central.appendLE32(0x0201_4B50)
        central.appendLE16(20)
        central.appendLE16(20)
        central.appendLE16(0)
        central.appendLE16(0)
        central.appendLE16(0)
        central.appendLE16(0)
        central.appendLE32(crc)
        central.appendLE32(UInt32(payload.count))
        central.appendLE32(UInt32(payload.count))
        central.appendLE16(UInt16(name.count))
        central.appendLE16(0)
        central.appendLE16(0)
        central.appendLE16(0)
        central.appendLE16(0)
        central.appendLE32(0)
        central.appendLE32(0)
        central.append(name)
    }
    zip.append(central)

    // End of central directory.
    let entryCount = UInt16(pages.count)
    zip.appendLE32(0x0605_4B50)
    zip.appendLE16(0)
    zip.appendLE16(0)
    zip.appendLE16(entryCount)
    zip.appendLE16(entryCount)
    zip.appendLE32(UInt32(central.count))
    zip.appendLE32(centralOffset)
    zip.appendLE16(0)
    return zip
}

/// CRC-32 (ISO 3309, as ZIP uses), table-free — test payloads are tiny.
private func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0 ..< 8 {
            crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xEDB8_8320 : 0)
        }
    }
    return crc ^ 0xFFFF_FFFF
}

extension Data {
    fileprivate mutating func appendLE16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    fileprivate mutating func appendLE32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8(value >> 24))
    }
}

/// fileReader double whose read parks until the test releases it —
/// modelling a slow network fetch that, like real IO, ignores task
/// cancellation.
private final class GatedFileReader: Sendable {
    let payload: Data
    private let started = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)

    init(payload: Data) {
        self.payload = payload
    }

    func waitUntilStarted() async {
        await Task.detached(priority: .utility) { self.started.wait() }.value
    }

    func release() {
        gate.signal()
    }

    func read(_ path: String) async throws -> Data {
        started.signal()
        gate.wait()
        return payload
    }
}
