import AppKit
import QuartzCore
import SnapKit

/// AppKit continuous vertical strip reader surface: pages stacked at full
/// viewport width inside an NSScrollView, virtualized ±3 screens by the
/// layout model. The view only renders what `ContinuousReaderViewModel`
/// computes — slot frames, create/destroy, anchored relayouts — and
/// forwards scroll/resize input.
///
/// Frames, not constraints, position the document and slot views: the
/// anchored relayout needs exact, transaction-free control that Auto
/// Layout constraints cannot express. Constraint-based chrome (scroll view,
/// progress label) still uses SnapKit per AGENTS.md §11.
@MainActor
final class ContinuousReaderView: NSView {
    private let viewModel: ContinuousReaderViewModel
    private let scrollView = StripScrollView()
    private let documentView = StripDocumentView()
    /// Bottom-center scrubber pill: drag the slider to preview a page
    /// number, release to jump. Replaces the passive progress label.
    private let scrubberPill = NSVisualEffectView()
    private let scrubberSlider = NSSlider()
    private let progressLabel = NSTextField(labelWithString: "")
    /// Center flash showing the zoom factor ("150%") on every zoom change;
    /// fades out shortly after. No zoom UI persists otherwise.
    private let zoomLabel = NSTextField(labelWithString: "")
    private var zoomHideGeneration = 0
    private var slotViews: [Int: StripSlotView] = [:]
    private var didApplyInitialOffset = false
    /// True while the scrubber knob is held; state updates then preview
    /// instead of yanking the slider under the user's thumb.
    private var isScrubbing = false

    /// Auto-scroll (自动滚屏): a pure view-layer, fixed-speed downward
    /// drive. Created lazily on play and invalidated on every stop or
    /// teardown path — the link (which retains its target) must never
    /// outlive this view or keep firing while paused.
    private var isAutoScrolling = false
    private var autoScrollDisplayLink: CADisplayLink?
    /// Timestamp of the previous display-link beat; nil until the first
    /// beat after a start records its baseline (no movement on beat one).
    private var autoScrollLastTick: CFTimeInterval?
    /// Play/pause toggle at the scrubber pill's leading edge.
    private let autoScrollButton = NSButton()
    /// Fixed drive speed in pt/s (ratified: single speed, ~10 s per screen).
    private static let autoScrollSpeed: CGFloat = 110
    /// Frame-delta ceiling: after an occlusion/hidden pause the display
    /// link reports one huge dt, which would teleport the strip instead
    /// of gliding.
    private static let autoScrollMaxFrameInterval: CFTimeInterval = 0.1

    init(viewModel: ContinuousReaderViewModel) {
        self.viewModel = viewModel
        super.init(frame: .zero)
        assemble()
        bindViewModel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // Isolated deinit: the display-link cleanup needs main-actor access to
    // the (non-Sendable) link — normally every stop/teardown path already
    // invalidated it (a live link retains its target, so it would also
    // leak this view), this is the last-resort net. Isolation keeps that
    // access legal under strict concurrency.
    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        autoScrollDisplayLink?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Leaving a window (mode switch back to paged, coordinator teardown)
        // must kill the drive — the link may never outlive the view.
        if window == nil {
            stopAutoScroll()
        }
    }

    override func layout() {
        super.layout()
        let size = scrollView.contentView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        viewModel.updateViewport(width: size.width, height: size.height)
        if !didApplyInitialOffset {
            didApplyInitialOffset = true
            relayout(to: viewModel.startContentOffset)
        }
    }

    // MARK: - Assembly

    private func assemble() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        // Overlay style: a position affordance for long comics that never
        // narrows the document width (scroller visibility would change it).
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = documentView
        // Any user wheel/trackpad gesture on the strip yields the
        // auto-scroll (see StripScrollView for why this hook only fires
        // for user gestures).
        scrollView.onUserScroll = { [weak self] in
            self?.stopAutoScroll()
        }

        // Play/pause toggle inside the scrubber pill: a bare white SF
        // Symbol that reads as part of the HUD capsule chrome.
        autoScrollButton.isBordered = false
        autoScrollButton.focusRingType = .none
        autoScrollButton.refusesFirstResponder = true
        autoScrollButton.contentTintColor = .white
        autoScrollButton.imageScaling = .scaleProportionallyUpOrDown
        autoScrollButton.target = self
        autoScrollButton.action = #selector(toggleAutoScroll)
        setAutoScrollSymbol(paused: true)

        progressLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        progressLabel.textColor = .white

        // The scrubber pill speaks the player's HUD-capsule language.
        scrubberPill.material = .hudWindow
        scrubberPill.blendingMode = .withinWindow
        scrubberPill.state = .active
        scrubberPill.wantsLayer = true
        scrubberPill.layer?.cornerRadius = CoveStyle.radiusLarge
        scrubberPill.layer?.masksToBounds = true

        scrubberSlider.controlSize = .small
        scrubberSlider.minValue = 1
        scrubberSlider.isContinuous = true
        scrubberSlider.target = self
        scrubberSlider.action = #selector(handleScrub(_:))

        scrubberPill.addSubview(autoScrollButton)
        scrubberPill.addSubview(scrubberSlider)
        scrubberPill.addSubview(progressLabel)
        // The zoom flash reads over bright pages thanks to the shadow.
        zoomLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        zoomLabel.textColor = NSColor.white.withAlphaComponent(0.9)
        zoomLabel.alphaValue = 0
        let zoomShadow = NSShadow()
        zoomShadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        zoomShadow.shadowBlurRadius = 3
        zoomShadow.shadowOffset = NSSize(width: 0, height: -1)
        zoomLabel.shadow = zoomShadow
        addSubview(scrollView)
        addSubview(scrubberPill)
        addSubview(zoomLabel)
        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        scrubberPill.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalToSuperview().offset(-16)
            make.height.equalTo(32)
        }
        autoScrollButton.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(8)
            make.centerY.equalToSuperview()
            make.size.equalTo(24)
        }
        scrubberSlider.snp.makeConstraints { make in
            make.leading.equalTo(autoScrollButton.snp.trailing).offset(6)
            make.centerY.equalToSuperview()
            make.width.equalTo(220)
        }
        progressLabel.snp.makeConstraints { make in
            make.leading.equalTo(scrubberSlider.snp.trailing).offset(10)
            make.trailing.equalToSuperview().offset(-14)
            make.centerY.equalToSuperview()
        }
        zoomLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        // Closing the reader window does not remove the view from the
        // window's hierarchy, so viewDidMoveToWindow alone would leave a
        // firing (and self-retaining) link behind.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(readerWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    private func bindViewModel() {
        viewModel.onSlotsChanged = { [weak self] events in
            self?.applySlotEvents(events)
        }
        viewModel.onSlotImage = { [weak self] index, image in
            self?.slotViews[index]?.show(image: image, forPage: index)
        }
        viewModel.onRelayout = { [weak self] newOffset in
            self?.relayout(to: newOffset)
        }
        viewModel.onZoomChange = { [weak self] scale in
            // Horizontal scrolling only exists while zoomed in; at 100% the
            // strip is exactly viewport-wide and the scroller would be a
            // dead affordance.
            self?.scrollView.hasHorizontalScroller = scale > 1
            self?.flashZoomLabel(scale)
        }
        viewModel.onStateChange = { [weak self] state in
            guard let self else { return }
            scrubberSlider.maxValue = Double(max(state.pageCount, 1))
            scrubberSlider.isEnabled = state.pageCount > 1
            if !isScrubbing {
                scrubberSlider.doubleValue = Double(state.currentPage + 1)
                progressLabel.stringValue = state.progressText
            }
            window?.title = state.pageTitle
        }
        viewModel.onScrollTo = { [weak self] offset in
            self?.scroll(to: offset)
        }
    }

    /// Slider beats: mouseDown/drag only previews the page number, the jump
    /// commits on mouseUp so a slow drag never fires a load storm. Keyboard
    /// steps (no mouse events) commit immediately. Any scrubber interaction
    /// is manual positioning and yields the auto-scroll (chosen behavior;
    /// see the review notes).
    @objc private func handleScrub(_ sender: NSSlider) {
        stopAutoScroll()
        let page = Int(sender.doubleValue.rounded())
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseDragged:
            isScrubbing = true
            progressLabel.stringValue = "\(page)/\(Int(sender.maxValue))"
        default:
            isScrubbing = false
            viewModel.scrollToPage(page - 1)
        }
    }

    // MARK: - Slot and layout application

    private func applySlotEvents(_ events: (create: [Int], destroy: [Int])) {
        for index in events.destroy {
            slotViews[index]?.removeFromSuperview()
            slotViews[index] = nil
        }
        for index in events.create where slotViews[index] == nil {
            let slot = StripSlotView(pageIndex: index)
            slot.frame = frame(forPage: index)
            documentView.addSubview(slot)
            slotViews[index] = slot
        }
    }

    /// Applies a batch reflow: new document height, resident slot frames,
    /// then the anchor-preserving content offset from the view model. The
    /// document width is the effective (zoomed) width, not the viewport's.
    private func relayout(to newOffset: CGFloat) {
        let width = viewModel.contentWidth
        documentView.frame = NSRect(x: 0, y: 0, width: width, height: viewModel.contentHeight)
        for (index, slot) in slotViews {
            slot.frame = frame(forPage: index)
        }
        if abs(scrollView.contentView.bounds.origin.y - newOffset) > 0.5 {
            scroll(to: newOffset)
        }
        // Heights moved the residency window; report the settled offset.
        viewModel.updateScrollOffset(scrollView.contentView.bounds.origin.y)
    }

    private func frame(forPage index: Int) -> NSRect {
        NSRect(
            x: 0,
            y: viewModel.yOffset(forPage: index),
            width: viewModel.contentWidth,
            height: viewModel.height(forPage: index)
        )
    }

    // MARK: - Zoom forwarding (keyboard arrives via the window controller)

    // Zooming triggers an anchored relayout; letting the drive continue
    // afterwards would fight the new offset, so every zoom entry point
    // yields first.
    func zoomIn() { stopAutoScroll(); viewModel.zoomIn() }
    func zoomOut() { stopAutoScroll(); viewModel.zoomOut() }
    func zoomReset() { stopAutoScroll(); viewModel.resetZoom() }

    // MARK: - Auto-scroll (自动滚屏)

    /// Play/pause toggle (scrubber button and Space key).
    @objc private func toggleAutoScroll() {
        if isAutoScrolling {
            stopAutoScroll()
        } else {
            startAutoScroll()
        }
    }

    /// Play at (or within a hair of) the document bottom is a no-op: the
    /// strip stays paused instead of jumping the position back to the top
    /// — losing the reading spot to an accidental tap reads worse than a
    /// momentarily dead tap (chosen behavior; see the review notes).
    private func startAutoScroll() {
        let maxOffset = max(0, viewModel.contentHeight - scrollView.contentView.bounds.height)
        guard window != nil, scrollView.contentView.bounds.origin.y < maxOffset - 0.5 else { return }
        isAutoScrolling = true
        autoScrollLastTick = nil
        autoScrollDisplayLink?.invalidate()
        let link = displayLink(target: self, selector: #selector(autoScrollTick(_:)))
        // The factory does NOT schedule the link — without an explicit
        // add(to:forMode:) it never fires (verified by probe). .common keeps
        // the beats flowing while menus/event tracking hold the default mode.
        link.add(to: .main, forMode: .common)
        autoScrollDisplayLink = link
        setAutoScrollSymbol(paused: false)
    }

    /// Stops the drive, resets the toggle icon, and always drops the
    /// display link (also when called while already paused, e.g. from
    /// teardown paths) so no callback can fire while idle.
    private func stopAutoScroll() {
        autoScrollDisplayLink?.invalidate()
        autoScrollDisplayLink = nil
        autoScrollLastTick = nil
        guard isAutoScrolling else { return }
        isAutoScrolling = false
        setAutoScrollSymbol(paused: true)
    }

    /// One display-link beat: advance the offset by 110 pt/s × dt through
    /// the existing clamping `scroll(to:)` (slot sync, page reporting, and
    /// warm window all ride its bounds-change notification chain), then
    /// stop on reaching the document bottom.
    @objc private func autoScrollTick(_ link: CADisplayLink) {
        guard isAutoScrolling else { return }
        let timestamp = link.targetTimestamp
        defer { autoScrollLastTick = timestamp }
        // First beat after a start only records the timing baseline.
        guard let last = autoScrollLastTick else { return }
        let dt = min(max(timestamp - last, 0), Self.autoScrollMaxFrameInterval)
        guard dt > 0 else { return }
        scroll(to: scrollView.contentView.bounds.origin.y + Self.autoScrollSpeed * CGFloat(dt))
        let maxOffset = max(0, viewModel.contentHeight - scrollView.contentView.bounds.height)
        if scrollView.contentView.bounds.origin.y >= maxOffset {
            stopAutoScroll()
        }
    }

    private func setAutoScrollSymbol(paused: Bool) {
        autoScrollButton.image = NSImage(
            systemSymbolName: paused ? "play.fill" : "pause.fill",
            accessibilityDescription: "自动滚屏"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        )
    }

    /// Briefly flashes the zoom factor at the window center, then fades it
    /// out; rapid repeated zooms retrigger instead of stacking fades.
    private func flashZoomLabel(_ scale: CGFloat) {
        zoomLabel.stringValue = "\(Int((scale * 100).rounded()))%"
        zoomHideGeneration += 1
        let generation = zoomHideGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            zoomLabel.animator().alphaValue = 1
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, self.zoomHideGeneration == generation else { return }
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0.3
            self.zoomLabel.animator().alphaValue = 0
            NSAnimationContext.endGrouping()
        }
    }

    private func scroll(to y: CGFloat) {
        let maxOffset = max(0, viewModel.contentHeight - scrollView.contentView.bounds.height)
        let clamped = max(0, min(y, maxOffset))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: clamped))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func clipBoundsDidChange(_ notification: Notification) {
        viewModel.updateScrollOffset(scrollView.contentView.bounds.origin.y)
    }

    @objc private func readerWindowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        stopAutoScroll()
    }

    // MARK: - Keyboard

    /// Handles scroll keys while strip mode owns the window. Returns true
    /// when the key was consumed. Space toggles the auto-scroll; the
    /// scroll keys first yield a running auto-scroll (manual scroll beats
    /// the drive). Left/right are consumed as no-ops — paging keys have no
    /// meaning in the strip.
    func handleKey(_ event: NSEvent) -> Bool {
        let offset = scrollView.contentView.bounds.origin.y
        switch event.keyCode {
        case 49: if !event.isARepeat { toggleAutoScroll() } // Space (hold-to-repeat must not flicker)
        case 126: stopAutoScroll(); scroll(to: offset - 80) // ↑
        case 125: stopAutoScroll(); scroll(to: offset + 80) // ↓
        case 116: stopAutoScroll(); scroll(to: offset - scrollView.contentView.bounds.height) // PageUp
        case 121: stopAutoScroll(); scroll(to: offset + scrollView.contentView.bounds.height) // PageDown
        case 123, 124: break // ←/→
        default: return false
        }
        return true
    }
}

/// Flipped so y=0 is the document top, matching the layout model's
/// coordinates (a slot's frame y equals the model's yOffset).
@MainActor
private final class StripDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// The strip's scroll view. `scrollWheel` is the one funnel through which
/// every user wheel/trackpad gesture passes — the view's own programmatic
/// scrolling via `contentView.scroll(to:)` (auto-scroll beats, key
/// scrolling, relayouts) never does — so the hook cleanly separates "the
/// user touched the strip" from the view driving itself, without flags.
@MainActor
private final class StripScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onUserScroll?()
        super.scrollWheel(with: event)
    }
}

/// One page slot. The page index is pinned at creation and never changes;
/// an image is applied only when its arriving index matches the pin (hard
/// rule: async results must never land on a re-purposed view). The
/// placeholder is a near-black fill with the page number.
@MainActor
private final class StripSlotView: NSView {
    let pageIndex: Int
    private let imageView = NSImageView()
    private let numberLabel = NSTextField(labelWithString: "")

    init(pageIndex: Int) {
        self.pageIndex = pageIndex
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor

        numberLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        numberLabel.textColor = NSColor.white.withAlphaComponent(0.35)
        numberLabel.alignment = .center
        numberLabel.stringValue = "\(pageIndex + 1)"

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        // Same solver insurance as the paged reader: the image's pixel-size
        // intrinsic claims must never beat the slot's edge constraints.
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        addSubview(imageView)
        addSubview(numberLabel)
        imageView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        numberLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(image: CGImage, forPage index: Int) {
        guard index == pageIndex else { return }
        imageView.image = NSImage(cgImage: image, size: .zero)
        numberLabel.isHidden = true
    }
}
