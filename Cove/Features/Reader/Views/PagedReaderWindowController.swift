import AppKit
import SnapKit

/// AppKit single-page manual-paging reader (route A1): shows exactly one page at
/// a time over a near-black background, centered and fit to the window
/// (SenPlayer-style). Navigation is manual only — previous/next buttons,
/// arrow/Page keys; there is no continuous scrolling, no slot topology,
/// no retention, and no prefetch.
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
    private let imageView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let previousButton = FrostedCircleButton(
        symbolName: "chevron.left", pointSize: 16, accessibilityDescription: "上一张"
    )
    private let nextButton = FrostedCircleButton(
        symbolName: "chevron.right", pointSize: 16, accessibilityDescription: "下一张"
    )
    private let exitButton = FrostedCircleButton(
        symbolName: "xmark", pointSize: 12, accessibilityDescription: "退出阅读器"
    )
    private let modeButton = FrostedCircleButton(
        symbolName: "scroll", pointSize: 13, accessibilityDescription: "切换到条带模式"
    )
    private let progressLabel = NSTextField(labelWithString: "")

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
        window.backgroundColor = .black
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
        rootView.layer?.backgroundColor = NSColor.black.cgColor

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        // The ≤-superview size caps must beat the image's intrinsic point
        // size: `NSImage(cgImage:size:.zero)` claims pixel dims as points,
        // which exceeds any window, and with the default compression
        // resistance the caps can lose — the view then renders at image
        // size and the window crops it (seen on landscape monitors).
        // Lowering the resistance lets the solver always shrink the view.
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        statusLabel.alignment = .center
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = true

        previousButton.target = self
        previousButton.action = #selector(handlePrevious(_:))
        nextButton.target = self
        nextButton.action = #selector(handleNext(_:))
        exitButton.target = self
        exitButton.action = #selector(handleExit(_:))
        modeButton.target = self
        modeButton.action = #selector(handleModeSwitch(_:))

        progressLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        progressLabel.textColor = .white

        rootView.addSubview(imageView)
        rootView.addSubview(statusLabel)
        rootView.addSubview(previousButton)
        rootView.addSubview(nextButton)
        rootView.addSubview(exitButton)
        rootView.addSubview(modeButton)
        rootView.addSubview(progressLabel)

        // Centered, aspect-preserving, never larger than the window. The
        // constraints — not code — keep the image placed through full-screen
        // and resize transitions; no relayout handler is needed.
        imageView.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.width.lessThanOrEqualToSuperview()
            make.height.lessThanOrEqualToSuperview()
        }
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
        exitButton.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(16)
            make.top.equalToSuperview().offset(16)
            make.size.equalTo(32)
        }
        modeButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-16)
            make.top.equalToSuperview().offset(16)
            make.size.equalTo(32)
        }
        progressLabel.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalToSuperview().offset(-16)
        }

        rootView.onKeyDown = { [weak self] event in
            self?.handleKey(event) ?? false
        }
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
        previousButton.isEnabled = state.canGoPrevious
        nextButton.isEnabled = state.canGoNext
        window?.title = state.pageTitle
        imageView.image = state.image.map { NSImage(cgImage: $0, size: .zero) }
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

    @objc private func handleExit(_ sender: NSButton) {
        close()
    }

    @objc private func handleModeSwitch(_ sender: NSButton) {
        onModeSwitch?()
        window?.makeFirstResponder(rootView)
    }

    // MARK: - Mode switching

    /// Swaps the single-page chrome for the strip surface. The paged view
    /// model stays alive (just hidden), so switching back is instant.
    func showStrip(_ view: ContinuousReaderView) {
        stripView?.removeFromSuperview()
        stripView = view
        mode = .strip
        // Below the whole chrome: the exit/mode buttons must stay on top.
        rootView.addSubview(view, positioned: .below, relativeTo: imageView)
        view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
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
        progressLabel.isHidden = !visible
    }

    // MARK: - Keyboard

    /// Returns true when the key was consumed. Works in full screen because
    /// the root view is the window's first responder. In strip mode scroll
    /// keys go to the strip view; Esc steps out of full screen and is
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

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) != true {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
    }
}
