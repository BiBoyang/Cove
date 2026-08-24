import AppKit
import CacheKit
import SourceKit

/// Owns the single PDF reader window and wires its failures into the shared
/// error pipeline. Opening another PDF replaces the current window.
///
/// The data path is the same whole-file original-pool layering the CBZ
/// reader uses (`ReaderContent.originalBytes`): cache hit returns instantly,
/// a miss downloads via `fileReader` and best-effort stores the raw bytes.
@MainActor
final class PdfReaderCoordinator: NSObject {
    private let cache: CacheStore
    private var controller: PdfReaderWindowController?

    var onError: ((_ error: Error, _ title: String) -> Void)?
    var onMessageError: ((_ message: String, _ title: String) -> Void)?

    init(cache: CacheStore) {
        self.cache = cache
        super.init()
    }

    func open(
        item: ContentItem,
        sourceID: String,
        fileReader: @escaping @Sendable (String) async throws -> Data,
        bypassOriginalPool: Bool = false
    ) {
        let cache: CacheStore? = bypassOriginalPool ? nil : self.cache
        let viewModel = PdfReaderViewModel(title: item.name) {
            try await ReaderContent.originalBytes(
                for: item, fileReader: fileReader, cache: cache, sourceID: sourceID
            )
        }
        viewModel.onFailure = { [weak self] failure in
            switch failure {
            case .load(let error):
                self?.onError?(error, "打开 PDF 失败")
            case .invalidDocument:
                self?.onMessageError?("文件损坏或不是有效的 PDF。", "打开 PDF 失败")
            }
        }
        controller?.close()
        let controller = PdfReaderWindowController(viewModel: viewModel)
        self.controller = controller
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(readerWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: controller.window
        )
        controller.showWindow(nil)
    }

    /// Closes the window if its document is still loading — the open counts
    /// as pending until then. An already-readable document stays open,
    /// matching the image reader's treatment of visible windows.
    func cancelPendingOpen() {
        guard let controller, controller.isLoading else { return }
        controller.close()
    }

    @objc private func readerWindowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: notification.object as? NSWindow
        )
        if controller?.window === (notification.object as? NSWindow) {
            controller = nil
        }
    }
}
