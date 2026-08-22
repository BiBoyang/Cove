import CoreGraphics
import Foundation
import ReaderKit
import TraceKit

/// Main-actor state for one single-page Reader session.
///
/// The ViewModel owns paging, cancellation, stale-result rejection, and the
/// state rendered by AppKit. Cache reads and image decoding remain inside the
/// Sendable loader and run in a detached user-initiated task.
@MainActor
final class ReaderViewModel {
    struct State: Sendable {
        let pageTitle: String
        let progressText: String
        let canGoPrevious: Bool
        let canGoNext: Bool
        let image: CGImage?
        let errorMessage: String?
    }

    private let logger: TraceLogger
    private let loader: any ReaderPageLoading
    private let pages: [ReaderPage]
    private var currentIndex: Int
    private var currentImage: CGImage?
    private var errorMessage: String?
    private var loadGeneration = 0
    private var loadingTask: Task<Void, Never>?
    private var isTornDown = false
    private var hasStarted = false

    var onStateChange: ((State) -> Void)? {
        didSet { publishState() }
    }

    var state: State {
        State(
            pageTitle: pages[currentIndex].title,
            progressText: "\(currentIndex + 1)/\(pages.count)",
            canGoPrevious: currentIndex > 0,
            canGoNext: currentIndex < pages.count - 1,
            image: currentImage,
            errorMessage: errorMessage
        )
    }

    init(
        pages: [ReaderPage],
        startIndex: Int,
        loader: any ReaderPageLoading,
        logger: TraceLogger
    ) {
        precondition(!pages.isEmpty, "ReaderViewModel requires at least one page")
        self.pages = pages
        currentIndex = min(max(startIndex, 0), pages.count - 1)
        self.loader = loader
        self.logger = logger
    }

    func start() {
        guard !hasStarted, !isTornDown else { return }
        hasStarted = true
        loadCurrentPage()
    }

    func goPrevious() {
        goToPage(currentIndex - 1)
    }

    func goNext() {
        goToPage(currentIndex + 1)
    }

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        loadGeneration += 1
        loadingTask?.cancel()
        loadingTask = nil
        onStateChange = nil
    }

    private func goToPage(_ index: Int) {
        guard !isTornDown, pages.indices.contains(index), index != currentIndex else { return }
        currentIndex = index
        errorMessage = nil
        publishState()
        loadCurrentPage()
    }

    /// Starts the only in-flight page request. The existing image stays in
    /// state until the requested page succeeds or reports a real failure.
    private func loadCurrentPage() {
        guard !isTornDown else { return }
        loadGeneration += 1
        let requestedGeneration = loadGeneration
        loadingTask?.cancel()
        errorMessage = nil
        publishState()

        let index = currentIndex
        let loader = loader
        loadingTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let loaded = try await loader.load(pageAt: index)
                try Task.checkCancellation()
                await self?.applyLoadedPage(loaded, index: index, generation: requestedGeneration)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                await self?.applyFailure(error, index: index, generation: requestedGeneration)
            }
        }
    }

    private func applyLoadedPage(
        _ loaded: ReaderLoadedImage,
        index: Int,
        generation: Int
    ) {
        guard !isTornDown, generation == loadGeneration else { return }
        loadingTask = nil
        currentImage = loaded.image
        errorMessage = nil
        logger.debug(
            "paged show index=\(index) size=\(loaded.size.width)x\(loaded.size.height)"
        )
        publishState()
    }

    private func applyFailure(_ error: Error, index: Int, generation: Int) {
        guard !isTornDown, generation == loadGeneration else { return }
        loadingTask = nil
        currentImage = nil
        errorMessage = "加载失败"
        logger.error("Page \(index) load failed: \(error.localizedDescription)", privacy: .private)
        publishState()
    }

    private func publishState() {
        guard !isTornDown else { return }
        onStateChange?(state)
    }
}
