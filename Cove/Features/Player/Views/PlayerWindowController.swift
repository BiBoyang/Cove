import AppKit
import SnapKit
import SourceKit

/// The v1 player window: the mpv render layer fills the window and a
/// always-visible bottom control bar carries play/pause, a draggable
/// progress slider, the time readout, and volume. Keyboard controls from
/// the spike stay (space = pause, arrows = ±10s, Esc = close).
///
/// This controller only renders `PlayerViewModel` state and forwards input;
/// playback state lives in the view model, the mpv handle in the core.
@MainActor
final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    private let core: MPVPlayerCore
    private let viewModel: PlayerViewModel
    /// Fired exactly once when the window closes; the coordinator uses it
    /// to drop its owning reference.
    var onClose: (() -> Void)?

    private let playPauseButton = NSButton()
    private let progressSlider = NSSlider()
    private let timeLabel = NSTextField(labelWithString: "")
    private let volumeSlider = NSSlider()

    init(item: ContentItem, core: MPVPlayerCore, viewModel: PlayerViewModel) {
        self.core = core
        self.viewModel = viewModel
        let window = PlayerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 584),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = item.name
        window.center()
        super.init(window: window)
        window.delegate = self
        window.onKeyDown = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }
        assembleContent(videoLayer: core.videoLayer)
        viewModel.onChange = { [weak self] in self?.render() }
        render()
        core.load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - View assembly

    private func assembleContent(videoLayer: CALayer) {
        guard let window else { return }
        let container = NSView()
        window.contentView = container

        let videoHost = VideoLayerHostView(videoLayer: videoLayer)
        container.addSubview(videoHost)

        let controlsBar = NSVisualEffectView()
        controlsBar.material = .underWindowBackground
        controlsBar.blendingMode = .withinWindow
        controlsBar.state = .active
        container.addSubview(controlsBar)

        configureButton(
            playPauseButton, symbol: "pause.fill",
            accessibilityDescription: "播放/暂停",
            action: #selector(handlePlayPause(_:))
        )
        progressSlider.isContinuous = true
        progressSlider.minValue = 0
        progressSlider.maxValue = 1
        progressSlider.target = self
        progressSlider.action = #selector(handleProgressSlider(_:))

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        volumeSlider.minValue = 0
        volumeSlider.maxValue = 100
        volumeSlider.doubleValue = viewModel.volume
        volumeSlider.target = self
        volumeSlider.action = #selector(handleVolumeSlider(_:))

        controlsBar.addSubview(playPauseButton)
        controlsBar.addSubview(progressSlider)
        controlsBar.addSubview(timeLabel)
        controlsBar.addSubview(volumeSlider)

        videoHost.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        controlsBar.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
            make.height.equalTo(44)
        }
        playPauseButton.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(12)
            make.centerY.equalToSuperview()
            make.size.equalTo(28)
        }
        progressSlider.snp.makeConstraints { make in
            make.leading.equalTo(playPauseButton.snp.trailing).offset(8)
            make.centerY.equalToSuperview()
        }
        timeLabel.snp.makeConstraints { make in
            make.leading.equalTo(progressSlider.snp.trailing).offset(8)
            make.centerY.equalToSuperview()
        }
        volumeSlider.snp.makeConstraints { make in
            make.leading.equalTo(timeLabel.snp.trailing).offset(8)
            make.trailing.equalToSuperview().offset(-12)
            make.centerY.equalToSuperview()
            make.width.equalTo(80)
        }
    }

    private func configureButton(
        _ button: NSButton, symbol: String,
        accessibilityDescription: String, action: Selector
    ) {
        button.isBordered = false
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: accessibilityDescription
        )
        button.imageScaling = .scaleProportionallyUpOrDown
        button.target = self
        button.action = action
    }

    // MARK: - Rendering

    private func render() {
        let symbol = viewModel.showsPauseButton ? "pause.fill" : "play.fill"
        playPauseButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "播放/暂停")
        progressSlider.isEnabled = viewModel.isProgressEnabled
        progressSlider.maxValue = max(viewModel.duration, 1)
        if !viewModel.isScrubbing {
            progressSlider.doubleValue = viewModel.currentTime
        }
        timeLabel.stringValue = viewModel.statusText ?? viewModel.timeText
    }

    // MARK: - Input

    @objc private func handlePlayPause(_ sender: NSButton) {
        viewModel.togglePause()
    }

    /// NSSlider sends its action on mouse-down, drag steps, and mouse-up;
    /// the current event type distinguishes them so a drag suppresses
    /// time-pos feedback until the user lets go.
    @objc private func handleProgressSlider(_ sender: NSSlider) {
        switch NSApp.currentEvent?.type {
        case .leftMouseDown:
            viewModel.beginScrubbing()
            viewModel.scrubTo(sender.doubleValue)
        case .leftMouseDragged:
            viewModel.scrubTo(sender.doubleValue)
        case .leftMouseUp:
            viewModel.scrubTo(sender.doubleValue)
            viewModel.endScrubbing()
        default:
            break
        }
    }

    @objc private func handleVolumeSlider(_ sender: NSSlider) {
        viewModel.setVolume(sender.doubleValue)
    }

    /// Returns true when the key was consumed.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 49: // space
            viewModel.togglePause()
            return true
        case 124: // right arrow
            viewModel.seekBy(seconds: 10)
            return true
        case 123: // left arrow
            viewModel.seekBy(seconds: -10)
            return true
        case 53: // esc
            window?.close()
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        core.shutdown()
        onClose?()
        onClose = nil
    }
}

/// NSWindow subclass that routes unhandled key events to the controller
/// (the window is key and its content view is not an NSTextView, so plain
/// keyDown forwarding is enough for the player controls).
private final class PlayerWindow: NSWindow {
    var onKeyDown: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) != true {
            super.keyDown(with: event)
        }
    }
}

/// Layer-hosting view for the mpv render layer: keeps the layer fitted to
/// the view bounds and in sync with the backing scale factor so mpv
/// renders at native resolution.
private final class VideoLayerHostView: NSView {
    private let videoLayer: CALayer

    init(videoLayer: CALayer) {
        self.videoLayer = videoLayer
        super.init(frame: .zero)
        // Assigning the layer first turns this into a layer-hosting view.
        layer = videoLayer
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        videoLayer.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    private func updateContentsScale() {
        videoLayer.contentsScale = window?.backingScaleFactor ?? 2
    }
}
