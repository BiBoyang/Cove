import CoreGraphics
import Foundation
import ReaderKit
import TraceKit

/// Main-actor state for one continuous-strip Reader session.
///
/// Owns the slot lifecycle and loading tasks; the layout math lives in the
/// pure `StripLayoutModel`. The two post-mortem invariants are enforced
/// here: a slot is created for exactly one page index and destroyed (never
/// reused) when it leaves the window, and every async result is validated
/// against the slot's pinned index and generation before it lands. Slot
/// destruction cancels the task and drops the decoded image — the on-disk
/// display pool covers revisits.
@MainActor
final class ContinuousReaderViewModel {
    struct State: Sendable {
        let pageTitle: String
        let progressText: String
        /// Zero-based page at the viewport top, and the total page count;
        /// the scrubber renders/follows these.
        let currentPage: Int
        let pageCount: Int
    }

    private let pages: [ReaderPage]
    private let loader: any ReaderPageLoading
    private let logger: TraceLogger

    private var layout: StripLayoutModel?
    private var viewportWidth: CGFloat = 0
    private var viewportHeight: CGFloat = 0
    private var contentOffset: CGFloat = 0
    /// Discrete layout-zoom levels: pages lay out at viewport width × scale
    /// (a zoomed-in strip scrolls horizontally). Session-only, resets on open.
    static let zoomScales: [CGFloat] = [1, 1.25, 1.5, 2]
    private var zoomIndex = 0
    private(set) var zoomScale: CGFloat = 1
    /// First visible page at the latest scroll report; doubles as the
    /// reflow anchor.
    private(set) var currentPage: Int
    private var activeWindow: Range<Int>?
    private var warmWindow: [Int] = []
    private var isTornDown = false

    /// A resident slot. `pageIndex` is pinned at creation and never
    /// changes; `generation` invalidates in-flight loads on re-create.
    private struct SlotState {
        let pageIndex: Int
        var generation: Int
    }

    private var slots: [Int: SlotState] = [:]
    private var loadTasks: [Int: Task<Void, Never>] = [:]
    private var pendingMeasurements: [Int: CGFloat] = [:]
    private var relayoutScheduled = false

    var onStateChange: ((State) -> Void)? {
        didSet { publishState() }
    }

    /// Fired when the first visible page changes; the strip never wires
    /// this to prefetch — the warm window seam below supersedes it here.
    var onPageChanged: ((Int) -> Void)?

    /// Pages intersecting one viewport height below the visible bottom;
    /// re-emitted only when the set changes.
    var onWarmWindow: (([Int]) -> Void)?

    /// Slot create/destroy for the view. A destroyed index is gone for
    /// good; a later re-create is a brand-new slot with a fresh generation.
    var onSlotsChanged: (((create: [Int], destroy: [Int])) -> Void)?

    /// A slot's decoded image; the view re-validates the pinned index.
    var onSlotImage: ((Int, CGImage) -> Void)?

    /// Document height changed; the view re-lays out resident slots and
    /// applies the given anchor-preserving content offset.
    var onRelayout: ((CGFloat) -> Void)?

    /// Zoom factor changed; the view toggles its horizontal scroller.
    var onZoomChange: ((CGFloat) -> Void)?

    /// Jump request: scroll so the document position lands at the viewport
    /// top (the scrubber commits through `scrollToPage`).
    var onScrollTo: ((CGFloat) -> Void)?

    var state: State {
        State(
            pageTitle: pages[currentPage].title,
            progressText: "\(currentPage + 1)/\(pages.count)",
            currentPage: currentPage,
            pageCount: pages.count
        )
    }

    init(
        pages: [ReaderPage],
        startIndex: Int,
        loader: any ReaderPageLoading,
        logger: TraceLogger
    ) {
        precondition(!pages.isEmpty, "ContinuousReaderViewModel requires at least one page")
        self.pages = pages
        currentPage = min(max(startIndex, 0), pages.count - 1)
        self.loader = loader
        self.logger = logger
    }

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        for task in loadTasks.values { task.cancel() }
        loadTasks.removeAll()
        slots.removeAll()
        pendingMeasurements.removeAll()
        onStateChange = nil
        onPageChanged = nil
        onWarmWindow = nil
        onSlotsChanged = nil
        onSlotImage = nil
        onRelayout = nil
        onZoomChange = nil
        onScrollTo = nil
    }

    // MARK: - Layout reads for the view

    var contentHeight: CGFloat { layout?.contentHeight ?? 0 }

    /// Laid-out page strip width: the viewport width under the current zoom.
    /// The view sizes its document and slot frames with it (wider than the
    /// viewport while zoomed in, which is what engages horizontal scrolling).
    var contentWidth: CGFloat { viewportWidth * zoomScale }

    func yOffset(forPage index: Int) -> CGFloat { layout?.yOffset(forPage: index) ?? 0 }

    func height(forPage index: Int) -> CGFloat { layout?.height(forPage: index) ?? 0 }

    /// Document position of the start page under the all-estimated layout;
    /// the view applies it once after the first viewport report.
    var startContentOffset: CGFloat {
        layout.map { $0.yOffset(forPage: currentPage) } ?? 0
    }

    // MARK: - View input

    /// The view reports its visible size. Creates the layout model on first
    /// call; a width change rebases all heights under the viewport anchor
    /// (window resize, fullscreen transitions). The model always works in
    /// effective width (viewport × zoom), so a resize keeps the zoom level.
    func updateViewport(width: CGFloat, height: CGFloat) {
        guard !isTornDown, width > 0, height > 0 else { return }
        viewportWidth = width
        viewportHeight = height
        let effectiveWidth = width * zoomScale
        guard var model = layout else {
            let created = StripLayoutModel(pageCount: pages.count, viewportWidth: effectiveWidth)
            layout = created
            // Adopt the start page's offset as the initial scroll position;
            // otherwise the first sync would snap a mid-document session
            // (startIndex) back to page 0.
            contentOffset = created.yOffset(forPage: currentPage)
            syncWindow()
            publishWarmWindow()
            return
        }
        guard abs(effectiveWidth - model.viewportWidth) > 0.5 else {
            // A height-only change can still move the residency window.
            syncWindow()
            publishWarmWindow()
            return
        }
        let anchor = anchorForReflow(using: model)
        let newOffset = model.updateViewportWidth(
            effectiveWidth, anchorPage: anchor.page, offsetWithinAnchorPage: anchor.offsetWithin
        )
        layout = model
        contentOffset = newOffset
        onRelayout?(newOffset)
        syncWindow()
        publishWarmWindow()
    }

    // MARK: - Zoom

    /// Steps the layout zoom in/out; `resetZoom` returns to fit-width.
    /// The rebase reuses the viewport-width anchoring rule, so the page at
    /// the top edge stays visually stationary across a zoom change.
    func zoomIn() { stepZoom(by: 1) }
    func zoomOut() { stepZoom(by: -1) }
    func resetZoom() { applyZoom(index: 0) }

    private func stepZoom(by delta: Int) { applyZoom(index: zoomIndex + delta) }

    private func applyZoom(index: Int) {
        let clamped = min(max(index, 0), Self.zoomScales.count - 1)
        guard clamped != zoomIndex, !isTornDown else { return }
        zoomIndex = clamped
        zoomScale = Self.zoomScales[clamped]
        onZoomChange?(zoomScale)
        // Before the first viewport report there is no layout to rebase;
        // the recorded index applies at creation time instead.
        guard var model = layout else { return }
        let anchor = anchorForReflow(using: model)
        let newOffset = model.updateViewportWidth(
            viewportWidth * zoomScale, anchorPage: anchor.page, offsetWithinAnchorPage: anchor.offsetWithin
        )
        layout = model
        contentOffset = newOffset
        onRelayout?(newOffset)
        syncWindow()
        publishWarmWindow()
    }

    /// The view reports scroll position changes (also after every relayout,
    /// since new heights may have shifted the residency window).
    func updateScrollOffset(_ offset: CGFloat) {
        guard !isTornDown, layout != nil else { return }
        contentOffset = offset
        syncWindow()
        publishWarmWindow()
    }

    /// Jumps the strip so `index`'s top edge lands at the viewport top
    /// (out-of-range indices clamp to the queue ends). The scrubber commits
    /// here; the usual window sync and current-page publish follow inline,
    /// so the jump works even without a view observing the scroll request.
    func scrollToPage(_ index: Int) {
        guard !isTornDown, let model = layout else { return }
        let clamped = min(max(index, 0), pages.count - 1)
        let target = model.yOffset(forPage: clamped)
        contentOffset = target
        onScrollTo?(target)
        syncWindow()
        publishWarmWindow()
    }

    // MARK: - Slots and loading

    private func syncWindow() {
        guard let model = layout else { return }
        let next = model.activeRange(contentOffset: contentOffset, viewportHeight: viewportHeight)
        let previous = activeWindow
        activeWindow = next
        let events = previous.map { StripLayoutModel.windowEvents(from: $0, to: next) }
            ?? (create: Array(next), destroy: [])
        guard !events.create.isEmpty || !events.destroy.isEmpty else {
            publishCurrentPage(using: model)
            return
        }
        destroySlots(events.destroy)
        createSlots(events.create)
        onSlotsChanged?(events)
        publishCurrentPage(using: model)
    }

    private func createSlots(_ indices: [Int]) {
        for index in indices where slots[index] == nil {
            slots[index] = SlotState(pageIndex: index, generation: 0)
            startLoad(index)
        }
    }

    private func destroySlots(_ indices: [Int]) {
        for index in indices {
            loadTasks[index]?.cancel()
            loadTasks[index] = nil
            slots[index] = nil
            pendingMeasurements[index] = nil
        }
    }

    /// Starts the one in-flight request for a slot. The slot keeps its
    /// placeholder until the image lands; a destroy cancels the task.
    private func startLoad(_ index: Int) {
        guard let slot = slots[index] else { return }
        let generation = slot.generation + 1
        slots[index]?.generation = generation
        let loader = loader
        loadTasks[index] = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let loaded = try await loader.load(pageAt: index)
                try Task.checkCancellation()
                await self?.applyLoaded(loaded, index: index, generation: generation)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                await self?.applyLoadFailure(error, index: index, generation: generation)
            }
        }
    }

    private func applyLoaded(_ loaded: ReaderLoadedImage, index: Int, generation: Int) {
        // Hard rule: never land a result on a slot that was destroyed or
        // re-created while the request was in flight.
        guard !isTornDown,
              let slot = slots[index],
              slot.pageIndex == index,
              slot.generation == generation else { return }
        loadTasks[index] = nil
        logger.debug(
            "strip show index=\(index) size=\(loaded.size.width)x\(loaded.size.height)"
        )
        onSlotImage?(index, loaded.image)
        let aspect = loaded.size.height / loaded.size.width
        guard aspect > 0 else { return }
        pendingMeasurements[index] = aspect
        scheduleRelayout()
    }

    private func applyLoadFailure(_ error: Error, index: Int, generation: Int) {
        guard !isTornDown, slots[index]?.generation == generation else { return }
        loadTasks[index] = nil
        // The placeholder stays; scrolling out and back retries the load.
        logger.error("Strip page \(index) load failed: \(error.localizedDescription)", privacy: .private)
    }

    // MARK: - Anchored reflow

    /// Coalesces all measurements arriving in one runloop turn into a
    /// single anchored reflow — no per-image layout churn.
    private func scheduleRelayout() {
        guard !relayoutScheduled else { return }
        relayoutScheduled = true
        Task { [weak self] in
            self?.flushMeasurements()
        }
    }

    private func flushMeasurements() {
        relayoutScheduled = false
        guard !isTornDown, var model = layout, !pendingMeasurements.isEmpty else { return }
        let anchor = anchorForReflow(using: model)
        let updates = pendingMeasurements
        pendingMeasurements.removeAll()
        let newOffset = model.applyMeasurements(
            updates, anchorPage: anchor.page, offsetWithinAnchorPage: anchor.offsetWithin
        )
        layout = model
        contentOffset = newOffset
        onRelayout?(newOffset)
        syncWindow()
        publishWarmWindow()
    }

    private func anchorForReflow(using model: StripLayoutModel) -> (page: Int, offsetWithin: CGFloat) {
        (page: currentPage, offsetWithin: contentOffset - model.yOffset(forPage: currentPage))
    }

    // MARK: - Current page and warm window

    private func publishCurrentPage(using model: StripLayoutModel) {
        let first = model.firstVisiblePage(atY: contentOffset)
        guard first != currentPage else { return }
        currentPage = first
        publishState()
        onPageChanged?(first)
    }

    /// Pages intersecting one viewport height below the visible bottom.
    private func publishWarmWindow() {
        guard let model = layout, viewportHeight > 0 else { return }
        let bottom = contentOffset + viewportHeight
        let first = model.firstVisiblePage(atY: bottom)
        let last = model.firstVisiblePage(atY: bottom + viewportHeight)
        let indices = last > first ? Array((first + 1) ... last) : []
        guard indices != warmWindow else { return }
        warmWindow = indices
        onWarmWindow?(indices)
    }

    private func publishState() {
        guard !isTornDown else { return }
        onStateChange?(state)
    }
}
