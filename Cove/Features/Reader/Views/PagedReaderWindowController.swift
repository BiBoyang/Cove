import AppKit
import SnapKit

/// AppKit single-page reader (route A1): shows exactly one page at
/// a time over a near-black background, centered and fit to the window.
/// Navigation is manual (previous/next buttons, arrow/Page keys) plus an
/// opt-in fixed-interval auto-advance slideshow (Space or the page
/// counter's play button); there is no continuous scrolling, no slot
/// topology, no retention, and no prefetch.
///
/// The same window can swap to the continuous strip surface
/// (`ContinuousReaderView`) via the mode button; the paged chrome is then
/// hidden, not torn down, so switching back is instant. Paged-mode behavior
/// is unchanged from A1.
///
/// Paging, loading, cancellation, and stale-result rejection belong to the
/// injected `ReaderViewModel`; this controller only renders AppKit state and
/// forwards user input.
@MainActor
final class PagedReaderWindowController: NSWindowController {
    private let viewModel: ReaderViewModel
    private var isTornDown = false

    private let rootView = PagedReaderRootView()
    private let imageView = NonInteractiveImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let previousButton = FrostedCircleButton(
        symbolName: "chevron.left", pointSize: CoveStyle.symbolMedium, accessibilityDescription: "上一张"
    )
    private let nextButton = FrostedCircleButton(
        symbolName: "chevron.right", pointSize: CoveStyle.symbolMedium, accessibilityDescription: "下一张"
    )
    private let modeButton = FrostedCircleButton(
        symbolName: "scroll", pointSize: CoveStyle.symbolMedium, accessibilityDescription: "切换到条带模式"
    )
    /// Bottom-center chrome pill: page counter + auto-advance toggle on
    /// the same surfaceOverlay board as the strip's scrubber pill — one
    /// chrome language across both reader modes.
    private let pageChromePill = NSView()
    private let progressLabel = NSTextField(labelWithString: "")
    /// Auto-advance (自动翻页) play/pause inside the chrome pill; a bare
    /// white symbol that reads as part of the pill (same treatment as the
    /// strip's auto-scroll button). Shows the pause symbol while the
    /// slideshow runs.
    private let autoAdvanceButton = NSButton()
    // Resume hint: a window-level HUD capsule shown after a
    // resume-from-memory open moved the start off the tapped file. It is a
    // pure rendering surface — the coordinator decides when to show it and
    // what the return button does.
    private let resumeHintPill = ResumeHintPill()
    private let resumeHintLabel = NSTextField(labelWithString: "")
    private let resumeReturnButton = PillButton(title: "返回选中的图", style: .secondary)
    /// Fires once per show; cleared by every dismiss path so a double click
    /// cannot re-trigger the jump.
    private var resumeHintReturnHandler: (() -> Void)?
    /// Pending ~4 s auto-dismiss; cancelled by hide, re-show, and teardown.
    private var resumeHintDismissTask: Task<Void, Never>?

    // MARK: zoom state (session-scoped, never persisted)

    /// Current zoom tier as a multiplier of the window-fit size (1 = fit).
    private var zoomTier: CGFloat = 1
    /// Pan offset of the zoomed image from the centered position, clamped
    /// so a zoomed image always covers the window (no black background).
    private var zoomPanOffset = CGPoint.zero
    /// Point size of the currently displayed page; drives the fit rect.
    private var currentImageSize = CGSize.zero
    /// Underlying CGImage of the last render; identity-compared to detect
    // page changes (the NSImage wrapper is recreated on every render).
    private var lastRenderedImage: CGImage?
    /// Container size the last frame was computed for; a change means a
    /// resize/full-screen transition and resets the zoom to fit.
    private var lastContainerSize = CGSize.zero
    /// True while a pan drag owns the closed-hand cursor.
    private var isPanningWithCursor = false
    private let zoomFlashLabel = NSTextField(labelWithString: "")
    private var zoomFlashGeneration = 0

    /// The active surface. The coordinator owns the switch (it builds the
    /// strip session); this controller only hosts views.
    private(set) var mode: ReaderMode = .paged
    private var stripView: ContinuousReaderView?
    /// User tapped the mode button; the coordinator performs the switch.
    var onModeSwitch: (() -> Void)?

    init(viewModel: ReaderViewModel, initialMode: ReaderMode = .paged) {
        self.viewModel = viewModel
        mode = initialMode
        let screen = NSScreen.main
        let window = NSWindow(
            contentRect: screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = viewModel.state.pageTitle
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = CoveStyle.readerBackground
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]

        super.init(window: window)

        assembleContent()
        registerObservers()
        bindViewModel()
        applyInitialMode()
        // In strip-default sessions the paged model starts lazily on the
        // first switch back, so opening a comic never loads a page the
        // user may never see.
        if mode == .paged {
            viewModel.start()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard let window else { return }
        window.makeFirstResponder(rootView)
    }

    // MARK: - View assembly

    private func assembleContent() {
        guard let window else { return }
        window.contentView = rootView

        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = CoveStyle.readerBackground.cgColor
        // Zoomed (panned) image frames may extend past the view bounds; the
        // layer clips them so the window never composes image pixels over
        // neighboring screens or the title bar.
        rootView.layer?.masksToBounds = true

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        // Layout is frame-driven (see `applyZoomedFrame`): the frame is
        // always computed from the aspect-fit rect in code, so the view can
        // never settle at the image's intrinsic point size — the bug the
        // old low compression-resistance constraints fixed on landscape
        // monitors (`NSImage(cgImage:size:.zero)` claims pixel dims as
        // points). Zoom just scales that fitted rect by the tier.

        statusLabel.alignment = .center
        statusLabel.font = CoveStyle.bodyFont
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = true

        previousButton.target = self
        previousButton.action = #selector(handlePrevious(_:))
        nextButton.target = self
        nextButton.action = #selector(handleNext(_:))
        modeButton.target = self
        modeButton.action = #selector(handleModeSwitch(_:))

        autoAdvanceButton.isBordered = false
        autoAdvanceButton.focusRingType = .none
        autoAdvanceButton.refusesFirstResponder = true
        autoAdvanceButton.contentTintColor = CoveStyle.textOnMedia1
        autoAdvanceButton.imageScaling = .scaleProportionallyUpOrDown
        autoAdvanceButton.target = self
        autoAdvanceButton.action = #selector(handleAutoAdvance(_:))
        setAutoAdvanceSymbol(running: false)

        progressLabel.font = CoveStyle.monoDigitFont
        progressLabel.textColor = CoveStyle.textOnMedia1

        // The chrome pill: same board recipe as the strip's scrubber pill
        // (opaque surfaceOverlay, radius large).
        pageChromePill.wantsLayer = true
        pageChromePill.layer?.backgroundColor = CoveStyle.surfaceOverlay.cgColor
        pageChromePill.layer?.cornerRadius = CoveStyle.radiusLarge
        pageChromePill.layer?.masksToBounds = true

        // The zoom flash reads over bright pages thanks to the shadow
        // (same treatment as the strip's zoom flash).
        zoomFlashLabel.font = CoveStyle.overlayFlashFont
        zoomFlashLabel.textColor = CoveStyle.textOnMedia1
        zoomFlashLabel.alphaValue = 0
        let zoomShadow = NSShadow()
        zoomShadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        zoomShadow.shadowBlurRadius = 3
        zoomShadow.shadowOffset = NSSize(width: 0, height: -1)
        zoomFlashLabel.shadow = zoomShadow

        rootView.addSubview(imageView)
        rootView.addSubview(statusLabel)
        rootView.addSubview(previousButton)
        rootView.addSubview(nextButton)
        rootView.addSubview(modeButton)
        pageChromePill.addSubview(progressLabel)
        pageChromePill.addSubview(autoAdvanceButton)
        rootView.addSubview(pageChromePill)
        rootView.addSubview(zoomFlashLabel)

        // The imageView is deliberately unconstrained: zoom places it with
        // a frame on every layout pass (see `rootView.onLayout`), so resize
        // and full-screen transitions re-fit the page in code instead of via
        // the Auto Layout solver. Everything else stays constraint-based.
        statusLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
        previousButton.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(16)
            make.centerY.equalToSuperview()
            make.size.equalTo(44)
        }
        nextButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-16)
            make.centerY.equalToSuperview()
            make.size.equalTo(44)
        }
        modeButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-16)
            make.top.equalToSuperview().offset(16)
            make.size.equalTo(32)
        }
        pageChromePill.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalToSuperview().offset(-16)
            make.height.equalTo(32)
        }
        progressLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(12)
            make.centerY.equalToSuperview()
        }
        autoAdvanceButton.snp.makeConstraints { make in
            make.leading.equalTo(progressLabel.snp.trailing).offset(6)
            make.trailing.equalToSuperview().offset(-8)
            make.centerY.equalToSuperview()
            make.size.equalTo(24)
        }
        zoomFlashLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }

        rootView.onKeyDown = { [weak self] event in
            self?.handleKey(event) ?? false
        }
        rootView.onLayout = { [weak self] in
            self?.applyZoomedFrameFromLayoutPass()
        }
        rootView.onPanDelta = { [weak self] delta in
            self?.panImage(by: delta)
        }
        rootView.onPanEnd = { [weak self] in
            self?.endPan()
        }

        assembleResumeHint()
    }

    private func registerObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    private func bindViewModel() {
        viewModel.onStateChange = { [weak self] state in
            self?.render(state)
        }
    }

    private func render(_ state: ReaderViewModel.State) {
        progressLabel.stringValue = state.progressText
        setAutoAdvanceSymbol(running: state.isAutoAdvancing)
        previousButton.isEnabled = state.canGoPrevious
        nextButton.isEnabled = state.canGoNext
        window?.title = state.pageTitle
        let newImage = state.image.map { NSImage(cgImage: $0, size: .zero) }
        // A page change is a new CGImage; zoom is session-scoped per page.
        // Compare the underlying CGImage identity, not the NSImage wrapper
        // (a fresh wrapper is created every render, so wrapper comparison
        // would always report a page change).
        let didChangePage = state.image !== lastRenderedImage
        lastRenderedImage = state.image
        imageView.image = newImage
        currentImageSize = state.image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        if didChangePage {
            resetZoom(silent: true)
        } else {
            applyZoomedFrameFromLayoutPass()
        }
        statusLabel.stringValue = state.errorMessage ?? ""
        statusLabel.isHidden = state.errorMessage == nil
    }

    @objc private func handlePrevious(_ sender: NSButton) {
        viewModel.goPrevious()
        window?.makeFirstResponder(rootView)
    }

    @objc private func handleNext(_ sender: NSButton) {
        viewModel.goNext()
        window?.makeFirstResponder(rootView)
    }

    @objc private func handleModeSwitch(_ sender: NSButton) {
        onModeSwitch?()
        window?.makeFirstResponder(rootView)
    }

    @objc private func handleAutoAdvance(_ sender: NSButton) {
        viewModel.toggleAutoAdvance()
        window?.makeFirstResponder(rootView)
    }

    /// Swaps the auto-advance toggle's symbol (pause while the slideshow
    /// runs, play otherwise).
    private func setAutoAdvanceSymbol(running: Bool) {
        autoAdvanceButton.image = NSImage(
            systemSymbolName: running ? "pause.fill" : "play.fill",
            accessibilityDescription: "自动翻页"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: CoveStyle.symbolSmall, weight: .semibold)
        )
    }

    // MARK: - Zoom

    /// Steps the zoom tier up (⌘=). Clamped at the largest tier; the
    /// boundary no-op does nothing (no recenter, no flash).
    private func zoomIn() {
        let next = PagedZoomLayout.stepUp(from: zoomTier)
        guard next != zoomTier else { return }
        setZoomTier(next)
    }

    /// Steps the zoom tier down (⌘−). Clamped at the 100% fit; the boundary
    /// no-op does nothing (no flash).
    private func zoomOut() {
        let next = PagedZoomLayout.stepDown(from: zoomTier)
        guard next != zoomTier else { return }
        setZoomTier(next)
    }

    /// ⌘0: back to the 100% fit. A no-op when already pristine (tier 1,
    /// zero pan) so it does not flash a pointless "100%"; after panning it
    /// still recenters and flashes.
    private func zoomReset() {
        guard zoomTier != 1 || zoomPanOffset != .zero else { return }
        setZoomTier(1)
    }

    private func setZoomTier(_ tier: CGFloat) {
        zoomTier = tier
        // Tier changes recenter; the old pan offset is meaningless at the
        // new size.
        zoomPanOffset = .zero
        flashZoom(tier)
        applyZoomedFrameFromLayoutPass()
    }

    /// Resets to the 100% fit. `silent` skips the flash for implicit resets
    /// (page turn, resize) — only explicit zoom actions flash.
    private func resetZoom(silent: Bool) {
        zoomTier = 1
        zoomPanOffset = .zero
        if !silent {
            flashZoom(1)
        }
        applyZoomedFrameFromLayoutPass()
    }

    /// Single recompute entry point: also invoked from the root view's
    /// layout pass so resize/full-screen transitions re-fit the page — the
    /// frame-driven replacement for what the old constraints did for free.
    private func applyZoomedFrameFromLayoutPass() {
        let containerSize = rootView.bounds.size
        // A container-size change is a resize/full-screen transition: zoom
        // resets to fit (the fit base itself moved).
        if containerSize != lastContainerSize {
            lastContainerSize = containerSize
            zoomTier = 1
            zoomPanOffset = .zero
        }
        imageView.frame = PagedZoomLayout.imageFrame(
            imageSize: currentImageSize,
            containerSize: containerSize,
            tier: zoomTier,
            panOffset: zoomPanOffset
        )
    }

    /// Accumulates a drag delta into the pan offset, clamped so the zoomed
    /// image always covers the window; no-ops at the 100% fit tier.
    private func panImage(by delta: CGSize) {
        guard mode == .paged, zoomTier > 1 else { return }
        if !isPanningWithCursor {
            isPanningWithCursor = true
            NSCursor.closedHand.push()
        }
        let frameSize = PagedZoomLayout.zoomedSize(
            imageSize: currentImageSize,
            containerSize: rootView.bounds.size,
            tier: zoomTier
        )
        zoomPanOffset = PagedZoomLayout.clampedPan(
            CGPoint(x: zoomPanOffset.x + delta.width, y: zoomPanOffset.y + delta.height),
            frameSize: frameSize,
            containerSize: rootView.bounds.size
        )
        applyZoomedFrameFromLayoutPass()
    }

    private func endPan() {
        guard isPanningWithCursor else { return }
        isPanningWithCursor = false
        NSCursor.pop()
    }

    /// Briefly flashes the zoom percent at the window center, then fades it
    /// out; rapid repeated zooms retrigger instead of stacking fades (same
    /// generation-counter pattern as the strip's flash).
    private func flashZoom(_ tier: CGFloat) {
        zoomFlashLabel.stringValue = "\(Int((tier * 100).rounded()))%"
        zoomFlashGeneration += 1
        let generation = zoomFlashGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = CoveStyle.motionFast
            context.timingFunction = CoveStyle.motionTimingFunction
            zoomFlashLabel.animator().alphaValue = 1
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, self.zoomFlashGeneration == generation else { return }
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = CoveStyle.motionMedium
            NSAnimationContext.current.timingFunction = CoveStyle.motionTimingFunction
            self.zoomFlashLabel.animator().alphaValue = 0
            NSAnimationContext.endGrouping()
        }
    }

    // MARK: - Mode switching

    /// Swaps the single-page chrome for the strip surface. The paged view
    /// model stays alive (just hidden), so switching back is instant.
    func showStrip(_ view: ContinuousReaderView) {
        // The slideshow belongs to the paged surface; leaving paged mode
        // stops it so no hidden timer keeps turning pages underneath.
        viewModel.stopAutoAdvance()
        stripView?.removeFromSuperview()
        stripView = view
        mode = .strip
        // Below the whole chrome: the exit/mode buttons must stay on top.
        rootView.addSubview(view, positioned: .below, relativeTo: imageView)
        view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        // Switching modes resets the paged zoom back to the 100% fit.
        zoomTier = 1
        zoomPanOffset = .zero
        setPagedChromeVisible(false)
        modeButton.setSymbol("rectangle.portrait", accessibilityDescription: "切换到单页模式")
        window?.makeFirstResponder(rootView)
    }

    /// Back to single-page mode. The coordinator tears the strip session
    /// down before this call; the strip view is destroyed here.
    func showPaged() {
        stripView?.removeFromSuperview()
        stripView = nil
        mode = .paged
        zoomTier = 1
        zoomPanOffset = .zero
        setPagedChromeVisible(true)
        modeButton.setSymbol("scroll", accessibilityDescription: "切换到条带模式")
        // Idempotent: starts the paged session on the first switch-back of
        // a strip-default (comic) session.
        viewModel.start()
        window?.makeFirstResponder(rootView)
    }

    private func applyInitialMode() {
        guard mode == .strip else { return }
        setPagedChromeVisible(false)
        modeButton.setSymbol("rectangle.portrait", accessibilityDescription: "切换到单页模式")
    }

    private func setPagedChromeVisible(_ visible: Bool) {
        imageView.isHidden = !visible
        statusLabel.isHidden = !visible || viewModel.state.errorMessage == nil
        previousButton.isHidden = !visible
        nextButton.isHidden = !visible
        pageChromePill.isHidden = !visible
    }

    // MARK: - Resume hint

    /// Assembles the resume-hint HUD: a top-center capsule in the reader's
    /// HUD chrome language (same material and radius as the strip's
    /// scrubber pill), always in the hierarchy but fully transparent (and
    /// hit-test-transparent) until shown. Top-center keeps it clear of the
    /// corner buttons and of the strip's bottom scrubber pill.
    private func assembleResumeHint() {
        resumeHintLabel.font = CoveStyle.monoDigitFont
        resumeHintLabel.textColor = CoveStyle.textOnMedia1

        resumeReturnButton.refusesFirstResponder = true
        resumeReturnButton.target = self
        resumeReturnButton.action = #selector(handleResumeReturn(_:))

        // The hint pill speaks the same chrome-pill language as the
        // strip's scrubber pill and the paged chrome pill.
        resumeHintPill.wantsLayer = true
        resumeHintPill.layer?.backgroundColor = CoveStyle.surfaceOverlay.cgColor
        resumeHintPill.layer?.cornerRadius = CoveStyle.radiusLarge
        resumeHintPill.layer?.masksToBounds = true
        resumeHintPill.alphaValue = 0

        resumeHintPill.addSubview(resumeHintLabel)
        resumeHintPill.addSubview(resumeReturnButton)
        rootView.addSubview(resumeHintPill)
        resumeHintPill.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.equalToSuperview().offset(16)
            make.height.equalTo(32)
        }
        resumeHintLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(14)
            make.centerY.equalToSuperview()
        }
        resumeReturnButton.snp.makeConstraints { make in
            make.leading.equalTo(resumeHintLabel.snp.trailing).offset(10)
            make.trailing.equalToSuperview().offset(-10)
            make.centerY.equalToSuperview()
        }
    }

    /// Shows the resume hint with a short fade-in and schedules the ~4 s
    /// auto fade-out; any re-show resets the timer. `page` is the 0-based
    /// restored page index (displayed 1-based, matching the progress label).
    /// Pure rendering: the click is forwarded via `onReturn`, which fires at
    /// most once per show.
    func showResumeHint(page: Int, onReturn: @escaping () -> Void) {
        resumeHintLabel.stringValue = "已回到第 \(page + 1) 页"
        resumeHintReturnHandler = onReturn
        resumeHintDismissTask?.cancel()
        setResumeHintVisible(true)
        resumeHintDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled else { return }
            self.hideResumeHint()
        }
    }

    /// Dismisses the resume hint early (page turn, scroll, window close).
    /// Idempotent, and always cancels the pending auto-dismiss.
    func hideResumeHint() {
        resumeHintDismissTask?.cancel()
        resumeHintDismissTask = nil
        resumeHintReturnHandler = nil
        guard resumeHintPill.alphaValue > 0.01 else { return }
        setResumeHintVisible(false)
    }

    private func setResumeHintVisible(_ visible: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = CoveStyle.motionMedium
            context.timingFunction = CoveStyle.motionTimingFunction
            resumeHintPill.animator().alphaValue = visible ? 1 : 0
        }
    }

    @objc private func handleResumeReturn(_ sender: NSButton) {
        // Take the handler before hiding: hiding clears it, so the jump
        // fires exactly once even on a double click.
        let handler = resumeHintReturnHandler
        hideResumeHint()
        handler?()
    }

    // MARK: - Keyboard

    /// Returns true when the key was consumed. Works in full screen because
    /// the root view is the window's first responder. In strip mode scroll
    /// keys and Space (the auto-scroll toggle, consumed by the strip view
    /// itself) go to the strip view; Esc steps out of full screen and is
    /// otherwise ignored.
    private func handleKey(_ event: NSEvent) -> Bool {
        // Strip zoom shortcuts (⌘=/⌘−/⌘0) are consumed here; every other
        // Cmd combination still falls through to the menu commands.
        if mode == .strip, event.modifierFlags.contains(.command) {
            switch event.keyCode {
            case 24: stripView?.zoomIn(); return true // ⌘=
            case 27: stripView?.zoomOut(); return true // ⌘−
            case 29: stripView?.zoomReset(); return true // ⌘0
            default: return false
            }
        }
        // Paged zoom shortcuts (⌘=/⌘−/⌘0) are consumed here; every other
        // Cmd combination still falls through to the menu commands. This
        // block must sit BEFORE the Cmd fall-through guard below, or these
        // keys would be handed to the menu where they do not exist.
        if mode == .paged, event.modifierFlags.contains(.command) {
            switch event.keyCode {
            case 24: zoomIn(); return true // ⌘=
            case 27: zoomOut(); return true // ⌘−
            case 29: zoomReset(); return true // ⌘0
            default: return false
            }
        }
        // Leave menu commands (Cmd+W, Cmd+Q, …) to the responder chain.
        guard !event.modifierFlags.contains(.command) else { return false }
        if mode == .strip {
            if event.keyCode == 53 { // Esc
                handleEscape()
                return true
            }
            return stripView?.handleKey(event) ?? false
        }
        switch event.keyCode {
        case 123, 116: // ←, PageUp
            viewModel.goPrevious()
        case 124, 121: // →, PageDown
            viewModel.goNext()
        case 49: // Space toggles the auto-advance slideshow
            if !event.isARepeat { viewModel.toggleAutoAdvance() }
        case 53: // Esc
            handleEscape()
        default:
            return false
        }
        return true
    }

    /// Esc steps out of full screen; in a windowed session it does nothing
    /// (close via the ✕ button or Cmd+W).
    private func handleEscape() {
        guard let window, window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    // MARK: - Lifecycle

    @objc private func windowWillClose(_ notification: Notification) {
        guard !isTornDown else { return }
        isTornDown = true
        // The auto-dismiss task must never outlive the window.
        hideResumeHint()
        viewModel.tearDown()
        NotificationCenter.default.removeObserver(self)
    }
}

/// The window's content view: first responder so keyboard paging works in
/// full screen. Black background for the single centered page.
@MainActor
private final class PagedReaderRootView: NSView {
    /// Returns true when the key was consumed.
    var onKeyDown: ((NSEvent) -> Bool)?
    /// Runs at the end of every layout pass (resize, full-screen toggle,
    /// zoom setNeedsLayout) so the frame-driven image can re-fit.
    var onLayout: (() -> Void)?
    /// Drag delta in view coordinates; forwarded while a drag is active.
    var onPanDelta: ((CGSize) -> Void)?
    /// The drag ended (mouse up anywhere).
    var onPanEnd: (() -> Void)?

    private var panLocation: NSPoint?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) != true {
            super.keyDown(with: event)
        }
    }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func mouseDown(with event: NSEvent) {
        panLocation = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = panLocation else { return }
        let location = convert(event.locationInWindow, from: nil)
        panLocation = location
        onPanDelta?(CGSize(width: location.x - last.x, height: location.y - last.y))
    }

    override func mouseUp(with event: NSEvent) {
        panLocation = nil
        onPanEnd?()
    }

    override func draw(_ dirtyRect: NSRect) {
        CoveStyle.readerBackground.setFill()
        dirtyRect.fill()
    }
}

/// The page image never accepts hits itself — mouse events must reach the
/// root view so the pan drag (and nothing else) owns them. The floating
/// chrome buttons are separate siblings and still receive their clicks.
@MainActor
private final class NonInteractiveImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Pure geometry for the paged reader's layout-level zoom: aspect-fit rect,
/// tier scaling, and pan clamping. Layout-level (never a rendered
/// magnification) so zooming stays sharp; the image view's frame is simply
/// resized and AppKit/`scaleProportionallyUpOrDown` does the drawing.
enum PagedZoomLayout {
    /// Ratios of the window-fit size; percent is relative to fit, not to
    /// the image's native pixels.
    static let tiers: [CGFloat] = [1, 1.5, 2, 3]

    /// Next tier up, clamped at the largest tier.
    static func stepUp(from tier: CGFloat) -> CGFloat {
        tiers.first { $0 > tier } ?? tiers.last!
    }

    /// Next tier down, clamped at the 100% fit.
    static func stepDown(from tier: CGFloat) -> CGFloat {
        tiers.last { $0 < tier } ?? tiers.first!
    }

    /// Aspect-fit rect of `imageSize` centered in `containerSize` — the
    /// 100% tier. An empty image yields an empty centered rect.
    static func fittedRect(imageSize: CGSize, containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            return CGRect(
                x: (containerSize.width) / 2, y: (containerSize.height) / 2,
                width: 0, height: 0
            )
        }
        let scale = min(
            containerSize.width / imageSize.width,
            containerSize.height / imageSize.height
        )
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (containerSize.width - size.width) / 2,
            y: (containerSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// The image frame size at `tier` (fitted size × tier).
    static func zoomedSize(imageSize: CGSize, containerSize: CGSize, tier: CGFloat) -> CGSize {
        let fitted = fittedRect(imageSize: imageSize, containerSize: containerSize).size
        return CGSize(width: fitted.width * tier, height: fitted.height * tier)
    }

    /// Clamps a pan offset (displacement of the frame center from the
    /// container center) so the frame never lets the container show past an
    /// image edge while zoomed; an axis smaller than the container pins to
    /// the center (offset 0) instead.
    static func clampedPan(_ pan: CGPoint, frameSize: CGSize, containerSize: CGSize) -> CGPoint {
        func clampAxis(_ offset: CGFloat, _ frame: CGFloat, _ container: CGFloat) -> CGFloat {
            let slack = (frame - container) / 2
            guard slack > 0 else { return 0 }
            return min(max(offset, -slack), slack)
        }
        return CGPoint(
            x: clampAxis(pan.x, frameSize.width, containerSize.width),
            y: clampAxis(pan.y, frameSize.height, containerSize.height)
        )
    }

    /// The final image frame: fitted centered rect × tier, displaced by the
    /// clamped pan offset. At tier 1 this is exactly the fitted centered
    /// rect (the clamp zeroes any pan).
    static func imageFrame(
        imageSize: CGSize,
        containerSize: CGSize,
        tier: CGFloat,
        panOffset: CGPoint
    ) -> CGRect {
        let size = zoomedSize(imageSize: imageSize, containerSize: containerSize, tier: tier)
        let pan = clampedPan(panOffset, frameSize: size, containerSize: containerSize)
        return CGRect(
            x: (containerSize.width - size.width) / 2 + pan.x,
            y: (containerSize.height - size.height) / 2 + pan.y,
            width: size.width,
            height: size.height
        )
    }
}

/// The resume-hint capsule: opaque surfaceOverlay board with capsule
/// corners, matching the reader chrome pills. While fully transparent it is
/// also fully hit-test-transparent, so clicks and wheel events pass through
/// to the reader surface beneath; while visible, only the embedded button
/// accepts hits — the capsule body and label never block the page.
@MainActor
private final class ResumeHintPill: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard alphaValue > 0.01 else { return nil }
        let hit = super.hitTest(point)
        return hit is NSButton ? hit : nil
    }
}
