import AppKit
import CacheKit
import ReaderKit
import SourceKit
import TraceKit

/// Creates Reader content, loading infrastructure, view models, and windows.
///
/// The coordinator also owns the asynchronous CBZ-open intent. A generation
/// guard makes a newer navigation/open request authoritative even when an old
/// archive read does not respond to cancellation immediately.
@MainActor
final class ReaderCoordinator: NSObject {
    private let cache: CacheStore
    private let preheatService: PreheatService
    private let settings: SettingsService
    private let logger = TraceLogger(category: "Reader")

    private var readerController: PagedReaderWindowController?
    private var openTask: Task<Void, Never>?
    private var openGeneration = 0
    /// The presented directory's images in page order; nil in comic mode,
    /// where prefetching is pointless (the archive is already cached whole).
    private var directoryPrefetchItems: [ContentItem]?
    /// The current comic-mode loader. Set only when a comic presentation
    /// actually built one (production `present` path); nil in directory
    /// mode and while `presentContent` is substituted by tests. Powers
    /// the `warmPages` default.
    private var comicLoader: ReaderImageLoader?
    /// The current comic-mode page count, for computing warm ranges.
    private var comicPageCount: Int?
    /// Session state of the presented reader, used by mode switching.
    private var sessionPages: [ReaderPage]?
    private var sessionLoader: ReaderImageLoader?
    private var pagedViewModel: ReaderViewModel?
    private var stripViewModel: ContinuousReaderViewModel?

    var onError: ((_ error: Error, _ title: String) -> Void)?
    var onMessageError: ((_ message: String, _ title: String) -> Void)?

    /// Presentation seam: production shows the reader window; tests
    /// substitute a recorder to observe what an open intent would present.
    /// Its two consumers are the production default and tests, nothing else.
    /// (Lazy so the default may weakly capture the fully-initialized self.)
    lazy var presentContent: @MainActor (ReaderContent, Int, String, ReaderMode) -> Void = { [weak self] content, startIndex, sourceID, mode in
        self?.present(content: content, startIndex: startIndex, sourceID: sourceID, mode: mode)
    }

    /// Prefetch seam, same pattern as `presentContent`: production forwards
    /// to the preheat service; tests substitute a recorder.
    lazy var submitPrefetch: ([ContentItem]) -> Void = { [weak self] items in
        self?.preheatService.prefetchPages(items)
    }

    /// Warm seam, same pattern as `submitPrefetch`: production pre-decodes
    /// the given comic pages on a detached task (decode is CPU-bound and
    /// must stay off the main actor); tests substitute a recorder. Invoked
    /// in comic mode only — directory-mode display variants depend on
    /// network bytes the prefetch path already covers.
    lazy var warmPages: ([Int]) -> Void = { [weak self] indices in
        guard let loader = self?.comicLoader else { return }
        Task.detached(priority: .utility) {
            for index in indices {
                await loader.warm(pageAt: index)
            }
        }
    }

    init(cache: CacheStore, preheatService: PreheatService, settings: SettingsService) {
        self.cache = cache
        self.preheatService = preheatService
        self.settings = settings
        super.init()
    }

    /// Cancels an archive open that has not presented its window yet. The
    /// currently visible Reader is intentionally left open.
    func cancelPendingOpen() {
        openGeneration += 1
        openTask?.cancel()
        openTask = nil
    }

    func openDirectory(
        items: [ContentItem],
        selectedPath: String,
        sourceID: String,
        fileReader: @escaping @Sendable (String) async throws -> Data,
        bypassOriginalPool: Bool = false
    ) {
        cancelPendingOpen()
        guard let startIndex = items.firstIndex(where: { $0.path == selectedPath }) else {
            onMessageError?("无法定位图片。", "打开阅读器失败")
            return
        }
        let content = ReaderContent.directory(
            items: items,
            fileReader: fileReader,
            cache: bypassOriginalPool ? nil : cache,
            sourceID: sourceID
        )
        directoryPrefetchItems = items
        comicPageCount = nil
        presentContent(content, startIndex, sourceID, preferredMode(forComic: false))
        // Open trigger: warm the two pages after the start page, so the
        // first page turn hits the cache.
        prefetchFollowing(from: startIndex)
    }

    func openComic(
        item: ContentItem,
        sourceID: String,
        fileReader: @escaping @Sendable (String) async throws -> Data,
        isSourceCurrent: @escaping @MainActor () -> Bool,
        bypassOriginalPool: Bool = false
    ) {
        cancelPendingOpen()
        directoryPrefetchItems = nil
        let generation = openGeneration
        openTask = Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await ReaderContent.comic(
                    item: item,
                    fileReader: fileReader,
                    cache: bypassOriginalPool ? nil : cache,
                    sourceID: sourceID
                )
                guard generation == openGeneration, isSourceCurrent() else { return }
                openTask = nil
                presentContent(content, 0, sourceID, preferredMode(forComic: true))
                comicPageCount = content.cachePages.count
                // Open trigger: warm the two pages after the first page.
                warmPages(upcomingWarmIndices(from: 0))
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                guard generation == openGeneration else { return }
                openTask = nil
                onError?(error, "打开漫画失败")
            }
        }
    }

    private func present(content: ReaderContent, startIndex: Int, sourceID: String, mode: ReaderMode) {
        readerController?.close()
        let targetWidth = ScreenGeometry.mainScreenPixelWidth
        let loader = ReaderImageLoader(
            cache: cache,
            sourceID: sourceID,
            targetWidth: targetWidth,
            logger: logger,
            content: content
        )
        let viewModel = ReaderViewModel(
            pages: content.pages,
            startIndex: startIndex,
            loader: loader,
            logger: logger
        )
        // Comic mode keeps the loader for `warmPages`; directory mode's
        // display variants are the prefetch path's business.
        comicLoader = (directoryPrefetchItems == nil) ? loader : nil
        sessionPages = content.pages
        sessionLoader = loader
        pagedViewModel = viewModel
        // Page-turn trigger: the only seam between the reader and
        // prefetching/warming — the view model never learns why we listen.
        viewModel.onPageChanged = { [weak self] index in
            self?.pageDidChange(at: index)
        }
        let reader = PagedReaderWindowController(viewModel: viewModel, initialMode: mode)
        reader.onModeSwitch = { [weak self] in
            self?.toggleReaderMode()
        }
        readerController = reader
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(readerWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: reader.window
        )
        if mode == .strip {
            presentStrip(startIndex: startIndex)
        }
        reader.showWindow(nil)
    }

    /// Builds and embeds the strip surface for the current session,
    /// starting at the given page (mode switches preserve the page).
    private func presentStrip(startIndex: Int) {
        guard let reader = readerController,
              let pages = sessionPages,
              let loader = sessionLoader else { return }
        let strip = ContinuousReaderViewModel(
            pages: pages,
            startIndex: startIndex,
            loader: loader,
            logger: logger
        )
        // Strip warm window (one screen ahead): comic pages pre-decode,
        // directory pages prefetch original bytes — the same pipelines the
        // paged mode drives through page turns.
        strip.onWarmWindow = { [weak self] indices in
            guard let self else { return }
            if directoryPrefetchItems != nil {
                prefetchIndices(indices)
            } else {
                warmPages(indices)
            }
        }
        stripViewModel = strip
        reader.showStrip(ContinuousReaderView(viewModel: strip))
    }

    private func toggleReaderMode() {
        guard let reader = readerController, let paged = pagedViewModel else { return }
        // Persist the choice per content kind; the next open of the same
        // kind starts there instead of at the kind's default.
        let isComic = directoryPrefetchItems == nil
        switch reader.mode {
        case .paged:
            presentStrip(startIndex: paged.currentPageIndex)
            settings.setReaderModeRawValue(ReaderMode.strip.rawValue, forComic: isComic)
        case .strip:
            let index = stripViewModel?.currentPage ?? paged.currentPageIndex
            stripViewModel?.tearDown()
            stripViewModel = nil
            reader.showPaged()
            paged.jumpToPage(index)
            settings.setReaderModeRawValue(ReaderMode.paged.rawValue, forComic: isComic)
        }
    }

    /// The open-time mode for one content kind: the user's saved preference
    /// wins; otherwise the kind's default (comic → strip, directory → paged).
    private func preferredMode(forComic comic: Bool) -> ReaderMode {
        if let raw = settings.readerModeRawValue(forComic: comic),
           let mode = ReaderMode(rawValue: raw) {
            return mode
        }
        return comic ? .strip : .paged
    }

    /// Page-turn dispatch, wired to `onPageChanged`: directory mode
    /// continues original-byte prefetch; comic mode pre-decodes the next
    /// display variants (its bytes are local — the cost is CPU, not the
    /// network).
    func pageDidChange(at index: Int) {
        if directoryPrefetchItems != nil {
            prefetchFollowing(from: index)
        } else {
            warmPages(upcomingWarmIndices(from: index))
        }
    }

    /// The at most two comic pages after `index` that still exist.
    private func upcomingWarmIndices(from index: Int) -> [Int] {
        guard let count = comicPageCount, count > index + 1 else { return [] }
        return Array((index + 1)..<min(index + 3, count))
    }

    /// Submits the two pages after `index` for original-pool prefetch.
    /// Directory mode only; repeat submissions are deduped by the
    /// scheduler, and already-downloaded pages are skipped there too.
    private func prefetchFollowing(from index: Int) {
        guard let items = directoryPrefetchItems else { return }
        let upcoming = items.dropFirst(index + 1).prefix(2)
        guard !upcoming.isEmpty else { return }
        submitPrefetch(Array(upcoming))
    }

    /// Prefetches original bytes for the strip's warm window. Directory
    /// mode only; same dedupe/skipping as `prefetchFollowing`.
    private func prefetchIndices(_ indices: [Int]) {
        guard let items = directoryPrefetchItems, !indices.isEmpty else { return }
        submitPrefetch(indices.map { items[$0] })
    }

    @objc private func readerWindowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: notification.object as? NSWindow
        )
        if readerController?.window === (notification.object as? NSWindow) {
            stripViewModel?.tearDown()
            stripViewModel = nil
            pagedViewModel = nil
            sessionPages = nil
            sessionLoader = nil
            readerController = nil
            // Drop the comic loader with the window: it pins the whole
            // in-memory archive.
            comicLoader = nil
            comicPageCount = nil
        }
    }
}
