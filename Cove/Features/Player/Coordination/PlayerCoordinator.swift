import AppKit
import SourceKit

/// Assembles and owns the player window (bridge + mpv core + view model
/// + window controller) and the sibling-video playlist. Single-window
/// policy: opening another video — or stepping through the playlist —
/// swaps the session inside the same window via `install`, so full screen
/// and window position survive a track change. Window close shuts the live
/// session's mpv handle and stream bridge down via `windowWillClose`.
///
/// The play mode (single / repeat-one / list / list-loop / shuffle) drives
/// what a clean end-of-file does and how prev/next step; the pure index
/// math lives in `PlayerPlaylist`. List-like modes still run the 5-second
/// up-next countdown before auto-advancing — repeat-one replays in place
/// without a countdown, single just parks on the last frame.
@MainActor
final class PlayerCoordinator {
    private static let upNextDuration = 5

    private let progressStore: PlaybackProgressStoring?
    private var windowController: PlayerWindowController?
    private var playlist = PlayerPlaylist(items: [], selectedPath: "")
    private var sourceID: String?
    private var reader: VideoStreamBridge.RangedReader?
    /// Live countdown, if any; `nil` once fired or cancelled. Being `nil`
    /// is what makes a fire beat and a manual step mutually exclusive.
    private var upNextCountdown: UpNextCountdown?
    private var upNextTimer: Timer?
    private var playMode: PlayMode = .list {
        didSet { updateTransport() }
    }
    /// Session-sticky playback rate: applied to every newly built session
    /// so a track change keeps the user's chosen speed.
    private var playbackSpeed: Double = 1

    var onError: ((_ error: Error, _ title: String) -> Void)?
    var onMessageError: ((_ message: String, _ title: String) -> Void)?

    init(progressStore: PlaybackProgressStoring? = nil) {
        self.progressStore = progressStore
    }

    /// Opens `selectedPath` within its sibling-video queue. Reuses the
    /// existing window (session swap) when one is already up.
    func open(
        items: [ContentItem],
        selectedPath: String,
        sourceID: String?,
        reader: @escaping VideoStreamBridge.RangedReader
    ) {
        // Defensive: opening a new video from the browser while a countdown
        // is alive (e.g. the user picked another file the instant a track
        // ended) kills the pending advance.
        cancelUpNextCountdown()
        playlist = PlayerPlaylist(items: items, selectedPath: selectedPath)
        self.sourceID = sourceID
        self.reader = reader
        guard let item = playlist.current else { return }
        // A failed first session leaves any previous one untouched.
        guard let session = buildSession(item: item) else { return }
        if let windowController {
            windowController.install(item: item, core: session.core, viewModel: session.viewModel)
        } else {
            let controller = PlayerWindowController(item: item, core: session.core, viewModel: session.viewModel)
            controller.onClose = { [weak self] in
                self?.cancelUpNextCountdown()
                self?.windowController = nil
            }
            controller.onPreviousTrack = { [weak self] in self?.step(delta: -1) }
            controller.onNextTrack = { [weak self] in self?.step(delta: 1) }
            controller.onSelectTrack = { [weak self] in self?.jump(toPath: $0) }
            controller.onPlayModeSelected = { [weak self] in self?.selectPlayMode($0) }
            controller.onSpeedSelected = { [weak self] in self?.selectSpeed($0) }
            controller.onRetry = { [weak self] in
                guard let self else { return }
                // Rebuild the session for the queue's current item: a fresh
                // bridge + mpv handle over the same reader.
                self.moveTo(index: self.playlist.currentIndex)
            }
            windowController = controller
            controller.show()
        }
        windowController?.setPlaylist(items: items, currentIndex: playlist.currentIndex, playMode: playMode)
        updateTransport()
    }

    /// Previous/next track intents (the transport buttons); no-ops at the
    /// queue edges unless the mode wraps/shuffles.
    private func step(delta: Int) {
        guard let target = playlist.stepIndex(delta: delta, mode: playMode) else { return }
        // A live countdown never survives a transport step: cancel it first.
        // No-op when the fire beat got here first — `upNextCountdown` is
        // already nil, so fire and manual step cannot both advance the queue.
        cancelUpNextCountdown()
        moveTo(index: target)
    }

    /// Playlist-panel selection: jump straight to the tapped video.
    private func jump(toPath path: String) {
        guard let target = playlist.items.firstIndex(where: { $0.path == path }),
              target != playlist.currentIndex else { return }
        cancelUpNextCountdown()
        moveTo(index: target)
    }

    private func selectPlayMode(_ mode: PlayMode) {
        playMode = mode
        windowController?.setPlayMode(mode)
    }

    /// Speed popover selection: remembered for future sessions and applied
    /// to the live one.
    private func selectSpeed(_ speed: Double) {
        playbackSpeed = speed
        windowController?.applySpeed(speed)
    }

    /// Swaps the live session to `index`, rolling the index back if the
    /// session fails to build.
    private func moveTo(index: Int) {
        guard playlist.items.indices.contains(index), let windowController else { return }
        let outgoing = playlist.currentIndex
        playlist.setCurrentIndex(index)
        guard let item = playlist.current else { return }
        guard let session = buildSession(item: item) else {
            // The outgoing session is still alive; roll the index back so
            // the queue stays consistent with what is actually playing.
            playlist.setCurrentIndex(outgoing)
            return
        }
        windowController.install(item: item, core: session.core, viewModel: session.viewModel)
        windowController.setPlaylist(items: playlist.items, currentIndex: index, playMode: playMode)
        updateTransport()
    }

    /// Clean end of file: what happens next is the play mode's call.
    /// List-like modes run the up-next countdown and advance when it fires;
    /// repeat-one replays in place; single parks on the last frame.
    private func advanceAfterEnded() {
        guard let windowController else { return }
        // The ended event can repeat; a live countdown absorbs it.
        guard upNextCountdown == nil else { return }
        guard let next = playlist.autoAdvanceIndex(mode: playMode) else { return }
        if next == playlist.currentIndex {
            // Repeat-one: replay without the countdown ceremony.
            windowController.replayCurrentTrack()
            return
        }
        let title = playlist.items[next].name
        upNextCountdown = UpNextCountdown(totalSeconds: Self.upNextDuration)
        windowController.showUpNext(title: title, seconds: Self.upNextDuration)
        // Target/selector rather than a block: the block API is @Sendable
        // and would fight the coordinator's MainActor isolation.
        upNextTimer = Timer.scheduledTimer(
            timeInterval: 1,
            target: self,
            selector: #selector(upNextTimerFired),
            userInfo: nil,
            repeats: true
        )
    }

    // MARK: - Up Next countdown

    /// Timer beat: refresh the overlay readout, and on zero fire the
    /// track change.
    @objc private func upNextTimerFired() {
        guard var countdown = upNextCountdown, let windowController else { return }
        let remaining = countdown.tick()
        if let remaining, remaining > 0 {
            upNextCountdown = countdown
            windowController.updateUpNext(seconds: remaining)
            return
        }
        // Zero = fired this beat; `nil` is unreachable in practice (cancel
        // paths nil the model and invalidate the timer) but tears down
        // without advancing, just in case.
        upNextCountdown = nil
        tearDownUpNextTimer()
        windowController.hideUpNext()
        if countdown.didFire {
            // The mode is re-read at fire time; a mode switch during the
            // countdown is honored, and a mode that no longer advances just
            // parks (autoAdvanceIndex == nil or current → replay).
            if let next = playlist.autoAdvanceIndex(mode: playMode) {
                if next == playlist.currentIndex {
                    windowController.replayCurrentTrack()
                } else {
                    moveTo(index: next)
                }
            }
        }
    }

    /// The single cancel funnel: overlay cancel button, Esc, manual
    /// prev/next, window close, defensive re-open. Stops the timer, drops
    /// the model, hides the pill, and leaves the queue position untouched
    /// (stay on the last frame).
    private func cancelUpNextCountdown() {
        tearDownUpNextTimer()
        upNextCountdown = nil
        windowController?.hideUpNext()
    }

    private func tearDownUpNextTimer() {
        upNextTimer?.invalidate()
        upNextTimer = nil
    }

    private typealias Session = (core: MPVPlayerCore, viewModel: PlayerViewModel)

    private func buildSession(item: ContentItem) -> Session? {
        guard let reader else { return nil }
        let bridge = VideoStreamBridge(path: item.path, size: item.size, reader: reader)
        do {
            let core = try MPVPlayerCore(bridge: bridge)
            // Resume positions are remembered per source, so same-named
            // files on different servers never collide.
            let progressKey = sourceID.map { "\($0)|\(item.path)" }
            let viewModel = PlayerViewModel(controller: core, progressStore: progressStore, progressKey: progressKey)
            if playbackSpeed != 1 {
                // Keep the chosen rate across track changes; setting speed
                // on the idle handle applies to the upcoming file.
                viewModel.setSpeed(playbackSpeed)
            }
            core.onEvent = { [weak viewModel] event in viewModel?.apply(event) }
            viewModel.onError = { [weak self] detail in
                self?.onMessageError?("播放中断：\(detail)", "播放失败")
            }
            viewModel.onEnded = { [weak self] in self?.advanceAfterEnded() }
            return (core, viewModel)
        } catch {
            bridge.detach()
            onError?(error, "打开视频失败")
            return nil
        }
    }

    private func updateTransport() {
        // Wrap/shuffle modes can always step while a second video exists;
        // linear modes are bounded by the queue edges.
        let wraps = playMode == .listLoop || playMode == .shuffle
        windowController?.setTransportAvailability(
            canGoPrevious: wraps ? playlist.items.count > 1 : playlist.canGoPrevious,
            canGoNext: wraps ? playlist.items.count > 1 : playlist.canGoNext
        )
    }
}

extension MPVPlayerCore: PlayerPlaybackControlling {}
