import AppKit
import SnapKit
import SourceKit

/// The v1 player window: the mpv render layer fills the whole window
/// (title bar hidden, full-size content), a floating frosted capsule
/// carries play/pause, a draggable progress slider, the time readout, and
/// volume, and the file name sits as a small overlay label in the top-left
/// corner. During playback the capsule, title, and cursor hide after a
/// short idle timeout and come back on any mouse movement. Keyboard
/// controls: space = pause, arrows = ±10s, up/down = volume, Esc = close.
///
/// This controller only renders `PlayerViewModel` state and forwards input;
/// playback state and the idle-hide policy live in the view model, the mpv
/// handle in the core.
@MainActor
final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    private let core: MPVPlayerCore
    private let viewModel: PlayerViewModel
    /// Fired exactly once when the window closes; the coordinator uses it
    /// to drop its owning reference.
    var onClose: (() -> Void)?

    private let rootView = PlayerRootView()
    private let playPauseButton = NSButton()
    private let progressSlider = NSSlider()
    private let timeLabel = NSTextField(labelWithString: "")
    private let volumeIconView = NSImageView()
    private let volumeSlider = NSSlider()
    private let titleLabel = NSTextField(labelWithString: "")
    private let controlsCapsule = ControlsCapsuleView()
    private var renderedControlsVisible = true

    init(item: ContentItem, core: MPVPlayerCore, viewModel: PlayerViewModel) {
        self.core = core
        self.viewModel = viewModel
        let window = PlayerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 584),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = item.name
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.center()
        super.init(window: window)
        window.delegate = self
        window.onKeyDown = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }
        assembleContent(videoLayer: core.videoLayer, title: item.name)
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

    private func assembleContent(videoLayer: CALayer, title: String) {
        guard let window else { return }
        window.contentView = rootView
        rootView.onMouseActivity = { [weak self] in
            self?.viewModel.noteMouseActivity()
        }

        let videoHost = VideoLayerHostView(videoLayer: videoLayer)
        rootView.addSubview(videoHost)

        // Overlay file name: small white text with a shadow so it stays
        // readable on bright frames; leading offset clears the traffic
        // lights.
        let titleShadow = NSShadow()
        titleShadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        titleShadow.shadowBlurRadius = 3
        titleShadow.shadowOffset = NSSize(width: 0, height: -1)
        titleLabel.attributedStringValue = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.8),
                .shadow: titleShadow,
            ]
        )
        rootView.addSubview(titleLabel)

        // The capsule carries the shadow on its own (unclipped) layer; the
        // material view inside clips to the corner radius.
        controlsCapsule.onHoverChanged = { [weak self] over in
            self?.viewModel.setPointerOverControls(over)
        }
        let capsuleMaterial = NSVisualEffectView()
        capsuleMaterial.material = .hudWindow
        capsuleMaterial.blendingMode = .withinWindow
        capsuleMaterial.state = .active
        capsuleMaterial.wantsLayer = true
        capsuleMaterial.layer?.cornerRadius = CoveStyle.radiusLarge
        capsuleMaterial.layer?.masksToBounds = true
        controlsCapsule.addSubview(capsuleMaterial)
        rootView.addSubview(controlsCapsule)

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
        timeLabel.textColor = NSColor.white.withAlphaComponent(0.8)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        volumeIconView.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "音量")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        volumeIconView.contentTintColor = NSColor.white.withAlphaComponent(0.8)

        volumeSlider.minValue = 0
        volumeSlider.maxValue = 100
        volumeSlider.doubleValue = viewModel.volume
        volumeSlider.target = self
        volumeSlider.action = #selector(handleVolumeSlider(_:))

        capsuleMaterial.addSubview(playPauseButton)
        capsuleMaterial.addSubview(progressSlider)
        capsuleMaterial.addSubview(timeLabel)
        capsuleMaterial.addSubview(volumeIconView)
        capsuleMaterial.addSubview(volumeSlider)

        videoHost.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        titleLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(72)
            make.top.equalToSuperview().offset(10)
        }
        controlsCapsule.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.bottom.equalToSuperview().offset(-16)
            make.height.equalTo(48)
        }
        capsuleMaterial.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        playPauseButton.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(16)
            make.centerY.equalToSuperview()
            make.size.equalTo(28)
        }
        progressSlider.snp.makeConstraints { make in
            make.leading.equalTo(playPauseButton.snp.trailing).offset(10)
            make.centerY.equalToSuperview()
        }
        timeLabel.snp.makeConstraints { make in
            make.leading.equalTo(progressSlider.snp.trailing).offset(10)
            make.centerY.equalToSuperview()
        }
        volumeIconView.snp.makeConstraints { make in
            make.leading.equalTo(timeLabel.snp.trailing).offset(10)
            make.centerY.equalToSuperview()
            make.size.equalTo(16)
        }
        volumeSlider.snp.makeConstraints { make in
            make.leading.equalTo(volumeIconView.snp.trailing).offset(6)
            make.trailing.equalToSuperview().offset(-16)
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
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        button.contentTintColor = .white
        button.imageScaling = .scaleProportionallyUpOrDown
        button.target = self
        button.action = action
    }

    // MARK: - Rendering

    private func render() {
        let symbol = viewModel.showsPauseButton ? "pause.fill" : "play.fill"
        playPauseButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "播放/暂停")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        progressSlider.isEnabled = viewModel.isProgressEnabled
        progressSlider.maxValue = max(viewModel.duration, 1)
        if !viewModel.isScrubbing {
            progressSlider.doubleValue = viewModel.currentTime
        }
        timeLabel.stringValue = viewModel.statusText ?? viewModel.timeText
        renderControlsVisibility()
    }

    /// Fades the capsule and overlay title in/out and hides the cursor
    /// alongside them. Hit-testing on the capsule is cut while hidden so
    /// the invisible controls cannot catch clicks.
    private func renderControlsVisibility() {
        let visible = viewModel.controlsVisible
        guard visible != renderedControlsVisible else { return }
        renderedControlsVisible = visible
        controlsCapsule.isInteractable = visible
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            controlsCapsule.animator().alphaValue = visible ? 1 : 0
            titleLabel.animator().alphaValue = visible ? 1 : 0
        }
        if !visible {
            hideCursorIfInsideWindow()
        }
    }

    /// `setHiddenUntilMouseMoves` restores the cursor on the next movement
    /// by itself, so it cannot unbalance; only hide when the pointer is
    /// actually over this window (it stays put when the user is mousing
    /// somewhere else, e.g. a second monitor).
    private func hideCursorIfInsideWindow() {
        guard let window, let contentView = window.contentView else { return }
        let location = contentView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if contentView.bounds.contains(location) {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
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
        case 126: // up arrow
            viewModel.adjustVolume(by: 5)
            return true
        case 125: // down arrow
            viewModel.adjustVolume(by: -5)
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

/// The window's content view. Forwards every pointer movement over the
/// window to the view model so it can restart the idle countdown — the
/// tracking area is what makes AppKit deliver mouse-moved events at all
/// (movement over subviews bubbles up the responder chain).
private final class PlayerRootView: NSView {
    var onMouseActivity: (() -> Void)?
    private var trackingAreaRef: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseActivity?()
    }
}

/// The floating control capsule. Carries the drop shadow on its own
/// unclipped layer (the material view inside clips itself to the corner
/// radius, which would cut a shadow off) and reports pointer hover so the
/// view model keeps the controls up while the pointer rests on them.
private final class ControlsCapsuleView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    /// While false the capsule ignores clicks entirely (controls hidden).
    var isInteractable = true

    private var trackingAreaRef: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        self.shadow = shadow
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: CoveStyle.radiusLarge,
            cornerHeight: CoveStyle.radiusLarge,
            transform: nil
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isInteractable ? super.hitTest(point) : nil
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
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
