import Foundation

/// The commands the player UI can issue to a playback engine. Implemented
/// by `MPVPlayerCore`; tests substitute a recorder.
@MainActor
protocol PlayerPlaybackControlling: AnyObject {
    func togglePause()
    func seek(bySeconds seconds: Int)
    func seekTo(seconds: Double)
    func setVolume(_ volume: Double)
    func setSpeed(_ speed: Double)
    /// Selects a subtitle track by mpv track id; nil turns subtitles off.
    func setSubtitle(trackID: Int?)
    /// The engine's current subtitle bottom margin (mpv `sub-margin-y`,
    /// in points), i.e. the rest position subtitles return to when the
    /// controls hide. The view model reads this back once per session
    /// after the file loads and never hard-codes it (mpv's default is
    /// build-dependent).
    var subtitleBottomMarginBaseline: Int { get }
    /// Lifts or lowers the subtitle rendering area by setting the
    /// subtitle bottom margin (in points). Driven by the controls'
    /// visibility: visible = baseline + clearance, hidden = baseline.
    func setSubtitleBottomMargin(_ points: Int)
    /// Grabs the currently displayed frame as raw BGRA (the video-cover
    /// pipeline's write side, TASK-video-thumbnails).
    func captureCurrentFrame() -> BGRAVideoFrame?
}

extension PlayerPlaybackControlling {
    /// Default: no capture. Engines that cannot grab frames (the tests'
    /// fake controller) simply never produce covers.
    func captureCurrentFrame() -> BGRAVideoFrame? { nil }

    /// Default: engines that cannot report a baseline (the tests' fake
    /// controller) treat 0 as the subtitle rest position.
    var subtitleBottomMarginBaseline: Int { 0 }

    /// Default: no subtitle-margin control. Engines without subtitle
    /// lifting simply ignore the command.
    func setSubtitleBottomMargin(_ points: Int) {}
}

/// The file-identity facts a captured cover's cache key is computed from,
/// handed over by the coordinator at session build (TASK-video-thumbnails:
/// the player writes under the same key contract the home cards read).
struct ThumbnailFileFacts {
    let sourceID: String
    let path: String
    let fileSize: Int64
    let modified: Date?
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
    /// Video-cover write side (TASK-video-thumbnails): where captured
    /// frames go, plus the file facts the cover key is computed from.
    /// Either nil = covers disabled (test fakes, sessions without a source
    /// id) and captures are skipped entirely.
    private let thumbnailWriter: VideoThumbnailWriter?
    private let thumbnailFacts: ThumbnailFileFacts?

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
    /// Codec-chip facts for the current video; nil until the track's first
    /// reconfig lands.
    private(set) var videoInfo: VideoTrackInfo?
    /// Whether the current file carries a video track, mirrored from the
    /// core's `.videoTrackPresenceChanged` events. Defaults true so an
    /// ordinary video open never flashes the audio shell in the gap
    /// before the track-list lands; audio sessions flip to false once.
    private(set) var hasVideoTrack = true
    /// While true, incoming time-pos updates are ignored so the slider the
    /// user is dragging does not fight playback position updates.
    private(set) var isScrubbing = false
    private(set) var volume: Double = 100
    /// Playback rate multiplier; 1 = normal speed.
    private(set) var speed: Double = 1
    /// Subtitle tracks of the current file (empty when it has none),
    /// mirrored from the core's `.subtitleTracksChanged` events; the core
    /// re-emits on every file switch, which is what resets the list.
    private(set) var subtitleTracks: [SubtitleTrack] = []
    /// The selected subtitle track's mpv id; nil = subtitles off.
    private(set) var selectedSubtitleTrackID: Int?
    /// Whether the floating controls (capsule + overlay title) are shown.
    /// Auto-hide only ever engages during smooth playback; see
    /// `updateIdlePolicy`.
    private(set) var controlsVisible = true {
        didSet { applySubtitleMargin() }
    }
    /// Distance from the window content's bottom edge up to the controls
    /// capsule's top edge (in points), measured by the window
    /// controller's layout pass and fed in here. The view model never
    /// hard-codes capsule geometry; it only consumes this number.
    var subtitleClearance: Double = 0 {
        didSet { applySubtitleMargin() }
    }
    /// Failure detail behind `.error`, rendered by the central failure
    /// placeholder; nil otherwise.
    private(set) var errorDetail: String?
    /// Clean end-of-file reached: playback finished and the session is
    /// parked on the last frame. Set by `.ended`, cleared by a fresh file
    /// load or any user seek — afterwards a play intent is an ordinary
    /// unpause again.
    private var endedAtCleanEOF = false
    /// Whether the coordinator parked this clean EOF with no Up-Next
    /// auto-advance pending (which step follows an EOF is coordinator
    /// knowledge). Fed back through `markParkedWithNoPendingAdvance()`;
    /// only together with `endedAtCleanEOF` does a play intent replay
    /// from the top (TASK-player-ux-trio Step 1).
    private var hasNoPendingAdvance = false

    private var isPointerOverControls = false
    private var idleHideTask: Task<Void, Never>?
    /// mpv's `sub-margin-y` read back once per session after the file
    /// loads: the rest position subtitles return to when the controls
    /// hide. Never hard-coded — mpv's default is build-dependent.
    private var subtitleMarginBaseline = 0
    /// False until the baseline read-back has happened; no margin is
    /// written to the engine before that.
    private var subtitleBaselineReady = false
    /// The last margin handed to the engine. Layout and render passes
    /// recompute the margin constantly; an unchanged value is never
    /// re-sent.
    private var lastAppliedSubtitleMargin: Int?

    /// Called whenever a displayed value may have changed; the view
    /// re-renders from the view model's public state.
    var onChange: (() -> Void)?
    /// Playback failure detail, forwarded to the coordinator's error chain.
    var onError: ((String) -> Void)?
    /// Clean-EOF hook; the coordinator uses it to auto-advance the
    /// playlist. Fired after the finished video's resume record is dropped.
    var onEnded: (() -> Void)?

    init(
        controller: PlayerPlaybackControlling,
        idleHideInterval: TimeInterval = 2.5,
        progressStore: PlaybackProgressStoring? = nil,
        progressKey: String? = nil,
        thumbnailWriter: VideoThumbnailWriter? = nil,
        thumbnailFacts: ThumbnailFileFacts? = nil
    ) {
        self.controller = controller
        self.idleHideInterval = idleHideInterval
        self.progressStore = progressStore
        self.progressKey = progressKey
        self.thumbnailWriter = thumbnailWriter
        self.thumbnailFacts = thumbnailFacts
    }

    // MARK: - Event reduction

    func apply(_ event: PlayerCoreEvent) {
        switch event {
        case .fileLoaded:
            hasLoaded = true
            // A fresh file resets the EOF park: the previous video's
            // end says nothing about the new one.
            endedAtCleanEOF = false
            hasNoPendingAdvance = false
            readSubtitleMarginBaseline()
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
        case .videoInfoChanged(let info):
            videoInfo = info
        case .videoTrackPresenceChanged(let hasVideo):
            hasVideoTrack = hasVideo
        case .subtitleTracksChanged(let tracks, let selectedID):
            subtitleTracks = tracks
            selectedSubtitleTrackID = selectedID
        case .ended:
            // A finished video is forgotten so a replay starts from the
            // top; the coordinator then decides whether to auto-advance
            // (the last video in the queue keeps the last frame up).
            endedAtCleanEOF = true
            if let progressStore, let progressKey {
                progressStore.removePosition(forKey: progressKey)
            }
            onEnded?()
        case .playbackFailed(let detail):
            hasFailed = true
            errorDetail = detail
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
    /// duration is known. A real save also captures the current frame for
    /// the video-cover pipeline — deferred to the next main-actor turn,
    /// because the capture polls mpv events and must never nest inside the
    /// event drain this call may be running in.
    private func persistProgress(_ position: Double, captureDeferred: Bool = true) {
        guard duration > 0, let progressStore, let progressKey else { return }
        lastPersistedPosition = position
        if position >= duration * 0.95 {
            progressStore.removePosition(forKey: progressKey)
        } else if position > 5 {
            progressStore.savePosition(position, forKey: progressKey, duration: duration)
            if captureDeferred {
                Task { [weak self] in self?.captureThumbnail() }
            }
        }
    }

    /// Final write, invoked by the window controller just before teardown
    /// (window close, track-swap install). The capture runs synchronously
    /// here — the caller tears the render context and mpv handle down right
    /// after this returns — which is safe because this call site is never
    /// inside the event drain.
    func persistProgressOnClose() {
        persistProgress(currentTime, captureDeferred: false)
        captureThumbnail()
    }

    /// Grabs the current frame and hands it to the cover writer together
    /// with the session's file facts. Every miss is silent: a nil capture
    /// or missing writer/facts just means the card keeps its film icon.
    private func captureThumbnail() {
        guard let thumbnailWriter, let thumbnailFacts, hasVideoTrack else { return }
        guard let frame = controller.captureCurrentFrame() else { return }
        thumbnailWriter.store(
            frame: frame,
            sourceID: thumbnailFacts.sourceID,
            path: thumbnailFacts.path,
            fileSize: thumbnailFacts.fileSize,
            modified: thumbnailFacts.modified
        )
    }

    // MARK: - User intents

    func togglePause() {
        // Parked at a clean EOF with no Up-Next jump pending, the
        // transport button and Space mean "watch it again", not
        // "unpause at the end of the file" (mpv would sit there).
        if endedAtCleanEOF && hasNoPendingAdvance {
            replayFromStart()
            return
        }
        controller.togglePause()
    }

    /// Armed by the coordinator when a clean EOF has nowhere to
    /// auto-advance: the queue-end park. While a countdown is pending or
    /// the mode replays/wraps, this is never called and the transport
    /// keeps its plain unpause behavior.
    func markParkedWithNoPendingAdvance() {
        hasNoPendingAdvance = true
    }

    /// Relative seek, used by the arrow keys. Any user seek disarms the
    /// EOF park: the user took the wheel, so a later play intent is an
    /// ordinary unpause again.
    func seekBy(seconds: Int) {
        endedAtCleanEOF = false
        hasNoPendingAdvance = false
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
        endedAtCleanEOF = false
        hasNoPendingAdvance = false
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

    /// Playback rate; only the popover's offered values reach here, so no
    /// clamping beyond sanity.
    func setSpeed(_ newValue: Double) {
        speed = min(max(0.25, newValue), 4)
        controller.setSpeed(speed)
        onChange?()
    }

    /// Subtitle picker selection; nil turns subtitles off. The core
    /// confirms asynchronously via `.subtitleTracksChanged`, so this only
    /// forwards the command — no optimistic state.
    func setSubtitle(trackID: Int?) {
        controller.setSubtitle(trackID: trackID)
    }

    /// Restarts the current video from the top (repeat-one mode, and the
    /// EOF-replay play intent): mpv parks paused at EOF under keep-open,
    /// so seek back and unpause. The replay itself disarms the EOF park.
    func replayFromStart() {
        endedAtCleanEOF = false
        hasNoPendingAdvance = false
        controller.seekTo(seconds: 0)
        if isPaused {
            controller.togglePause()
        }
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

    // MARK: - Subtitle clearance

    /// Breathing room between a lifted subtitle line and the capsule's
    /// top edge, on top of the measured clearance.
    private static let subtitleCapsuleGap = 8

    /// One-shot baseline read-back (TASK-subtitle-clearance), run on the
    /// session's first file-loaded event: the rest position is whatever
    /// mpv reports, never an assumed 0.
    private func readSubtitleMarginBaseline() {
        guard !subtitleBaselineReady else { return }
        subtitleBaselineReady = true
        subtitleMarginBaseline = controller.subtitleBottomMarginBaseline
        applySubtitleMargin()
    }

    /// Single choke point for the subtitle bottom margin. Called from
    /// every input that can change the outcome (`controlsVisible`'s
    /// didSet and `subtitleClearance`'s didSet); the same computed value
    /// is never written twice.
    private func applySubtitleMargin() {
        guard subtitleBaselineReady else { return }
        let margin = controlsVisible
            ? subtitleMarginBaseline + Int(ceil(subtitleClearance)) + Self.subtitleCapsuleGap
            : subtitleMarginBaseline
        guard margin != lastAppliedSubtitleMargin else { return }
        lastAppliedSubtitleMargin = margin
        controller.setSubtitleBottomMargin(margin)
    }

    // MARK: - Display projections

    var isProgressEnabled: Bool {
        hasLoaded && !hasFailed
    }

    /// True while the subtitle button should be tappable: the current file
    /// carries at least one subtitle track.
    var hasSubtitleTracks: Bool {
        !subtitleTracks.isEmpty
    }

    /// True while an audio-only session should show the static shell
    /// (symbol + file name) instead of the bare black video surface
    /// (TASK-audio-playback decision 4). Only the steady states belong to
    /// the shell: loading/buffering keep the spinner overlay, errors the
    /// failure placeholder.
    var showsAudioShell: Bool {
        !hasVideoTrack && (state == .playing || state == .paused)
    }

    /// True while the transport button should offer pausing.
    var showsPauseButton: Bool {
        state == .playing || state == .buffering
    }

    /// Elapsed readout for the capsule's lower-left timecode.
    var elapsedText: String {
        Self.formatTime(currentTime)
    }

    /// Total-length readout for the capsule's lower-right timecode.
    var totalText: String {
        Self.formatTime(duration)
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
