import AppKit
import PDFKit
import SnapKit

/// AppKit PDF reader window: one `PDFView` in continuous single-page mode
/// over a black background, windowed with a hidden title bar and Esc
/// stepping out of full screen — same look and feel as the image and video
/// readers.
///
/// The loading state machine, cancellation, and failure reporting belong to
/// the injected `PdfReaderViewModel`; this controller only renders AppKit
/// state and forwards user input.
@MainActor
final class PdfReaderWindowController: NSWindowController {
    private let viewModel: PdfReaderViewModel
    private var isTornDown = false

    private let rootView = PdfReaderRootView()
    private let pdfView = PDFView()
    private let statusLabel = NSTextField(labelWithString: "")

    /// True while the document bytes are still on the way; the coordinator
    /// uses this to treat the open as pending (navigation cancels it).
    var isLoading: Bool { viewModel.isLoading }

    init(viewModel: PdfReaderViewModel) {
        self.viewModel = viewModel
        let screen = NSScreen.main
        let window = NSWindow(
            contentRect: screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = viewModel.title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]

        super.init(window: window)

        assembleContent()
        registerObservers()
        bindViewModel()
        render(viewModel.state)
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
    }

    // MARK: - View assembly

    private func assembleContent() {
        guard let window else { return }
        window.contentView = rootView

        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.black.cgColor

        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = true
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .black
        pdfView.isHidden = true

        statusLabel.alignment = .center
        statusLabel.font = CoveStyle.bodyFont
        statusLabel.textColor = .secondaryLabelColor


        rootView.addSubview(pdfView)
        rootView.addSubview(statusLabel)

        pdfView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        statusLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
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

    private func render(_ state: PdfReaderViewModel.State) {
        switch state {
        case .loading:
            statusLabel.stringValue = "加载中…"
            statusLabel.isHidden = false
            pdfView.isHidden = true
        case .ready(let document):
            pdfView.document = document
            pdfView.isHidden = false
            statusLabel.isHidden = true
        case .failed(let message):
            statusLabel.stringValue = message
            statusLabel.isHidden = false
            pdfView.isHidden = true
        }
    }

    // MARK: - Keyboard

    /// Returns true when the key was consumed. Works in full screen because
    /// the root view is the window's first responder; PDF navigation itself
    /// is pointer-driven (scroll wheel / trackpad).
    private func handleKey(_ event: NSEvent) -> Bool {
        // Leave menu commands (Cmd+W, Cmd+Q, …) to the responder chain.
        guard !event.modifierFlags.contains(.command) else { return false }
        if event.keyCode == 53 { // Esc
            handleEscape()
            return true
        }
        return false
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

/// The window's content view: first responder so Esc works in full screen.
/// Black background behind the `PDFView` and the status label.
@MainActor
private final class PdfReaderRootView: NSView {
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
