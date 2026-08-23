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
    /// Seconds of pointer idleness after which the controls hide themselves
    /// during playback. Injected so tests can shrink the wait.
    private let idleHideInterval: TimeInterval
    /// Resume-position persistence. Both are nil for sessions that should
    /// not be remembered (e.g. no source id at open time).
    private let progressStore: PlaybackProgressStoring?
    private let progressKey: String?

    private var hasLoaded = false
    private var hasFailed = false
    private var isPaused = false
    private var isBuffering = false
    /// Resume is attempted exactly once per session, only after both the
    /// file is loaded and a real duration is known (streamed sources can
    /// report duration late or never).
    private var resumeAttempted = false
    /// Baseline for the ~5s position-delta throttle on progress writes.
    private var lastPersistedPosition = -Double.infinity

    private(set) var state: State = .loading
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    /// While true, incoming time-pos updates are ignored so the slider the
    /// user is dragging does not fight playback position updates.
    private(set) var isScrubbing = false
    private(set) var volume: Double = 100
    /// Whether the floating controls (capsule + overlay title) are shown.
    /// Auto-hide only ever engages during smooth playback; see
    /// `updateIdlePolicy`.
    private(set) var controlsVisible = true

    private var isPointerOverControls = false
    private var idleHideTask: Task<Void, Never>?

    /// Called whenever a displayed value may have changed; the view
    /// re-renders from the view model's public state.
    var onChange: (() -> Void)?
    /// Playback failure detail, forwarded to the coordinator's error chain.
    var onError: ((String) -> Void)?

    init(
        controller: PlayerPlaybackControlling,
        idleHideInterval: TimeInterval = 2.5,
        progressStore: PlaybackProgressStoring? = nil,
        progressKey: String? = nil
    ) {
        self.controller = controller
        self.idleHideInterval = idleHideInterval
        self.progressStore = progressStore
        self.progressKey = progressKey
    }

    // MARK: - Event reduction

    func apply(_ event: PlayerCoreEvent) {
        switch event {
        case .fileLoaded:
            hasLoaded = true
        case .timePosChanged(let time):
            if !isScrubbing {
                currentTime = time
                // mpv ticks ~1/s; one persisted write per ≥5s of movement is
                // plenty for a resume point. Scrubbed positions never reach
                // here, so a drag's intermediate states are not persisted.
                if time - lastPersistedPosition >= 5 {
                    persistProgress(time)
                }
            }
        case .durationChanged(let value):
            duration = max(0, value)
        case .pauseChanged(let paused):
            isPaused = paused
            if paused { persistProgress(currentTime) }
        case .bufferingChanged(let buffering):
            isBuffering = buffering
        case .ended:
            // v1: a clean end leaves the last frame up; the user closes the
            // window or seeks back manually. A finished video is forgotten
            // so a replay starts from the top.
            if let progressStore, let progressKey {
                progressStore.removePosition(forKey: progressKey)
            }
        case .playbackFailed(let detail):
            hasFailed = true
            onError?(detail)
        }
        attemptResumeIfReady()
        state = Self.computeState(hasLoaded: hasLoaded, hasFailed: hasFailed, isPaused: isPaused, isBuffering: isBuffering)
        updateIdlePolicy()
        onChange?()
    }

    static func computeState(hasLoaded: Bool, hasFailed: Bool, isPaused: Bool, isBuffering: Bool) -> State {
        if hasFailed { return .error }
        guard hasLoaded else { return .loading }
        if isBuffering { return .buffering }
        return isPaused ? .paused : .playing
    }

    // MARK: - Resume position

    /// Silent resume, checked after every event until both prerequisites
    /// (file loaded, positive duration) have been seen once. Positions ≤5s
    /// count as "not really started"; ≥95% of the duration count as
    /// finished and the record is dropped so the replay starts from the top.
    private func attemptResumeIfReady() {
        guard !resumeAttempted, hasLoaded, duration > 0,
              let progressStore, let progressKey else { return }
        resumeAttempted = true
        guard let position = progressStore.position(forKey: progressKey) else { return }
        if position >= duration * 0.95 {
            progressStore.removePosition(forKey: progressKey)
        } else if position > 5 {
            controller.seekTo(seconds: position)
        }
    }

    /// Persists `position` as the resume point, or drops the record when
    /// the position says the video is finished. Never writes before a real
    /// duration is known.
    private func persistProgress(_ position: Double) {
        guard duration > 0, let progressStore, let progressKey else { return }
        lastPersistedPosition = position
        if position >= duration * 0.95 {
            progressStore.removePosition(forKey: progressKey)
        } else if position > 5 {
            progressStore.savePosition(position, forKey: progressKey)
        }
    }

    /// Final write, invoked by the window controller just before teardown.
    func persistProgressOnClose() {
        persistProgress(currentTime)
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
        updateIdlePolicy()
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
        updateIdlePolicy()
        onChange?()
    }

    func setVolume(_ newValue: Double) {
        volume = min(max(0, newValue), 100)
        controller.setVolume(volume)
        onChange?()
    }

    /// Arrow-key volume nudge. Counts as user activity so the controls
    /// reveal themselves (and the change is visible) when hidden.
    func adjustVolume(by delta: Double) {
        setVolume(volume + delta)
        noteMouseActivity()
    }

    // MARK: - Idle auto-hide

    /// Auto-hide is only ever allowed during smooth playback: never while
    /// paused/buffering/error, scrubbing, or with the pointer resting on
    /// the capsule.
    private var isIdleHideEligible: Bool {
        state == .playing && !isScrubbing && !isPointerOverControls
    }

    /// The view forwards every pointer movement over the window content:
    /// the controls come back immediately and the idle countdown restarts.
    func noteMouseActivity() {
        idleHideTask?.cancel()
        idleHideTask = nil
        controlsVisible = true
        updateIdlePolicy()
        onChange?()
    }

    /// The view forwards capsule hover so the controls stay up while the
    /// pointer rests on them.
    func setPointerOverControls(_ over: Bool) {
        guard isPointerOverControls != over else { return }
        isPointerOverControls = over
        updateIdlePolicy()
        onChange?()
    }

    /// Single choke point that reconciles `controlsVisible` and the idle
    /// timer with the current inputs; called from every path that can
    /// change them (state reduction, scrubbing, hover, mouse activity).
    private func updateIdlePolicy() {
        guard isIdleHideEligible else {
            idleHideTask?.cancel()
            idleHideTask = nil
            controlsVisible = true
            return
        }
        if idleHideTask == nil && controlsVisible {
            scheduleIdleHide()
        }
    }

    private func scheduleIdleHide() {
        idleHideTask = Task { [weak self, idleHideInterval] in
            try? await Task.sleep(for: .milliseconds(Int(idleHideInterval * 1000)))
            guard !Task.isCancelled, let self else { return }
            self.idleHideTask = nil
            // Re-evaluate: the inputs may have changed while sleeping.
            guard self.isIdleHideEligible else { return }
            self.controlsVisible = false
            self.onChange?()
        }
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
