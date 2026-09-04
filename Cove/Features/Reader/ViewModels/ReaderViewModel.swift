import CoreGraphics
import Foundation
import ReaderKit
import TraceKit

/// Main-actor state for one single-page Reader session.
///
/// The ViewModel owns paging, cancellation, stale-result rejection, the
/// auto-advance slideshow, and the state rendered by AppKit. Cache reads
/// and image decoding remain inside the Sendable loader and run in a
/// detached user-initiated task.
@MainActor
final class ReaderViewModel: NSObject {
    struct State: Sendable {
        let pageTitle: String
        let progressText: String
        let canGoPrevious: Bool
        let canGoNext: Bool
        let image: CGImage?
        let errorMessage: String?
        let isAutoAdvancing: Bool
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

    /// Screensaver-style auto page turning (自动翻页): a fixed-interval
    /// timer owned here — UI session state and task lifetime belong to the
    /// VM (AGENTS.md §12). Any manual paging intent takes over and stops
    /// it; reaching the last page stops it instead of wrapping.
    static let autoAdvanceInterval: TimeInterval = 5
    /// Retains this view model while scheduled (target/selector); every
    /// stop/teardown path must invalidate it.
    private var autoAdvanceTimer: Timer?
    private(set) var isAutoAdvancing = false

    var onStateChange: ((State) -> Void)? {
        didSet { publishState() }
    }

    /// Fired after the current page index lands. The view model does not
    /// know what listens — the reader's adjacent-page prefetch hangs off
    /// this seam in the coordinator.
    var onPageChanged: ((Int) -> Void)?

    /// The currently displayed page index; the strip-mode handoff reads it
    /// so switching modes preserves the page.
    var currentPageIndex: Int { currentIndex }

    var state: State {
        State(
            pageTitle: pages[currentIndex].title,
            progressText: "\(currentIndex + 1)/\(pages.count)",
            canGoPrevious: currentIndex > 0,
            canGoNext: currentIndex < pages.count - 1,
            image: currentImage,
            errorMessage: errorMessage,
            isAutoAdvancing: isAutoAdvancing
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
        super.init()
    }

    func start() {
        guard !hasStarted, !isTornDown else { return }
        hasStarted = true
        loadCurrentPage()
    }

    func goPrevious() {
        // A manual page intent takes over: stop the slideshow first. A
        // whole-page jump would otherwise keep yanking away the page the
        // user is reading — deliberately unlike the strip auto-scroll's
        // "a reposition never interrupts" semantics.
        stopAutoAdvance()
        goToPage(currentIndex - 1)
    }

    func goNext() {
        stopAutoAdvance()
        goToPage(currentIndex + 1)
    }

    /// Jumps straight to a page (strip-mode handoff). Same clamping and
    /// no-op-if-current semantics as a manual page turn.
    func jumpToPage(_ index: Int) {
        stopAutoAdvance()
        goToPage(index)
    }

    /// Play/pause toggle for the auto-advance slideshow (Space and the HUD
    /// button). Pressing play at the last page is a deliberate no-op — the
    /// same "a dead tap beats losing the reading spot" call as the strip's
    /// auto-scroll at the document bottom.
    func toggleAutoAdvance() {
        if isAutoAdvancing {
            stopAutoAdvance()
        } else {
            startAutoAdvance()
        }
    }

    /// Stops the slideshow and publishes the released state. All manual
    /// paging, the mode switch, and teardown funnel through here.
    func stopAutoAdvance() {
        autoAdvanceTimer?.invalidate()
        autoAdvanceTimer = nil
        guard isAutoAdvancing else { return }
        isAutoAdvancing = false
        publishState()
    }

    /// One slideshow beat, called by the timer and directly by tests (no
    /// real-time waits): turn the page through the regular paging path so
    /// prefetch/loading/state publication ride along unchanged. Landing on
    /// the last page stops the show on the spot (the HUD flips back to
    /// play immediately, no dead one-beat linger); a beat that finds the
    /// show already stopped there is inert.
    func autoAdvanceTick() {
        guard isAutoAdvancing, !isTornDown else { return }
        guard currentIndex < pages.count - 1 else {
            stopAutoAdvance()
            return
        }
        goToPage(currentIndex + 1)
        if currentIndex == pages.count - 1 {
            stopAutoAdvance()
        }
    }

    private func startAutoAdvance() {
        guard !isTornDown, currentIndex < pages.count - 1 else { return }
        isAutoAdvancing = true
        publishState()
        autoAdvanceTimer?.invalidate()
        // Target/selector rather than a block: the block API is @Sendable
        // and would fight the view model's MainActor isolation (same call
        // as PlayerCoordinator's up-next timer).
        autoAdvanceTimer = Timer.scheduledTimer(
            timeInterval: Self.autoAdvanceInterval,
            target: self,
            selector: #selector(autoAdvanceTimerFired),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func autoAdvanceTimerFired() {
        autoAdvanceTick()
    }

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        // The timer retains this view model while scheduled; it must never
        // outlive the session.
        autoAdvanceTimer?.invalidate()
        autoAdvanceTimer = nil
        isAutoAdvancing = false
        loadGeneration += 1
        loadingTask?.cancel()
        loadingTask = nil
        onStateChange = nil
        onPageChanged = nil
    }

    private func goToPage(_ index: Int) {
        guard !isTornDown, pages.indices.contains(index), index != currentIndex else { return }
        currentIndex = index
        errorMessage = nil
        publishState()
        onPageChanged?(index)
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
