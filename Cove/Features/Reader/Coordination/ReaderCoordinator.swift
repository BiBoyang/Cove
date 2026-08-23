import AppKit
import CacheKit
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
    private let logger = TraceLogger(category: "Reader")

    private var readerController: PagedReaderWindowController?
    private var openTask: Task<Void, Never>?
    private var openGeneration = 0
    /// The presented directory's images in page order; nil in comic mode,
    /// where prefetching is pointless (the archive is already cached whole).
    private var directoryPrefetchItems: [ContentItem]?

    var onError: ((_ error: Error, _ title: String) -> Void)?
    var onMessageError: ((_ message: String, _ title: String) -> Void)?

    /// Presentation seam: production shows the reader window; tests
    /// substitute a recorder to observe what an open intent would present.
    /// Its two consumers are the production default and tests, nothing else.
    /// (Lazy so the default may weakly capture the fully-initialized self.)
    lazy var presentContent: @MainActor (ReaderContent, Int, String) -> Void = { [weak self] content, startIndex, sourceID in
        self?.present(content: content, startIndex: startIndex, sourceID: sourceID)
    }

    /// Prefetch seam, same pattern as `presentContent`: production forwards
    /// to the preheat service; tests substitute a recorder.
    lazy var submitPrefetch: ([ContentItem]) -> Void = { [weak self] items in
        self?.preheatService.prefetchPages(items)
    }

    init(cache: CacheStore, preheatService: PreheatService) {
        self.cache = cache
        self.preheatService = preheatService
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
        fileReader: @escaping @Sendable (String) async throws -> Data
    ) {
        cancelPendingOpen()
        guard let startIndex = items.firstIndex(where: { $0.path == selectedPath }) else {
            onMessageError?("无法定位图片。", "打开阅读器失败")
            return
        }
        let content = ReaderContent.directory(
            items: items,
            fileReader: fileReader,
            cache: cache,
            sourceID: sourceID
        )
        directoryPrefetchItems = items
        presentContent(content, startIndex, sourceID)
        // Open trigger: warm the two pages after the start page, so the
        // first page turn hits the cache.
        prefetchFollowing(from: startIndex)
    }

    func openComic(
        item: ContentItem,
        sourceID: String,
        fileReader: @escaping @Sendable (String) async throws -> Data,
        isSourceCurrent: @escaping @MainActor () -> Bool
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
                    cache: cache,
                    sourceID: sourceID
                )
                guard generation == openGeneration, isSourceCurrent() else { return }
                openTask = nil
                presentContent(content, 0, sourceID)
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                guard generation == openGeneration else { return }
                openTask = nil
                onError?(error, "打开漫画失败")
            }
        }
    }

    private func present(content: ReaderContent, startIndex: Int, sourceID: String) {
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
        // Page-turn trigger: the only seam between the reader and
        // prefetching — the view model never learns why we listen.
        viewModel.onPageChanged = { [weak self] index in
            self?.prefetchFollowing(from: index)
        }
        let reader = PagedReaderWindowController(viewModel: viewModel)
        readerController = reader
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(readerWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: reader.window
        )
        reader.showWindow(nil)
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

    @objc private func readerWindowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: notification.object as? NSWindow
        )
        if readerController?.window === (notification.object as? NSWindow) {
            readerController = nil
        }
    }
}
