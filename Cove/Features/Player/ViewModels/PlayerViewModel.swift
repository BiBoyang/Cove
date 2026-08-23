import Foundation

/// The commands the player UI can issue to a playback engine. Implemented
/// by `MPVPlayerCore`; tests substitute a recorder.
@MainActor
protocol PlayerPlaybackControlling: AnyObject {
    func togglePause()
    func seek(bySeconds seconds: Int)
    func seekTo(seconds: Double)
    func setVolume(_ volume: Double)
}

/// UI-facing playback state for one video session. Raw mpv events
/// (`PlayerCoreEvent`) are reduced here into the state machine and the
/// displayed progress/volume values, so the window controller stays a dumb
/// renderer and the whole reducer is unit-testable without mpv.
@MainActor
final class PlayerViewModel {
    enum State: Equatable {
        case loading
        case playing
        case paused
        case buffering
        case error
    }

    private let controller: PlayerPlaybackControlling

    private var hasLoaded = false
    private var hasFailed = false
    private var isPaused = false
    private var isBuffering = false

    private(set) var state: State = .loading
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    /// While true, incoming time-pos updates are ignored so the slider the
    /// user is dragging does not fight playback position updates.
    private(set) var isScrubbing = false
    private(set) var volume: Double = 100

    /// Called whenever a displayed value may have changed; the view
    /// re-renders from the view model's public state.
    var onChange: (() -> Void)?
    /// Playback failure detail, forwarded to the coordinator's error chain.
    var onError: ((String) -> Void)?

    init(controller: PlayerPlaybackControlling) {
        self.controller = controller
    }

    // MARK: - Event reduction

    func apply(_ event: PlayerCoreEvent) {
        switch event {
        case .fileLoaded:
            hasLoaded = true
        case .timePosChanged(let time):
            if !isScrubbing { currentTime = time }
        case .durationChanged(let value):
            duration = max(0, value)
        case .pauseChanged(let paused):
            isPaused = paused
        case .bufferingChanged(let buffering):
            isBuffering = buffering
        case .ended:
            // v1: a clean end leaves the last frame up; the user closes the
            // window or seeks back manually.
            break
        case .playbackFailed(let detail):
            hasFailed = true
            onError?(detail)
        }
        state = Self.computeState(hasLoaded: hasLoaded, hasFailed: hasFailed, isPaused: isPaused, isBuffering: isBuffering)
        onChange?()
    }

    static func computeState(hasLoaded: Bool, hasFailed: Bool, isPaused: Bool, isBuffering: Bool) -> State {
        if hasFailed { return .error }
        guard hasLoaded else { return .loading }
        if isBuffering { return .buffering }
        return isPaused ? .paused : .playing
    }

    // MARK: - User intents

    func togglePause() {
        controller.togglePause()
    }

    /// Relative seek, used by the arrow keys.
    func seekBy(seconds: Int) {
        controller.seek(bySeconds: seconds)
    }

    func beginScrubbing() {
        guard isProgressEnabled else { return }
        isScrubbing = true
    }

    /// Updates the displayed position while dragging; no seek is issued
    /// until `endScrubbing`.
    func scrubTo(_ time: Double) {
        guard isScrubbing else { return }
        currentTime = min(max(0, time), duration)
        onChange?()
    }

    func endScrubbing() {
        guard isScrubbing else { return }
        isScrubbing = false
        // currentTime already holds the drop target, so the slider shows
        // the destination while mpv's post-seek time-pos catches up.
        controller.seekTo(seconds: currentTime)
        onChange?()
    }

    func setVolume(_ newValue: Double) {
        volume = min(max(0, newValue), 100)
        controller.setVolume(volume)
        onChange?()
    }

    // MARK: - Display projections

    var isProgressEnabled: Bool {
        hasLoaded && !hasFailed
    }

    /// Status text replacing the time readout outside normal playback.
    var statusText: String? {
        switch state {
        case .loading: return "加载中…"
        case .buffering: return "缓冲中…"
        case .error: return "播放失败"
        case .playing, .paused: return nil
        }
    }

    /// True while the transport button should offer pausing.
    var showsPauseButton: Bool {
        state == .playing || state == .buffering
    }

    var timeText: String {
        "\(Self.formatTime(currentTime)) / \(Self.formatTime(duration))"
    }

    static func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
