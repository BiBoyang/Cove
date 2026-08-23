import AppKit
import SnapKit

/// AppKit single-page manual-paging reader (route A1): shows exactly one page at
/// a time over a near-black background, centered and fit to the window
/// (SenPlayer-style). Navigation is manual only — previous/next buttons,
/// arrow/Page keys; there is no continuous scrolling, no slot topology,
/// no retention, and no prefetch.
///
/// Paging, loading, cancellation, and stale-result rejection belong to the
/// injected `ReaderViewModel`; this controller only renders AppKit state and
/// forwards user input.
@MainActor
final class PagedReaderWindowController: NSWindowController {
    private let viewModel: ReaderViewModel
    private var isTornDown = false
    private var didRequestFullScreen = false

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
    private let progressLabel = NSTextField(labelWithString: "")

    init(viewModel: ReaderViewModel) {
        self.viewModel = viewModel
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
        viewModel.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard let window else { return }
        window.makeFirstResponder(rootView)
        if !didRequestFullScreen, !window.styleMask.contains(.fullScreen) {
            didRequestFullScreen = true
            window.toggleFullScreen(nil)
        }
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

        progressLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        progressLabel.textColor = .white

        rootView.addSubview(imageView)
        rootView.addSubview(statusLabel)
        rootView.addSubview(previousButton)
        rootView.addSubview(nextButton)
        rootView.addSubview(exitButton)
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

    // MARK: - Keyboard

    /// Returns true when the key was consumed. Works in full screen because
    /// the root view is the window's first responder.
    private func handleKey(_ event: NSEvent) -> Bool {
        // Leave menu commands (Cmd+W, Cmd+Q, …) to the responder chain.
        guard !event.modifierFlags.contains(.command) else { return false }
        switch event.keyCode {
        case 123, 116: // ←, PageUp
            viewModel.goPrevious()
        case 124, 121: // →, PageDown
            viewModel.goNext()
        case 53: // Esc
            close()
        default:
            return false
        }
        return true
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
