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
    private let settings: SettingsService
    private let scrollView = NSScrollView()
    private let documentView = StripDocumentView()
    /// Bottom-center scrubber pill: drag the slider to preview a page
    /// number, release to jump. Opaque warm-black board (surfaceOverlay)
    /// so the chrome stays readable over bright pages.
    private let scrubberPill = NSView()
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

    /// Auto-scroll (自动滚屏): a pure view-layer downward drive at the
    /// selected speed gear. Created lazily on play and invalidated on every
    /// stop or teardown path — the link (which retains its target) must
    /// never outlive this view or keep firing while paused.
    private var isAutoScrolling = false
    private var autoScrollDisplayLink: CADisplayLink?
    /// Timestamp of the previous display-link beat; nil until the first
    /// beat after a start records its baseline (no movement on beat one).
    private var autoScrollLastTick: CFTimeInterval?
    /// Play/pause toggle at the scrubber pill's leading edge; a right
    /// click cycles the speed gear.
    private let autoScrollButton = AutoScrollButton()
    /// Small gear readout ("1x") pinned to the button's trailing edge.
    private let speedLabel = NSTextField(labelWithString: "")
    /// Base drive speed in pt/s (~10 s per screen at 1x); the gears below
    /// are multipliers of it.
    private static let baseAutoScrollSpeed: CGFloat = 110
    /// Speed gears cycled by right-clicking the play/pause button, in the
    /// macOS player speed-button language: left toggles, right steps.
    private static let speedGears: [Double] = [0.5, 1.0, 2.0]
    /// Current gear, restored from settings at init and persisted on every
    /// cycle. A running drive picks a gear change up on its next beat.
    private var speedGearIndex: Int
    private var autoScrollSpeed: CGFloat {
        Self.baseAutoScrollSpeed * Self.speedGears[speedGearIndex]
    }
    /// Frame-delta ceiling: after an occlusion/hidden pause the display
    /// link reports one huge dt, which would teleport the strip instead
    /// of gliding.
    private static let autoScrollMaxFrameInterval: CFTimeInterval = 0.1

    init(viewModel: ContinuousReaderViewModel, settings: SettingsService) {
        self.viewModel = viewModel
        self.settings = settings
        // Snap a stored factor to the nearest gear; the setting is a plain
        // Double, so values written by other builds still land on a gear.
        let factor = settings.stripAutoScrollSpeedFactor
        speedGearIndex = Self.speedGears.indices.min(by: {
            abs(Self.speedGears[$0] - factor) < abs(Self.speedGears[$1] - factor)
        }) ?? Self.speedGears.firstIndex(of: 1.0)!
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
        layer?.backgroundColor = CoveStyle.readerBackground.cgColor

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        // Overlay style: a position affordance for long comics that never
        // narrows the document width (scroller visibility would change it).
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = documentView

        // Play/pause toggle inside the scrubber pill: a bare white SF
        // Symbol that reads as part of the HUD capsule chrome.
        autoScrollButton.isBordered = false
        autoScrollButton.focusRingType = .none
        autoScrollButton.refusesFirstResponder = true
        autoScrollButton.contentTintColor = .white
        autoScrollButton.imageScaling = .scaleProportionallyUpOrDown
        autoScrollButton.target = self
        autoScrollButton.action = #selector(toggleAutoScroll)
        autoScrollButton.onRightClick = { [weak self] in
            self?.cycleSpeedGear()
        }
        setAutoScrollSymbol(paused: true)

        speedLabel.font = CoveStyle.monoDigitFont
        speedLabel.textColor = CoveStyle.textOnMedia2
        updateSpeedLabel()

        progressLabel.font = CoveStyle.monoDigitFont
        progressLabel.textColor = CoveStyle.textOnMedia1

        // The scrubber pill speaks the shared chrome-pill language: an
        // opaque surfaceOverlay board (see the token's comment for why it
        // must not be a translucent material).
        scrubberPill.wantsLayer = true
        scrubberPill.layer?.backgroundColor = CoveStyle.surfaceOverlay.cgColor
        scrubberPill.layer?.cornerRadius = CoveStyle.radiusLarge
        scrubberPill.layer?.masksToBounds = true

        scrubberSlider.controlSize = .small
        scrubberSlider.minValue = 1
        scrubberSlider.isContinuous = true
        scrubberSlider.target = self
        scrubberSlider.action = #selector(handleScrub(_:))

        scrubberPill.addSubview(autoScrollButton)
        scrubberPill.addSubview(speedLabel)
        scrubberPill.addSubview(scrubberSlider)
        scrubberPill.addSubview(progressLabel)
        // The zoom flash reads over bright pages thanks to the shadow.
        zoomLabel.font = CoveStyle.overlayFlashFont
        zoomLabel.textColor = CoveStyle.textOnMedia1
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
        speedLabel.snp.makeConstraints { make in
            make.leading.equalTo(autoScrollButton.snp.trailing).offset(2)
            make.centerY.equalToSuperview()
        }
        scrubberSlider.snp.makeConstraints { make in
            make.leading.equalTo(speedLabel.snp.trailing).offset(6)
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
    /// steps (no mouse events) commit immediately. Scrubbing is a manual
    /// reposition: the auto-scroll (if running) just continues from the new
    /// spot — only zoom, an explicit toggle, the bottom edge, and teardown
    /// stop it.
    @objc private func handleScrub(_ sender: NSSlider) {
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

    /// Right-click on the play/pause button: step to the next gear and
    /// persist it. A running drive applies the new speed on its next beat;
    /// paused, only the readout changes and the next play uses the gear.
    private func cycleSpeedGear() {
        speedGearIndex = (speedGearIndex + 1) % Self.speedGears.count
        settings.stripAutoScrollSpeedFactor = Self.speedGears[speedGearIndex]
        updateSpeedLabel()
    }

    private func updateSpeedLabel() {
        let factor = Self.speedGears[speedGearIndex]
        speedLabel.stringValue = factor.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(factor))x"
            : "\(factor)x"
    }

    /// One display-link beat: advance the offset by the geared speed × dt
    /// through the existing clamping `scroll(to:)` (slot sync, page
    /// reporting, and warm window all ride its bounds-change notification
    /// chain), then stop on reaching the document bottom.
    @objc private func autoScrollTick(_ link: CADisplayLink) {
        guard isAutoScrolling else { return }
        let timestamp = link.targetTimestamp
        defer { autoScrollLastTick = timestamp }
        // First beat after a start only records the timing baseline.
        guard let last = autoScrollLastTick else { return }
        let dt = min(max(timestamp - last, 0), Self.autoScrollMaxFrameInterval)
        guard dt > 0 else { return }
        scroll(to: scrollView.contentView.bounds.origin.y + autoScrollSpeed * CGFloat(dt))
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
            NSImage.SymbolConfiguration(pointSize: CoveStyle.symbolSmall, weight: .semibold)
        )
    }

    /// Briefly flashes the zoom factor at the window center, then fades it
    /// out; rapid repeated zooms retrigger instead of stacking fades.
    private func flashZoomLabel(_ scale: CGFloat) {
        zoomLabel.stringValue = "\(Int((scale * 100).rounded()))%"
        zoomHideGeneration += 1
        let generation = zoomHideGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = CoveStyle.motionFast
            context.timingFunction = CoveStyle.motionTimingFunction
            zoomLabel.animator().alphaValue = 1
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, self.zoomHideGeneration == generation else { return }
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = CoveStyle.motionMedium
            NSAnimationContext.current.timingFunction = CoveStyle.motionTimingFunction
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
    /// when the key was consumed. Space toggles the auto-scroll; scroll keys
    /// are manual repositions and never interrupt a running auto-scroll —
    /// the drive simply continues from the new spot. Left/right are consumed
    /// as no-ops — paging keys have no meaning in the strip.
    func handleKey(_ event: NSEvent) -> Bool {
        let offset = scrollView.contentView.bounds.origin.y
        switch event.keyCode {
        case 49: if !event.isARepeat { toggleAutoScroll() } // Space (hold-to-repeat must not flicker)
        case 126: scroll(to: offset - 80) // ↑
        case 125: scroll(to: offset + 80) // ↓
        case 116: scroll(to: offset - scrollView.contentView.bounds.height) // PageUp
        case 121: scroll(to: offset + scrollView.contentView.bounds.height) // PageDown
        case 123, 124: break // ←/→
        default: return false
        }
        return true
    }
}

/// The strip's play/pause button: left click toggles, right click cycles
/// the speed gear (overriding `rightMouseDown` beats a gesture recognizer
/// here — no system-menu conflict, zero extra objects).
@MainActor
private final class AutoScrollButton: NSButton {
    var onRightClick: (() -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}

/// Flipped so y=0 is the document top, matching the layout model's
/// coordinates (a slot's frame y equals the model's yOffset).
@MainActor
private final class StripDocumentView: NSView {
    override var isFlipped: Bool { true }
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
        layer?.backgroundColor = CoveStyle.readerBackground.cgColor

        numberLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        numberLabel.textColor = CoveStyle.textOnMedia3
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
