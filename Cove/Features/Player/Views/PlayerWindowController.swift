import AppKit
import SnapKit
import SourceKit

/// The player window: the mpv render layer fills
/// the whole window under a transparent title bar, with the file name as a
/// centered overlay title at the top (long names truncate from the middle
/// so they stay centered). A floating frosted capsule at the bottom
/// carries, in order: previous / play-pause / next, the playback-rate
/// button ("1x", popover with speeds), volume icon + slider + live number,
/// the draggable progress slider, the time readout, and the playlist
/// button (popover listing the queue; tap a row to jump to it). The play
/// mode (single / repeat-one / list / list-loop / shuffle) is a capsule
/// button showing the current mode symbol with a popover picker.
///
/// During playback the capsule and cursor hide after a short idle timeout
/// and come back on any mouse movement; the centered title stays put.
/// Keyboard controls: space = pause, arrows = ±10s, up/down = volume,
/// Esc = exit full screen. While the up-next countdown overlay is shown,
/// Esc = cancel it and Return = play now, taking priority over the keys
/// above (press Esc again afterwards to exit full screen).
///
/// The overlay itself only renders and forwards callbacks; the countdown
/// lifecycle (timer, firing into a track change, every cancel path) lives
/// in the coordinator, as do the playlist and play-mode decisions. Track
/// changes swap the session in place (`install`): the window, its
/// full-screen state, and its position survive; only the mpv core, the
/// view model, and the video layer are replaced.
///
/// This controller only renders `PlayerViewModel` state and forwards
/// input; playback state and the idle-hide policy live in the view model,
/// the mpv handle in the core.
@MainActor
final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    private var core: MPVPlayerCore
    private var viewModel: PlayerViewModel
    /// Fired exactly once when the window closes; the coordinator uses it
    /// to drop its owning reference.
    var onClose: (() -> Void)?
    /// Playlist transport intents, wired by the coordinator.
    var onPreviousTrack: (() -> Void)?
    var onNextTrack: (() -> Void)?
    /// Playlist panel / popovers, wired by the coordinator.
    var onSelectTrack: ((_ path: String) -> Void)?
    var onPlayModeSelected: ((_ mode: PlayMode) -> Void)?
    var onSpeedSelected: ((_ speed: Double) -> Void)?
    /// Up-next overlay intents, wired by the coordinator.
    var onUpNextPlayNow: (() -> Void)?
    var onUpNextCancel: (() -> Void)?

    private let rootView = PlayerRootView()
    private let previousTrackButton = NSButton()
    private let playPauseButton = NSButton()
    private let nextTrackButton = NSButton()
    private let speedButton = NSButton()
    private let progressSlider = NSSlider()
    private let timeLabel = NSTextField(labelWithString: "")
    private let volumeIconView = NSImageView()
    private let volumeSlider = NSSlider()
    /// Live volume readout ("65") next to the slider; updates on drags and
    /// arrow-key nudges alike.
    private let volumeValueLabel = NSTextField(labelWithString: "")
    private let playModeButton = NSButton()
    private let playlistButton = NSButton()
    private let centerTitleLabel = NSTextField(labelWithString: "")
    private let controlsCapsule = ControlsCapsuleView()
    private let upNextOverlay = UpNextOverlayView()
    /// Top-left codec chips (HW / codec / resolution / bitrate): small
    /// surfaceOverlay tiles that ride the controls' visibility lifecycle —
    /// the frame stays clean while the capsule is hidden.
    private let codecChipsRow = NSStackView()
    private var videoHost: VideoLayerHostView?
    private var renderedControlsVisible = true
    /// Chips content guard: `render()` fires every second on time ticks,
    /// so the chip views are rebuilt only when the info actually changes.
    private var renderedVideoInfo: VideoTrackInfo?
    /// Mirrors the overlay's visibility for keyboard routing only; the
    /// countdown decisions stay in the coordinator.
    private var isUpNextShown = false
    /// Queue snapshot for the playlist popover (refreshed by the
    /// coordinator via `setPlaylist`).
    private var playlistItems: [ContentItem] = []
    private var playlistCurrentIndex = 0
    private var currentPlayMode: PlayMode = .list
    /// Retained while shown; a popover deallocates mid-flight otherwise.
    private var activePopover: NSPopover?

    /// Playback rates offered by the speed popover.
    private static let speedOptions: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    /// Play modes with their popover labels and capsule symbols.
    private static let playModeInfo: [(mode: PlayMode, label: String, symbol: String)] = [
        (.single, "单视频播放", "play.rectangle"),
        (.repeatOne, "单视频循环", "repeat.1"),
        (.list, "列表播放", "list.bullet"),
        (.listLoop, "列表循环", "repeat"),
        (.shuffle, "随机播放", "shuffle"),
    ]

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
        // The centered overlay title below replaces the system title (long
        // names lean left in the system title bar; ours truncates from the
        // middle and stays centered).
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
        startSession()
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

        let host = VideoLayerHostView(videoLayer: videoLayer)
        videoHost = host
        rootView.addSubview(host)

        // Centered file name across the top: middle-truncating so a long
        // name stays visually centered, with a shadow for bright frames.
        centerTitleLabel.attributedStringValue = Self.makeCenterTitle(title)
        centerTitleLabel.lineBreakMode = .byTruncatingMiddle
        centerTitleLabel.alignment = .center
        rootView.addSubview(centerTitleLabel)

        // Codec chips top-left, below the traffic-light safety zone (the
        // full-size content view puts the lights at the very top-left).
        codecChipsRow.orientation = .horizontal
        codecChipsRow.spacing = 6
        rootView.addSubview(codecChipsRow)
        codecChipsRow.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(16)
            make.top.equalToSuperview().offset(40)
        }

        // The capsule carries the shadow on its own (unclipped) layer; the
        // board view inside clips to the corner radius. Opaque warm black
        // (surfaceOverlay) so the chrome reads the same over bright frames
        // as over dark ones.
        controlsCapsule.onHoverChanged = { [weak self] over in
            self?.viewModel.setPointerOverControls(over)
        }
        let capsuleBoard = NSView()
        capsuleBoard.wantsLayer = true
        capsuleBoard.layer?.backgroundColor = CoveStyle.surfaceOverlay.cgColor
        capsuleBoard.layer?.cornerRadius = CoveStyle.radiusLarge
        capsuleBoard.layer?.masksToBounds = true
        controlsCapsule.addSubview(capsuleBoard)
        rootView.addSubview(controlsCapsule)

        configureButton(
            previousTrackButton, symbol: "backward.end.fill",
            accessibilityDescription: "上一个视频",
            action: #selector(handlePreviousTrack(_:))
        )
        configureButton(
            playPauseButton, symbol: "pause.fill",
            accessibilityDescription: "播放/暂停",
            action: #selector(handlePlayPause(_:))
        )
        configureButton(
            nextTrackButton, symbol: "forward.end.fill",
            accessibilityDescription: "下一个视频",
            action: #selector(handleNextTrack(_:))
        )
        configureButton(
            playlistButton, symbol: "list.bullet.rectangle",
            accessibilityDescription: "播放列表",
            action: #selector(handlePlaylistTapped(_:))
        )
        // Disabled until the coordinator reports the playlist position.
        previousTrackButton.isEnabled = false
        nextTrackButton.isEnabled = false

        // Playback rate: text button ("1x"), popover with fixed rates.
        speedButton.isBordered = false
        speedButton.title = "1x"
        speedButton.font = CoveStyle.monoDigitFont
        speedButton.contentTintColor = CoveStyle.textOnMedia2
        speedButton.target = self
        speedButton.action = #selector(handleSpeedTapped(_:))

        // Play mode: symbol button reflecting the current mode.
        playModeButton.isBordered = false
        playModeButton.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "播放模式")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: CoveStyle.symbolMedium, weight: .medium))
        playModeButton.contentTintColor = CoveStyle.textOnMedia2
        playModeButton.target = self
        playModeButton.action = #selector(handlePlayModeTapped(_:))

        progressSlider.isContinuous = true
        progressSlider.minValue = 0
        progressSlider.maxValue = 1
        progressSlider.target = self
        progressSlider.action = #selector(handleProgressSlider(_:))

        timeLabel.font = CoveStyle.monoDigitFont
        timeLabel.textColor = CoveStyle.textOnMedia2
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        volumeIconView.image = NSImage(
            systemSymbolName: Self.volumeSymbolName(for: viewModel.volume),
            accessibilityDescription: "音量"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: CoveStyle.symbolMedium, weight: .medium)
        )
        volumeIconView.contentTintColor = CoveStyle.textOnMedia2

        volumeSlider.minValue = 0
        volumeSlider.maxValue = 100
        volumeSlider.doubleValue = viewModel.volume
        volumeSlider.target = self
        volumeSlider.action = #selector(handleVolumeSlider(_:))

        volumeValueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        volumeValueLabel.textColor = CoveStyle.textOnMedia2
        volumeValueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        volumeValueLabel.setContentHuggingPriority(.required, for: .horizontal)

        capsuleBoard.addSubview(previousTrackButton)
        capsuleBoard.addSubview(playPauseButton)
        capsuleBoard.addSubview(nextTrackButton)
        capsuleBoard.addSubview(speedButton)
        capsuleBoard.addSubview(volumeIconView)
        capsuleBoard.addSubview(volumeSlider)
        capsuleBoard.addSubview(volumeValueLabel)
        capsuleBoard.addSubview(progressSlider)
        capsuleBoard.addSubview(timeLabel)
        capsuleBoard.addSubview(playlistButton)
        capsuleBoard.addSubview(playModeButton)

        host.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        centerTitleLabel.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.equalToSuperview().offset(7)
            // Clear the traffic lights on both sides.
            make.leading.greaterThanOrEqualToSuperview().offset(90)
            make.trailing.lessThanOrEqualToSuperview().offset(-90)
        }
        controlsCapsule.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.bottom.equalToSuperview().offset(-16)
            make.height.equalTo(48)
        }
        capsuleBoard.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        previousTrackButton.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(16)
            make.centerY.equalToSuperview()
            make.size.equalTo(28)
        }
        playPauseButton.snp.makeConstraints { make in
            make.leading.equalTo(previousTrackButton.snp.trailing).offset(6)
            make.centerY.equalToSuperview()
            make.size.equalTo(28)
        }
        nextTrackButton.snp.makeConstraints { make in
            make.leading.equalTo(playPauseButton.snp.trailing).offset(6)
            make.centerY.equalToSuperview()
            make.size.equalTo(28)
        }
        speedButton.snp.makeConstraints { make in
            make.leading.equalTo(nextTrackButton.snp.trailing).offset(12)
            make.centerY.equalToSuperview()
            make.width.equalTo(38)
        }
        volumeIconView.snp.makeConstraints { make in
            make.leading.equalTo(speedButton.snp.trailing).offset(8)
            make.centerY.equalToSuperview()
            make.size.equalTo(16)
        }
        volumeSlider.snp.makeConstraints { make in
            make.leading.equalTo(volumeIconView.snp.trailing).offset(4)
            make.centerY.equalToSuperview()
            make.width.equalTo(64)
        }
        volumeValueLabel.snp.makeConstraints { make in
            make.leading.equalTo(volumeSlider.snp.trailing).offset(4)
            make.centerY.equalToSuperview()
        }
        // The progress bar is the flexible element between volume and time.
        progressSlider.snp.makeConstraints { make in
            make.leading.equalTo(volumeValueLabel.snp.trailing).offset(12)
            make.centerY.equalToSuperview()
        }
        timeLabel.snp.makeConstraints { make in
            make.leading.equalTo(progressSlider.snp.trailing).offset(10)
            make.centerY.equalToSuperview()
        }
        playModeButton.snp.makeConstraints { make in
            make.leading.equalTo(timeLabel.snp.trailing).offset(10)
            make.centerY.equalToSuperview()
            make.size.equalTo(28)
        }
        playlistButton.snp.makeConstraints { make in
            make.leading.equalTo(playModeButton.snp.trailing).offset(4)
            make.trailing.equalToSuperview().offset(-16)
            make.centerY.equalToSuperview()
            make.size.equalTo(28)
        }

        // Up-next pill: same shadow/material recipe as the controls capsule,
        // parked above it in the bottom-right corner. Added last so it sits
        // on top of everything (including future video host swaps, which are
        // always positioned below the centered title).
        upNextOverlay.onPlayNow = { [weak self] in self?.onUpNextPlayNow?() }
        upNextOverlay.onCancel = { [weak self] in self?.onUpNextCancel?() }
        rootView.addSubview(upNextOverlay)
        upNextOverlay.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-16)
            // Above the 48pt capsule (bottom -16): 16 + 48 + 12 gap = 76.
            make.bottom.equalToSuperview().offset(-76)
            make.width.lessThanOrEqualTo(340)
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
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: CoveStyle.symbolMedium, weight: .semibold))
        button.contentTintColor = CoveStyle.textOnMedia1
        button.imageScaling = .scaleProportionallyUpOrDown
        button.target = self
        button.action = action
    }

    // MARK: - Track swap

    /// Enables/disables the prev/next transport buttons for the current
    /// playlist position (wired by the coordinator on open and track change).
    func setTransportAvailability(canGoPrevious: Bool, canGoNext: Bool) {
        previousTrackButton.isEnabled = canGoPrevious
        nextTrackButton.isEnabled = canGoNext
    }

    /// Refreshes the queue snapshot behind the playlist popover and the
    /// highlighted row (called by the coordinator on open and track change).
    func setPlaylist(items: [ContentItem], currentIndex: Int, playMode: PlayMode) {
        playlistItems = items
        playlistCurrentIndex = currentIndex
        setPlayMode(playMode)
        // The old panel's highlight is stale the moment the queue moves.
        if activePopover?.contentViewController is PlaylistPopoverController {
            activePopover?.close()
        }
    }

    /// Updates the play-mode button's symbol to `mode`.
    func setPlayMode(_ mode: PlayMode) {
        currentPlayMode = mode
        guard let info = Self.playModeInfo.first(where: { $0.mode == mode }) else { return }
        playModeButton.image = NSImage(
            systemSymbolName: info.symbol, accessibilityDescription: "播放模式"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: CoveStyle.symbolMedium, weight: .medium))
        playModeButton.toolTip = info.label
    }

    /// Applies a rate chosen in the speed popover to the live session.
    func applySpeed(_ speed: Double) {
        viewModel.setSpeed(speed)
    }

    /// Repeat-one replay of the live session (coordinator-driven).
    func replayCurrentTrack() {
        viewModel.replayFromStart()
    }

    /// Swaps the live session for a new track without closing the window:
    /// full screen and window position survive the change. Order matters —
    /// persist the outgoing resume point, cut its event feed so a dying mpv
    /// can never talk to the new session, shut the handle down, only then
    /// bring the new session up.
    func install(item: ContentItem, core: MPVPlayerCore, viewModel: PlayerViewModel) {
        self.viewModel.persistProgressOnClose()
        self.viewModel.onChange = nil
        self.core.onEvent = nil
        self.core.shutdown()

        self.core = core
        self.viewModel = viewModel

        let host = VideoLayerHostView(videoLayer: core.videoLayer)
        rootView.addSubview(host, positioned: .below, relativeTo: centerTitleLabel)
        host.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        videoHost?.removeFromSuperview()
        videoHost = host

        window?.title = item.name
        centerTitleLabel.attributedStringValue = Self.makeCenterTitle(item.name)
        startSession()
    }

    /// Binds and boots the current session (initial open and track swap).
    private func startSession() {
        viewModel.onChange = { [weak self] in self?.render() }
        render()
        core.load()
    }

    /// The centered file name: white text with a shadow so it stays
    /// readable on bright frames.
    private static func makeCenterTitle(_ title: String) -> NSAttributedString {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        return NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: CoveStyle.textOnMedia1,
                .shadow: shadow,
            ]
        )
    }

    /// Capsule text for a rate: "1x", "1.5x".
    private static func speedLabel(_ speed: Double) -> String {
        speed == speed.rounded() ? "\(Int(speed))x" : "\(speed)x"
    }

    /// Volume icon follows the level, system convention: muted at zero,
    /// then one to three waves by thirds.
    static func volumeSymbolName(for volume: Double) -> String {
        switch volume {
        case ..<1: return "speaker.slash.fill"
        case 1..<34: return "speaker.wave.1.fill"
        case 34..<67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    // MARK: - Popovers

    /// Presents `controller` in a transient dark popover above `anchor`.
    private func presentPopover(_ controller: NSViewController, from anchor: NSView) {
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        activePopover = popover
        popover.delegate = self
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    @objc private func handleSpeedTapped(_ sender: NSButton) {
        let options = Self.speedOptions.map {
            (label: Self.speedLabel($0), value: String($0), checked: $0 == viewModel.speed)
        }
        let controller = OptionListPopoverController(
            header: "播放速度",
            options: options
        ) { [weak self] value in
            self?.activePopover?.close()
            if let speed = Double(value) {
                self?.onSpeedSelected?(speed)
            }
        }
        presentPopover(controller, from: sender)
    }

    @objc private func handlePlayModeTapped(_ sender: NSButton) {
        let options = Self.playModeInfo.map {
            (label: $0.label, value: "\($0.mode)", checked: $0.mode == currentPlayMode)
        }
        let controller = OptionListPopoverController(
            header: "播放模式",
            options: options
        ) { [weak self] value in
            self?.activePopover?.close()
            guard let mode = Self.playModeInfo.first(where: { "\($0.mode)" == value })?.mode else { return }
            self?.onPlayModeSelected?(mode)
        }
        presentPopover(controller, from: sender)
    }

    @objc private func handlePlaylistTapped(_ sender: NSButton) {
        let controller = PlaylistPopoverController(
            items: playlistItems,
            currentIndex: playlistCurrentIndex
        ) { [weak self] path in
            self?.activePopover?.close()
            self?.onSelectTrack?(path)
        }
        presentPopover(controller, from: sender)
    }

    // MARK: - Up Next overlay

    /// Shows the countdown pill for `title` with the given remaining
    /// seconds. Pure rendering: the coordinator drives timing and firing.
    func showUpNext(title: String, seconds: Int) {
        upNextOverlay.configure(title: title, seconds: seconds)
        guard !isUpNextShown else { return }
        isUpNextShown = true
        upNextOverlay.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = CoveStyle.motionMedium
            context.timingFunction = CoveStyle.motionTimingFunction
            upNextOverlay.animator().alphaValue = 1
        }
    }

    /// Refreshes the countdown readout ("N 秒后播放").
    func updateUpNext(seconds: Int) {
        upNextOverlay.update(seconds: seconds)
    }

    /// Hides the pill. Instant rather than faded: by the time this runs the
    /// countdown has ended (fired into a track change or cancelled), so a
    /// lingering overlay would only obscure the new frame.
    func hideUpNext() {
        guard isUpNextShown else { return }
        isUpNextShown = false
        upNextOverlay.isHidden = true
        upNextOverlay.alphaValue = 0
    }

    // MARK: - Rendering

    private func render() {
        let symbol = viewModel.showsPauseButton ? "pause.fill" : "play.fill"
        playPauseButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "播放/暂停")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: CoveStyle.symbolMedium, weight: .semibold))
        progressSlider.isEnabled = viewModel.isProgressEnabled
        progressSlider.maxValue = max(viewModel.duration, 1)
        if !viewModel.isScrubbing {
            progressSlider.doubleValue = viewModel.currentTime
        }
        // Volume slider + readout follow every change source (arrow keys
        // included) — the slider itself only reflects drags through its
        // own action, so the keyboard path used to leave it behind.
        volumeSlider.doubleValue = viewModel.volume
        volumeValueLabel.stringValue = "\(Int(viewModel.volume.rounded()))"
        volumeIconView.image = NSImage(
            systemSymbolName: Self.volumeSymbolName(for: viewModel.volume),
            accessibilityDescription: "音量"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: CoveStyle.symbolMedium, weight: .medium)
        )
        speedButton.title = Self.speedLabel(viewModel.speed)
        timeLabel.stringValue = viewModel.statusText ?? viewModel.timeText
        renderCodecChips()
        renderControlsVisibility()
    }

    /// Rebuilds the codec chips when the video info changes (see
    /// `renderedVideoInfo` for why this is guarded per render pass).
    private func renderCodecChips() {
        let info = viewModel.videoInfo
        guard info != renderedVideoInfo else { return }
        renderedVideoInfo = info
        codecChipsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let info else { return }
        for text in Self.codecChipTexts(info) {
            codecChipsRow.addArrangedSubview(makeCodecChip(text))
        }
    }

    /// One surfaceOverlay tile: radius-small board, mono-digit text at the
    /// secondary media tier.
    private func makeCodecChip(_ text: String) -> NSView {
        let chip = RoundedFillView()
        chip.fillColor = CoveStyle.surfaceOverlay
        chip.cornerRadius = CoveStyle.radiusSmall
        let label = NSTextField(labelWithString: text)
        label.font = CoveStyle.monoDigitFont
        label.textColor = CoveStyle.textOnMedia2
        chip.addSubview(label)
        chip.snp.makeConstraints { make in
            make.height.equalTo(20)
        }
        label.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(8)
            make.trailing.equalToSuperview().offset(-8)
            make.centerY.equalToSuperview()
        }
        return chip
    }

    /// The four chips' texts: decode path, codec family, dimensions, and
    /// instantaneous bitrate (an em dash while mpv reports no bitrate).
    private static func codecChipTexts(_ info: VideoTrackInfo) -> [String] {
        [
            info.hardwareDecoded ? "HW" : "SW",
            info.codec.uppercased(),
            "\(info.width)×\(info.height)",
            info.bitrate > 0 ? String(format: "%.1f Mbps", info.bitrate / 1_000_000) : "—",
        ]
    }

    /// Fades the capsule (and the codec chips, which ride the same
    /// lifecycle) in/out and hides the cursor alongside it. Hit-testing on
    /// the capsule is cut while hidden so the invisible controls cannot
    /// catch clicks.
    private func renderControlsVisibility() {
        let visible = viewModel.controlsVisible
        guard visible != renderedControlsVisible else { return }
        renderedControlsVisible = visible
        controlsCapsule.isInteractable = visible
        NSAnimationContext.runAnimationGroup { context in
            context.duration = CoveStyle.motionMedium
            context.timingFunction = CoveStyle.motionTimingFunction
            controlsCapsule.animator().alphaValue = visible ? 1 : 0
            codecChipsRow.animator().alphaValue = visible ? 1 : 0
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

    @objc private func handlePreviousTrack(_ sender: NSButton) {
        onPreviousTrack?()
    }

    @objc private func handleNextTrack(_ sender: NSButton) {
        onNextTrack?()
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
        // The up-next overlay takes priority while shown: Esc cancels the
        // countdown (a second Esc then exits full screen as usual) and
        // Return plays the next track immediately.
        if isUpNextShown {
            switch event.keyCode {
            case 53: // esc
                onUpNextCancel?()
                return true
            case 36: // return
                onUpNextPlayNow?()
                return true
            default:
                break
            }
        }
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
            handleEscape()
            return true
        default:
            return false
        }
    }

    /// Esc steps out of full screen; in a windowed session it does nothing
    /// (close via the window's close button or Cmd+W).
    private func handleEscape() {
        guard let window, window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Persist the resume point before the mpv handle goes away.
        viewModel.persistProgressOnClose()
        core.shutdown()
        onClose?()
        onClose = nil
    }
}

extension PlayerWindowController: NSPopoverDelegate {
    /// Drops the retention once the popover dismissed (transient tap-out or
    /// an explicit close after selection).
    func popoverDidClose(_ notification: Notification) {
        activePopover = nil
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

/// The "Up Next" countdown pill: next-episode file name (truncated), the
/// seconds readout, and the play-now / cancel actions as primary/secondary
/// pill buttons. Same visual recipe as the controls capsule — drop shadow
/// on its own unclipped layer, the opaque surfaceOverlay board inside
/// clips itself to the corner radius. Pure rendering: no timer, no
/// countdown decisions, callbacks are forwarded to the window controller
/// which relays them to the coordinator.
private final class UpNextOverlayView: NSView {
    var onPlayNow: (() -> Void)?
    var onCancel: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let countdownLabel = NSTextField(labelWithString: "")
    private let playNowButton = PillButton(title: "立即播放", style: .primary)
    private let cancelButton = PillButton(title: "取消", style: .secondary)

    init() {
        super.init(frame: .zero)
        // Starts hidden: showUpNext fades the alpha in from zero.
        isHidden = true
        alphaValue = 0
        wantsLayer = true
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        self.shadow = shadow

        let board = NSView()
        board.wantsLayer = true
        board.layer?.backgroundColor = CoveStyle.surfaceOverlay.cgColor
        board.layer?.cornerRadius = CoveStyle.radiusLarge
        board.layer?.masksToBounds = true
        addSubview(board)

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.attributedStringValue = NSAttributedString(
            string: "",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: CoveStyle.textOnMedia1,
            ]
        )
        // The file name yields and truncates; the pill never grows past its
        // width cap because of a long name.
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        countdownLabel.font = CoveStyle.formLabelFont
        countdownLabel.textColor = CoveStyle.textOnMedia2

        playNowButton.refusesFirstResponder = true
        playNowButton.target = self
        playNowButton.action = #selector(handlePlayNow)
        cancelButton.refusesFirstResponder = true
        cancelButton.target = self
        cancelButton.action = #selector(handleCancel)

        board.addSubview(titleLabel)
        board.addSubview(countdownLabel)
        board.addSubview(playNowButton)
        board.addSubview(cancelButton)

        board.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        titleLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(16)
            make.top.equalToSuperview().offset(10)
            make.width.lessThanOrEqualTo(220)
        }
        countdownLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(16)
            make.top.equalTo(titleLabel.snp.bottom).offset(3)
            make.bottom.equalToSuperview().offset(-10)
        }
        playNowButton.snp.makeConstraints { make in
            make.leading.greaterThanOrEqualTo(titleLabel.snp.trailing).offset(12)
            make.leading.greaterThanOrEqualTo(countdownLabel.snp.trailing).offset(12)
            make.centerY.equalToSuperview()
        }
        cancelButton.snp.makeConstraints { make in
            make.leading.equalTo(playNowButton.snp.trailing).offset(8)
            make.trailing.equalToSuperview().offset(-16)
            make.centerY.equalToSuperview()
        }
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

    func configure(title: String, seconds: Int) {
        titleLabel.attributedStringValue = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: CoveStyle.textOnMedia1,
            ]
        )
        update(seconds: seconds)
    }

    func update(seconds: Int) {
        countdownLabel.stringValue = "\(seconds) 秒后播放"
    }

    @objc private func handlePlayNow() { onPlayNow?() }
    @objc private func handleCancel() { onCancel?() }
}

/// Shared chrome for the capsule's picker popovers (speed, play mode):
/// a small header over a vertical list of full-width rows; the selected
/// row carries a checkmark. Rows are plain buttons so hover and keyboard
/// activation work for free. The value is a string to keep the picker
/// generic; call sites convert back.
@MainActor
private final class OptionListPopoverController: NSViewController {
    typealias Option = (label: String, value: String, checked: Bool)

    private let header: String
    private let options: [Option]
    private let onSelect: ((String) -> Void)?

    init(header: String, options: [Option], onSelect: ((String) -> Void)?) {
        self.header = header
        self.options = options
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        // surfaceOverlay (warm black) sits flush with the darkAqua popover
        // chrome — the system arrow (≈#1E1E1E) and the content board read
        // as one temperature instead of cold-gray vs warm-gray.
        root.layer?.backgroundColor = CoveStyle.surfaceOverlay.cgColor

        let headerLabel = NSTextField(labelWithString: header)
        headerLabel.font = CoveStyle.sectionHeaderFont
        headerLabel.textColor = .secondaryLabelColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        for option in options {
            let row = makeRow(option)
            stack.addArrangedSubview(row)
            row.snp.makeConstraints { make in
                make.width.equalTo(stack)
            }
        }

        root.addSubview(headerLabel)
        root.addSubview(stack)
        headerLabel.snp.makeConstraints { make in
            make.leading.top.equalToSuperview().inset(14)
        }
        stack.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(8)
            make.top.equalTo(headerLabel.snp.bottom).offset(6)
            make.bottom.equalToSuperview().offset(-8)
        }
        // Same as the playlist panel: the popover sizes from
        // preferredContentSize, and a zero size renders as nothing.
        let height = CGFloat(options.count) * 26 + 54
        preferredContentSize = NSSize(width: 190, height: height)
        root.setFrameSize(preferredContentSize)
        view = root
    }

    private func makeRow(_ option: Option) -> NSButton {
        let row = NSButton(title: option.label, target: self, action: #selector(handleSelect(_:)))
        row.isBordered = false
        row.font = .systemFont(ofSize: 13, weight: option.checked ? .semibold : .regular)
        row.alignment = .left
        // The current option carries the accent-gold treatment — same
        // semantics as the playlist's gold speaker row; the white
        // checkmark is retired.
        row.contentTintColor = option.checked ? CoveStyle.accentGold : CoveStyle.textOnMedia1
        row.identifier = NSUserInterfaceItemIdentifier(option.value)
        if option.checked {
            row.image = NSImage(
                systemSymbolName: "checkmark", accessibilityDescription: nil
            )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: CoveStyle.symbolSmall, weight: .semibold))
            row.imagePosition = .imageTrailing
        }
        return row
    }

    @objc private func handleSelect(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue else { return }
        onSelect?(value)
    }
}

/// The queue panel (playlist button): every video in the sibling queue as
/// a scrollable row; the current one is gold-tinted with a speaker symbol.
/// Tapping a row jumps to that video via the coordinator.
///
/// Built on NSTableView: an NSStackView as a scroll view's documentView
/// keeps a zero frame (nothing renders), which showed up as an empty list.
@MainActor
private final class PlaylistPopoverController: NSViewController {
    private let items: [ContentItem]
    private let currentIndex: Int
    private let onSelect: ((String) -> Void)?

    private let tableView = NSTableView()

    init(items: [ContentItem], currentIndex: Int, onSelect: ((String) -> Void)?) {
        self.items = items
        self.currentIndex = currentIndex
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        // Same warm-black board as the picker popovers (see the comment in
        // OptionListPopoverController.loadView).
        root.layer?.backgroundColor = CoveStyle.surfaceOverlay.cgColor

        let headerLabel = NSTextField(labelWithString: "播放列表")
        headerLabel.font = CoveStyle.sectionHeaderFont
        headerLabel.textColor = .secondaryLabelColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 32
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.focusRingType = .none
        // The current row is styled gold by the cell; the system highlight
        // would fight that, so the table stays selectionless.
        tableView.selectionHighlightStyle = .none
        tableView.style = .plain
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(handleRowClick(_:))

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // Elastic bounce makes the wheel feel laggy in a short panel; a
        // hard stop at the ends scrolls much more directly.
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none

        root.addSubview(headerLabel)
        root.addSubview(scrollView)
        headerLabel.snp.makeConstraints { make in
            make.leading.top.equalToSuperview().inset(14)
        }
        scrollView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(8)
            make.trailing.equalToSuperview().offset(-8)
            make.top.equalTo(headerLabel.snp.bottom).offset(6)
            make.bottom.equalToSuperview().offset(-8)
        }

        // NSPopover sizes from preferredContentSize; without it the panel
        // collapses to zero. Natural height up to a generous cap so a long
        // queue still fits on screen; the table scrolls past it.
        let naturalHeight = CGFloat(items.count) * 32 + 62
        preferredContentSize = NSSize(width: 320, height: min(naturalHeight, 480))
        root.setFrameSize(preferredContentSize)
        view = root
    }

    @objc private func handleRowClick(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard items.indices.contains(row) else { return }
        onSelect?(items[row].path)
    }
}

extension PlaylistPopoverController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("PlaylistRowCell")
        let cell: PlaylistRowCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? PlaylistRowCellView {
            cell = reused
        } else {
            cell = PlaylistRowCellView()
            cell.identifier = identifier
        }
        cell.configure(name: items[row].name, isCurrent: row == currentIndex)
        return cell
    }
}

/// One queue row: the file name, gold + speaker when it is the current
/// video.
@MainActor
private final class PlaylistRowCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: CoveStyle.symbolSmall, weight: .semibold))
        iconView.contentTintColor = CoveStyle.accentGold
        iconView.isHidden = true

        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.textColor = .white

        addSubview(iconView)
        addSubview(nameLabel)
        iconView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(8)
            make.centerY.equalToSuperview()
            make.size.equalTo(14)
        }
        nameLabel.snp.makeConstraints { make in
            make.leading.equalTo(iconView.snp.trailing).offset(6)
            make.trailing.equalToSuperview().offset(-8)
            make.centerY.equalToSuperview()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(name: String, isCurrent: Bool) {
        nameLabel.stringValue = name
        nameLabel.textColor = isCurrent ? CoveStyle.accentGold : .white
        nameLabel.font = .systemFont(ofSize: 13, weight: isCurrent ? .semibold : .regular)
        iconView.isHidden = !isCurrent
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
