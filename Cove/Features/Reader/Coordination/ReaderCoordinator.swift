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
    private let logger = TraceLogger(category: "Reader")

    private var readerController: PagedReaderWindowController?
    private var openTask: Task<Void, Never>?
    private var openGeneration = 0

    var onError: ((_ error: Error, _ title: String) -> Void)?
    var onMessageError: ((_ message: String, _ title: String) -> Void)?

    init(cache: CacheStore) {
        self.cache = cache
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
        present(content: content, startIndex: startIndex, sourceID: sourceID)
    }

    func openComic(
        item: ContentItem,
        sourceID: String,
        fileReader: @escaping @Sendable (String) async throws -> Data,
        isSourceCurrent: @escaping @MainActor () -> Bool
    ) {
        cancelPendingOpen()
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
                present(content: content, startIndex: 0, sourceID: sourceID)
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
