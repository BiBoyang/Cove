import AppKit
import SourceKit

/// Assembles and owns the player window (bridge + mpv core + view model
/// + window controller) and the sibling-video playlist. Single-window
/// policy: opening another video — or stepping through the playlist —
/// swaps the session inside the same window via `install`, so full screen
/// and window position survive a track change. Window close shuts the live
/// session's mpv handle and stream bridge down via `windowWillClose`.
@MainActor
final class PlayerCoordinator {
    private let progressStore: PlaybackProgressStoring?
    private var windowController: PlayerWindowController?
    private var playlist = PlayerPlaylist(items: [], selectedPath: "")
    private var sourceID: String?
    private var reader: VideoStreamBridge.RangedReader?

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
            controller.onClose = { [weak self] in self?.windowController = nil }
            controller.onPreviousTrack = { [weak self] in self?.step(by: -1) }
            controller.onNextTrack = { [weak self] in self?.step(by: 1) }
            windowController = controller
            controller.show()
        }
        updateTransport()
    }

    /// Previous/next track intents (the transport buttons); no-ops at the
    /// queue ends.
    private func step(by delta: Int) {
        let moved = delta > 0 ? playlist.advance() : playlist.back()
        guard moved, let windowController, let item = playlist.current else { return }
        guard let session = buildSession(item: item) else {
            // The outgoing session is still alive; roll the index back so
            // the queue stays consistent with what is actually playing.
            _ = delta > 0 ? playlist.back() : playlist.advance()
            return
        }
        windowController.install(item: item, core: session.core, viewModel: session.viewModel)
        updateTransport()
    }

    /// Clean end of file: auto-advance into the next video. The last one in
    /// the queue keeps the old behavior (last frame stays up).
    private func advanceAfterEnded() {
        guard playlist.canGoNext else { return }
        step(by: 1)
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
        windowController?.setTransportAvailability(
            canGoPrevious: playlist.canGoPrevious,
            canGoNext: playlist.canGoNext
        )
    }
}

extension MPVPlayerCore: PlayerPlaybackControlling {}
