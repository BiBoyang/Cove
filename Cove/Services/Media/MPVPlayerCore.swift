import Foundation
import QuartzCore
import TraceKit

/// Errors while bringing up an mpv playback session.
enum PlayerCoreError: LocalizedError {
    case createFailed
    case initializeFailed(String)
    case rendererUnavailable

    var errorDescription: String? {
        switch self {
        case .createFailed:
            return "mpv handle creation failed."
        case .initializeFailed(let detail):
            return "mpv initialization failed: \(detail)"
        case .rendererUnavailable:
            return "mpv rejected the OpenGL render API."
        }
    }
}

/// Events forwarded from mpv to the player view model. Property replies
/// arrive on the main actor through the core's event drain; mpv also sends
/// each observed property's initial value right after observation starts.
enum PlayerCoreEvent {
    case fileLoaded
    case timePosChanged(Double)
    case durationChanged(Double)
    case pauseChanged(Bool)
    /// mpv's `paused-for-cache`: playback is stalled waiting for the
    /// demuxer cache to refill (the v1 buffering signal).
    case bufferingChanged(Bool)
    /// Video parameters settled after a (re)config; carries the facts the
    /// codec chips render.
    case videoInfoChanged(VideoTrackInfo)
    /// Subtitle track list or selection changed. Carries the full current
    /// list (empty when the file has no subtitle tracks) plus the selected
    /// track's id (nil = subtitles off). Sourced from the observed
    /// `track-list` property, so initial load, `setSubtitle` switches and
    /// file switches (which reset the list) all flow through here; mpv
    /// dedups the observation by value, so only real changes arrive.
    case subtitleTracksChanged([SubtitleTrack], selectedID: Int?)
    /// Whether the current file carries a video track, sourced from the
    /// same observed `track-list`. False = audio-only session, which the
    /// player turns into the static shell (TASK-audio-playback). Emitted
    /// once the real list lands (the empty pre-load list is idle noise)
    /// and only on actual changes afterwards.
    case videoTrackPresenceChanged(Bool)
    /// Clean end of file.
    case ended
    /// Playback died with an mpv error (end-file with a negative error code).
    case playbackFailed(String)
}

/// One video track's display-relevant facts, rendered as the player's
/// codec chips. Pure values only (tokens: no platform UI types past the
/// view model boundary).
struct VideoTrackInfo: Equatable, Sendable {
    /// True while a hardware decoder is active (mpv `hwdec-current`).
    let hardwareDecoded: Bool
    /// Codec family, e.g. "h264", "hevc" (mpv `video-format`).
    let codec: String
    let width: Int
    let height: Int
    /// Instantaneous video bitrate in bits per second; 0 when unknown.
    let bitrate: Double
}

/// One subtitle track as listed in the player's subtitle picker. Pure
/// values only (same boundary rule as `VideoTrackInfo`).
struct SubtitleTrack: Equatable, Sendable {
    /// mpv track id (`track-list/N/id`); the value the `sid` property takes.
    let id: Int
    /// Title metadata carried by the file; nil when the track has none.
    let title: String?
    /// ISO language code, e.g. "eng"; nil when the track has none.
    let lang: String?
    /// Codec name, e.g. "subrip" or "ass"; empty when mpv reports none yet.
    let codec: String
    /// mpv's `external` flag: mounted from a sidecar file (`sub-add`) rather
    /// than muxed into the container. Drives the picker's 「外挂」 marker.
    let external: Bool
    /// Picker row label; see `displayName(title:lang:codec:position:external:)`.
    let displayName: String
}

/// Raw facts of one `track-list` entry, any track type. The seam between
/// the mpv node walk (needs a live handle, not unit-testable) and the
/// pure picker logic on `SubtitleTrack`.
struct MPVTrackEntry: Equatable, Sendable {
    let id: Int
    /// mpv stream type: "video", "audio" or "sub".
    let type: String
    let title: String?
    let lang: String?
    let codec: String?
    /// mpv's `selected` flag: this track is the current pick of its type.
    let isSelected: Bool
    /// mpv's `external` flag: added from an external file (`sub-add`) instead
    /// of being muxed into the container.
    let isExternal: Bool
}

extension MPVTrackEntry {
    /// Whether a raw track-list carries at least one video track — the
    /// audio-shell signal (TASK-audio-playback, seam B). Embedded album
    /// art counts as video because mpv renders it into the video area,
    /// which is exactly what the user then sees.
    static func hasVideoTrack(trackList entries: [MPVTrackEntry]) -> Bool {
        entries.contains { $0.type == "video" }
    }
}

extension SubtitleTrack {
    /// Filters subtitle tracks out of a raw track-list and builds the
    /// picker models; also derives the selected track id (nil = subtitles
    /// off). The app never sets `secondary-sid`, so at most one subtitle
    /// track is selected; the first selected one wins defensively.
    static func parse(trackList entries: [MPVTrackEntry]) -> (tracks: [SubtitleTrack], selectedID: Int?) {
        var tracks: [SubtitleTrack] = []
        var selectedID: Int?
        for entry in entries where entry.type == "sub" {
            if entry.isSelected, selectedID == nil {
                selectedID = entry.id
            }
            tracks.append(SubtitleTrack(
                id: entry.id,
                title: entry.title,
                lang: entry.lang,
                codec: entry.codec ?? "",
                external: entry.isExternal,
                displayName: displayName(
                    title: entry.title,
                    lang: entry.lang,
                    codec: entry.codec,
                    position: tracks.count + 1,
                    external: entry.isExternal
                )
            ))
        }
        return (tracks, selectedID)
    }

    /// Row-label fallback chain: title, then language code, then codec,
    /// then a position-based placeholder, so metadata-less tracks never
    /// render as an empty row. Empty strings count as missing. External
    /// tracks get a 「外挂」 suffix so the picker can tell sidecars apart
    /// from muxed tracks with identical metadata.
    static func displayName(title: String?, lang: String?, codec: String?, position: Int, external: Bool = false) -> String {
        let base: String
        if let title, !title.isEmpty {
            base = title
        } else if let lang, !lang.isEmpty {
            base = lang
        } else if let codec, !codec.isEmpty {
            base = codec
        } else {
            base = "字幕 \(position)"
        }
        return external ? "\(base)（外挂）" : base
    }
}

/// Owns one mpv handle and its OpenGL render context for a single video.
///
/// Everything in this class runs on the main actor. mpv itself is
/// thread-safe internally: commands issued here are non-blocking, events
/// arrive via the wakeup callback (hopped to the main queue), and all
/// stream IO happens on mpv's demuxer thread inside `VideoStreamBridge`.
/// The only hard ordering rule: the render context must be freed before
/// `mpv_terminate_destroy`.
@MainActor
final class MPVPlayerCore {
    /// The layer the player view hosts; draws mpv frames as they arrive.
    let videoLayer = MPVVideoLayer()

    private let logger = TraceLogger(category: "Player")
    private let bridge: VideoStreamBridge
    private var handle: OpaquePointer?
    private var renderer: MPVGLRenderer?
    /// Hop target for mpv's wakeup callback; see below.
    private let wakeupBox = MPVWakeupBox()
    private var isShutdown = false
    /// Previous `eof-reached` value, for rising-edge detection of the
    /// clean-EOF signal (see `handlePropertyChange`).
    private var wasAtEOF = false
    /// Last emitted video info; reconfig fires several times per track
    /// (audio switches, format probes), so only real changes propagate.
    private var lastVideoTrackInfo: VideoTrackInfo?
    /// Subtitle tracks of the current file (empty when it has none) and
    /// the selected track id (nil = subtitles off). Mirror of the last
    /// emitted `.subtitleTracksChanged` event; because both come from the
    /// observed `track-list`, a file switch resets them automatically —
    /// the new file's list simply replaces the previous one.
    private(set) var subtitleTracks: [SubtitleTrack] = []
    private(set) var selectedSubtitleTrackID: Int?
    /// Last emitted video-track presence; nil until a real (non-empty)
    /// track-list has been seen, so the audio file's first list always
    /// reports even though its `false` matches the idle default.
    private var lastHasVideoTrack: Bool?

    /// Property-observation reply IDs, matched against `reply_userdata` in
    /// the drain loop.
    private enum ObservedProperty {
        static let timePos: UInt64 = 1
        static let duration: UInt64 = 2
        static let pause: UInt64 = 3
        static let pausedForCache: UInt64 = 4
        static let eofReached: UInt64 = 5
        static let trackList: UInt64 = 6
    }

    /// Reply-userdata space for `screenshot-raw` commands, clear of the
    /// property-observation IDs above; bumped per capture, so two captures
    /// issued within one main-actor turn (a persist tick racing a close)
    /// can never consume each other's reply.
    private static let captureReplyBase: UInt64 = 0xC0FFEE
    /// Rescue drive cadence and hard budget: ~100ms per beat, at most ~2s
    /// total (2026-09-15 hang fix, R2).
    private static let captureRescueBeatMillis = 100
    private static let captureRescueMaxBeats = 20
    /// Frames parsed out of `MPV_EVENT_COMMAND_REPLY` by the event drain,
    /// keyed by reply userdata and picked up by their capture call.
    private var capturedFrames: [UInt64: BGRAVideoFrame] = [:]
    /// Capture replies whose waiter already timed out. The drain drops a
    /// late reply for these instead of parking its BGRA frame in
    /// `capturedFrames` forever (reply IDs only move forward, so nobody
    /// would ever read it). Each ID enters at most once and is consumed
    /// at most once — the set stays bounded.
    private var abandonedCaptureIDs = Set<UInt64>()
    /// Next free screenshot-raw reply ID.
    private var nextCaptureReplyID: UInt64 = MPVPlayerCore.captureReplyBase
    /// The in-flight rescue drive started by a timed-out capture. Awaited
    /// by `waitForCaptureRescue()` so a teardown never lands while the
    /// core is still being unwedged.
    private var rescueTask: Task<Bool, Never>?
    /// Whether the most recent `captureCurrentFrame` timed out: its reply
    /// is still pending and the rescue drive is unwedging the core. The
    /// close path reads this to defer `shutdown()` past the rescue.
    private(set) var captureDidTimeOut = false
    /// Nested-capture guard: a capture polls the event queue, and a capture
    /// re-entered from inside that poll's drain would call wait_event while
    /// the outer loop still holds its (about-to-die) borrowed event.
    private var isCapturingFrame = false

    /// Receives playback events on the main actor; wired to the view model
    /// by the player coordinator.
    var onEvent: ((PlayerCoreEvent) -> Void)?

    init(bridge: VideoStreamBridge) throws {
        self.bridge = bridge
        guard let handle = mpv_create() else {
            throw PlayerCoreError.createFailed
        }
        self.handle = handle

        // config=no keeps mpv away from ~/.config/mpv and ~/.cache, which
        // the app sandbox would deny anyway.
        mpv_set_option_string(handle, "config", "no")
        // Render API owns the video output. Without this mpv spins up its
        // default VO (gpu-next -> Vulkan on this build), whose init crashes
        // in libplacebo — and which would fight the render context anyway.
        mpv_set_option_string(handle, "vo", "libmpv")
        // VideoToolbox first, automatic fallback to software decoding.
        mpv_set_option_string(handle, "hwdec", "auto-safe")
        // vd_lavc direct rendering deadlocks this mpv build's render-API VO
        // on software-decoded content (reproduced locally with an MPEG-4 SP
        // file: vd allocates a host-cached DR image, then vo/libmpv never
        // reconfigs — video-reconfig/playback-restart never fire, black
        // window forever). hwdec content (h264/hevc via VideoToolbox) never
        // touches DR. Off costs one memcpy per software-decoded frame.
        mpv_set_option_string(handle, "vd-lavc-dr", "no")
        // Buffering lives entirely in mpv's own cache (videos never enter
        // CacheKit); network streams get it explicitly.
        mpv_set_option_string(handle, "cache", "yes")
        // The app draws its own chrome over the render layer, so mpv's
        // native OSD is disabled at the master switch: osd-level 0 kills
        // osd-bar and osd-msg elements alike, which is what leaked the
        // orange timecode readout onto the frame (audit BUG-3).
        mpv_set_option_string(handle, "osd-level", "0")
        // Park on the last frame at clean EOF instead of unloading the
        // file. Without this, EOF leaves mpv idle and every later seek
        // command (the user dragging the slider back after cancelling the
        // up-next countdown) fails with "nothing loaded". Cost: a clean
        // EOF no longer fires MPV_EVENT_END_FILE — the eof signal comes
        // from the observed eof-reached property instead.
        mpv_set_option_string(handle, "keep-open", "yes")

        let initResult = mpv_initialize(handle)
        guard initResult >= 0 else {
            let detail = String(cString: mpv_error_string(initResult))
            mpv_terminate_destroy(handle)
            self.handle = nil
            throw PlayerCoreError.initializeFailed(detail)
        }
        bridge.register(handle: handle)

        wakeupBox.handler = { [weak self] in
            MainActor.assumeIsolated { self?.drainEvents() }
        }
        mpv_set_wakeup_callback(handle, coveMPVWakeup, Unmanaged.passUnretained(wakeupBox).toOpaque())
        mpv_request_log_messages(handle, "warn")
        observeProperties()

        guard let renderer = MPVGLRenderer(mpvHandle: UnsafeMutableRawPointer(handle), updateHandler: { [videoLayer] in
            MainActor.assumeIsolated { videoLayer.mpvNeedsDisplay() }
        }) else {
            mpv_terminate_destroy(handle)
            self.handle = nil
            throw PlayerCoreError.rendererUnavailable
        }
        videoLayer.renderer = renderer
        self.renderer = renderer
    }

    /// Starts playback of the bridge's stream.
    func load() {
        // Debug-level milestone: pairs with the FILE_LOADED /
        // PLAYBACK_RESTART events in drainEvents to show how far startup got.
        logger.debug("loadfile issued")
        command(["loadfile", bridge.uri])
    }

    func togglePause() {
        command(["cycle", "pause"])
    }

    /// Relative seek in seconds, using mpv's built-in demuxer seek.
    func seek(bySeconds seconds: Int) {
        command(["seek", String(seconds)])
    }

    /// Absolute seek in seconds, for the progress slider.
    func seekTo(seconds: Double) {
        command(["seek", String(seconds), "absolute"])
    }

    /// Volume on mpv's 0-100 scale.
    func setVolume(_ volume: Double) {
        // The command is "set", not "set_property": mpv's C API function
        // names (mpv_set_property) and its command names are different
        // namespaces — no command uses snake_case. A wrong command name
        // fails silently here (command() only logs), which is how a dead
        // volume slider shipped in the Step 2 review build.
        command(["set", "volume", String(volume)])
    }

    /// Playback rate multiplier (1 = normal).
    func setSpeed(_ speed: Double) {
        command(["set", "speed", String(speed)])
    }

    /// Selects a subtitle track by mpv track id; nil disables subtitles
    /// (`sid=no`). The switch is confirmed asynchronously: mpv re-notifies
    /// the observed track-list, which updates `selectedSubtitleTrackID`
    /// and emits `.subtitleTracksChanged` — no optimistic state here.
    func setSubtitle(trackID: Int?) {
        if let trackID {
            command(["set", "sid", String(trackID)])
        } else {
            command(["set", "sid", "no"])
        }
    }

    /// The engine's current subtitle bottom margin (mpv `sub-margin-y`,
    /// in points above the subtitle position) — the session's rest
    /// position, read back once by the view model after the file loads.
    /// Read failures degrade to 0 with a debug log: mpv's default is
    /// build-dependent, so callers must never assume a value.
    var subtitleBottomMarginBaseline: Int {
        guard let handle, !isShutdown else { return 0 }
        var value = Int64()
        let status = mpv_get_property(handle, "sub-margin-y", MPV_FORMAT_INT64, &value)
        guard status >= 0 else {
            logger.debug("sub-margin-y baseline read failed; falling back to 0")
            return 0
        }
        return Int(value)
    }

    /// Sets mpv's `sub-margin-y` (in points), lifting or lowering the
    /// subtitle rendering area at runtime. libass re-flows the lines on
    /// the next frame, so no track reload is needed.
    func setSubtitleBottomMargin(_ points: Int) {
        command(["set", "sub-margin-y", String(points)])
    }

    /// Mounts an already-staged local subtitle file as an external track.
    /// mpv accepts this whether the video has finished loading (track added
    /// and switched to) or is still loading (track added and pre-selected
    /// at playback init); commands are processed in arrival order, so an
    /// add issued after `load()` always follows the loadfile. Default
    /// `sub-add` flags are `select`, so the new track becomes the displayed
    /// one — the external-wins convention. Failures only log here.
    func addExternalSubtitle(path: String) {
        command(["sub-add", path])
    }

    /// Grabs the currently displayed frame as raw BGRA via `screenshot-raw`
    /// (the video-cover pipeline's write side). Nil on any failure — a
    /// missing cover degrades to the film icon, never an error surface.
    ///
    /// mpv services the command on the render context's dispatch queue, and
    /// the only drain is `mpv_render_context_update()` on a thread holding
    /// a current GL context. During playback the layer's own draws do it
    /// (the shim's render path ends in an update), but a paused session
    /// never redraws, so this poll drives `videoLayer.drainRenderDispatch`
    /// itself and picks the reply up through the regular event drain.
    ///
    /// Synchronous and bounded to 250ms by contract: it runs on the main
    /// actor at progress-persistence points, and the window-close point
    /// must finish the capture before the caller tears the render context
    /// and mpv handle down. The bound is what keeps that off the main
    /// thread's throat — a serviced reply lands within the first iteration
    /// (one render-context update). On timeout it degrades to nil and
    /// hands the wedge to the bounded rescue drive (`startCaptureRescue`)
    /// instead of ever blocking past the bound.
    func captureCurrentFrame() -> BGRAVideoFrame? {
        guard !isShutdown, !isCapturingFrame else { return nil }
        isCapturingFrame = true
        captureDidTimeOut = false
        defer { isCapturingFrame = false }

        let replyID = nextCaptureReplyID
        nextCaptureReplyID += 1
        guard issueCaptureCommand(replyID: replyID) >= 0 else {
            logger.error("screenshot-raw issue failed")
            return nil
        }
        let deadline = ContinuousClock.now + .milliseconds(250)
        while ContinuousClock.now < deadline {
            videoLayer.drainRenderDispatch()
            drainEvents()
            if let frame = capturedFrames.removeValue(forKey: replyID) {
                return frame
            }
            Thread.sleep(forTimeInterval: 0.004)
        }
        // Timed out: the reply can still arrive later, and storing it
        // would park its BGRA payload (1080p ≈ 8MB / 4K ≈ 33MB) in
        // `capturedFrames` forever. Record the ID; the drain drops the
        // late reply when (if) it lands. Dropping the reply does not fix
        // the wedge itself — mpv core is stuck inside the screenshot,
        // waiting on a VO render request only this thread can service — so
        // start the bounded rescue drive (2026-09-15 hang: a wedged core
        // deadlocks every later command on mpv's dispatch lock).
        abandonedCaptureIDs.insert(replyID)
        captureDidTimeOut = true
        logger.notice("screenshot-raw timed out; no cover captured")
        startCaptureRescue(replyID: replyID)
        return nil
    }

    /// One rescue beat: service the VO render request the wedged core is
    /// waiting on, then pump the event queue so the late reply, once it
    /// finally lands, is consumed out of `abandonedCaptureIDs`. Returns
    /// false when the drive is over — reply landed, core shut down — and
    /// the loop must stop touching the render context.
    private func rescueStep(replyID: UInt64) -> Bool {
        guard !isShutdown else { return false }
        videoLayer.drainRenderDispatch()
        drainEvents()
        return abandonedCaptureIDs.contains(replyID)
    }

    /// Starts the bounded rescue drive for a capture whose 250ms wait
    /// timed out: one beat every ~100ms for at most ~2s, stopping the
    /// moment the late reply lands. Checkpoints `isShutdown` every beat,
    /// so a shutdown mid-rescue stops the drive before it can service a
    /// render request for a context that is being torn down.
    private func startCaptureRescue(replyID: UInt64) {
        rescueTask?.cancel()
        rescueTask = Task { [weak self] in
            guard let self else { return false }
            let exhausted = await Self.runCaptureRescue(maxBeats: Self.captureRescueMaxBeats) {
                try? await Task.sleep(for: .milliseconds(Self.captureRescueBeatMillis))
            } step: {
                // Cross-actor hop: the closure is @Sendable, the loop is
                // not main-actor-isolated.
                await self.rescueStep(replyID: replyID)
            }
            if exhausted {
                logger.notice("screenshot-raw rescue exhausted; the mpv core may stay wedged")
            }
            return exhausted
        }
    }

    /// Suspends until the in-flight rescue drive finishes. Bounded by
    /// construction (~2s), so the close path can defer `shutdown()` to
    /// after it instead of joining mpv's threads while the core is still
    /// wedged inside the screenshot.
    func waitForCaptureRescue() async {
        _ = await rescueTask?.value
    }

    /// The rescue loop reduced to its testable skeleton: each beat pauses,
    /// then `step` reports whether the late capture reply is still pending.
    /// Stops as soon as `step` says the reply landed (or the core shut
    /// down), or after `maxBeats` beats either way. Returns true when the
    /// beat budget was exhausted with the reply still pending. Both
    /// closures are injected so the two stop states are unit-testable
    /// without an mpv handle and without real time passing.
    nonisolated static func runCaptureRescue(
        maxBeats: Int,
        beat: @escaping @Sendable () async -> Void,
        step: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        var beats = 0
        while beats < maxBeats {
            await beat()
            if Task.isCancelled { return false }
            beats += 1
            if !(await step()) { return false }
        }
        return true
    }

    /// Issues `screenshot-raw video bgra` as a node command under `replyID`.
    /// Both arguments are OPT_CHOICE properties and take the string
    /// spellings only (integer nodes are rejected). mpv duplicates the node
    /// tree when enqueueing, so the C memory only has to live for this call.
    private func issueCaptureCommand(replyID: UInt64) -> Int32 {
        guard let handle, !isShutdown else { return -1 }
        let cStrings: [UnsafeMutablePointer<CChar>?] =
            (["screenshot-raw", "video", "bgra"] as [String]).map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var argNodes: [mpv_node] = cStrings.compactMap { pointer in
            guard let pointer else { return nil }
            var node = mpv_node()
            node.format = MPV_FORMAT_STRING
            node.u.string = pointer
            return node
        }
        return argNodes.withUnsafeMutableBufferPointer { argBuffer in
            var argList = mpv_node_list()
            argList.num = Int32(argBuffer.count)
            argList.values = argBuffer.baseAddress
            argList.keys = nil
            return withUnsafeMutablePointer(to: &argList) { argListPointer in
                var commandNode = mpv_node()
                commandNode.format = MPV_FORMAT_NODE_ARRAY
                commandNode.u.list = argListPointer
                return withUnsafeMutablePointer(to: &commandNode) { commandPointer in
                    mpv_command_node_async(handle, replyID, commandPointer)
                }
            }
        }
    }

    /// Pure seam: one `screenshot-raw` reply node (a NODE_MAP with `w` /
    /// `h` / `stride` / `format` / `data`) → a BGRA frame with the bytes
    /// copied out. The node memory is event-owned — dead at the next
    /// `mpv_wait_event` — so the byte array is copied here, synchronously
    /// at the drain site. Nil on anything that cannot describe a real BGRA
    /// frame (wrong pixel format, degenerate sizes, a buffer shorter than
    /// stride × height). Internal for the synthetic-node unit tests.
    /// `nonisolated`: pure function over the node, no core state.
    nonisolated static func bgraFrame(fromScreenshotReply node: mpv_node) -> BGRAVideoFrame? {
        guard node.format == MPV_FORMAT_NODE_MAP,
              let list = node.u.list,
              list.pointee.num > 0,
              let keys = list.pointee.keys,
              let values = list.pointee.values else { return nil }
        var width = 0
        var height = 0
        var stride = 0
        var format: String?
        var data: Data?
        for index in 0..<Int(list.pointee.num) {
            guard let key = keys[index] else { continue }
            let value = values[index]
            switch String(cString: key) {
            case "w":
                if value.format == MPV_FORMAT_INT64 { width = Int(value.u.int64) }
            case "h":
                if value.format == MPV_FORMAT_INT64 { height = Int(value.u.int64) }
            case "stride":
                if value.format == MPV_FORMAT_INT64 { stride = Int(value.u.int64) }
            case "format":
                format = nodeString(value)
            case "data":
                // The byte array dies with the event; own a copy now.
                if value.format == MPV_FORMAT_BYTE_ARRAY, let byteArray = value.u.ba {
                    data = Data(bytes: byteArray.pointee.data, count: byteArray.pointee.size)
                }
            default:
                break
            }
        }
        guard format == "bgra",
              width > 0, height > 0, stride > 0,
              let data, data.count >= stride * height else { return nil }
        return BGRAVideoFrame(data: data, width: width, height: height, stride: stride)
    }

    /// Whether a `screenshot-raw` reply may store its frame: replies for
    /// captures whose wait already timed out are consumed here (dropped),
    /// keeping their BGRA payload out of `capturedFrames`. Static over an
    /// `inout` set — the exact consume-once rule the drain applies — so
    /// the rule is unit-testable without an mpv handle.
    nonisolated static func shouldStoreCaptureReply(
        replyID: UInt64, abandonedCaptureIDs: inout Set<UInt64>
    ) -> Bool {
        abandonedCaptureIDs.remove(replyID) == nil
    }

    /// Observes the properties the player UI reads. Replies (including each
    /// property's initial value) arrive as MPV_EVENT_PROPERTY_CHANGE in the
    /// drain loop, distinguished by `reply_userdata`.
    private func observeProperties() {
        guard let handle else { return }
        mpv_observe_property(handle, ObservedProperty.timePos, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, ObservedProperty.duration, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, ObservedProperty.pause, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, ObservedProperty.pausedForCache, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, ObservedProperty.eofReached, "eof-reached", MPV_FORMAT_FLAG)
        // track-list as NODE: one observation covers the whole subtitle
        // lifecycle — the list becomes reliable at file-loaded, `set sid`
        // switches re-notify it (mpv fires TRACK_SWITCHED), and a file
        // switch replaces it. mpv dedups observed values, so noisier
        // events that also touch track-list (e.g. reconfig) cost nothing.
        mpv_observe_property(handle, ObservedProperty.trackList, "track-list", MPV_FORMAT_NODE)
    }

    /// Snapshots the codec-chip facts once a video track is configured.
    /// Nil while no video is selected (properties missing or zero-sized).
    private func readVideoTrackInfo() -> VideoTrackInfo? {
        guard handle != nil else { return nil }
        guard let codec = readStringProperty("video-format"), !codec.isEmpty else { return nil }
        let width = readIntProperty("width")
        let height = readIntProperty("height")
        guard width > 0, height > 0 else { return nil }
        let hwdec = readStringProperty("hwdec-current") ?? ""
        return VideoTrackInfo(
            hardwareDecoded: !hwdec.isEmpty,
            codec: codec,
            width: width,
            height: height,
            bitrate: max(0, readDoubleProperty("video-bitrate"))
        )
    }

    /// Copies an observed `track-list` node out to raw entries. The node
    /// memory is event-owned and invalidated by the next `mpv_wait_event`
    /// call, so every string is copied here, synchronously, inside the
    /// drain loop.
    private static func readTrackListEntries(_ node: mpv_node) -> [MPVTrackEntry] {
        guard node.format == MPV_FORMAT_NODE_ARRAY,
              let list = node.u.list,
              let values = list.pointee.values else { return [] }
        return (0..<Int(list.pointee.num)).compactMap { readTrackEntry(values[$0]) }
    }

    /// One track-list entry (a NODE_MAP). Keys mpv marks unavailable (e.g.
    /// `title` on an untitled track) are absent from the map, so a missing
    /// key becomes nil rather than an empty string.
    private static func readTrackEntry(_ node: mpv_node) -> MPVTrackEntry? {
        guard node.format == MPV_FORMAT_NODE_MAP,
              let map = node.u.list,
              let keys = map.pointee.keys,
              let values = map.pointee.values else { return nil }
        var id = 0
        var type = ""
        var title: String?
        var lang: String?
        var codec: String?
        var isSelected = false
        var isExternal = false
        for index in 0..<Int(map.pointee.num) {
            guard let key = keys[index] else { continue }
            let value = values[index]
            switch String(cString: key) {
            case "id":
                if value.format == MPV_FORMAT_INT64 { id = Int(value.u.int64) }
            case "type":
                type = Self.nodeString(value) ?? ""
            case "title":
                title = Self.nodeString(value)
            case "lang":
                lang = Self.nodeString(value)
            case "codec":
                codec = Self.nodeString(value)
            case "selected":
                if value.format == MPV_FORMAT_FLAG { isSelected = value.u.flag != 0 }
            case "external":
                if value.format == MPV_FORMAT_FLAG { isExternal = value.u.flag != 0 }
            default:
                break
            }
        }
        return MPVTrackEntry(id: id, type: type, title: title, lang: lang, codec: codec, isSelected: isSelected, isExternal: isExternal)
    }

    private nonisolated static func nodeString(_ node: mpv_node) -> String? {
        guard node.format == MPV_FORMAT_STRING, let cString = node.u.string else { return nil }
        return String(cString: cString)
    }

    /// Synchronous string read; nil when the property is unavailable.
    private func readStringProperty(_ name: String) -> String? {
        guard let cString = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(cString) }
        return String(cString: cString)
    }

    /// Synchronous numeric reads; 0 when the property is unavailable.
    private func readIntProperty(_ name: String) -> Int {
        var value = Int64()
        mpv_get_property(handle, name, MPV_FORMAT_INT64, &value)
        return Int(value)
    }

    private func readDoubleProperty(_ name: String) -> Double {
        var value = Double()
        mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value)
        return value
    }

    /// Reads one property-change event and forwards it. The observation ID
    /// travels on the outer event's `reply_userdata` (mpv_event_property
    /// itself carries only name/format/data). MPV_FORMAT_NONE (property
    /// unavailable, e.g. duration before demux) is ignored.
    private func handlePropertyChange(_ property: mpv_event_property, replyUserdata: UInt64) {
        switch replyUserdata {
        case ObservedProperty.timePos, ObservedProperty.duration:
            guard property.format == MPV_FORMAT_DOUBLE, let data = property.data else { return }
            let value = data.assumingMemoryBound(to: Double.self).pointee
            onEvent?(replyUserdata == ObservedProperty.timePos
                ? .timePosChanged(value) : .durationChanged(value))
        case ObservedProperty.pause, ObservedProperty.pausedForCache, ObservedProperty.eofReached:
            guard property.format == MPV_FORMAT_FLAG, let data = property.data else { return }
            let value = data.assumingMemoryBound(to: Int32.self).pointee != 0
            switch replyUserdata {
            case ObservedProperty.pause:
                onEvent?(.pauseChanged(value))
            case ObservedProperty.pausedForCache:
                onEvent?(.bufferingChanged(value))
            default:
                // Clean-EOF signal: under keep-open the file stays loaded at
                // EOF, so MPV_EVENT_END_FILE never fires for it. Rising edge
                // only — seeking back clears the flag, and replaying to the
                // end raises it again, so a replayed video can end (and
                // re-trigger the up-next countdown) just like a fresh one.
                if value, !wasAtEOF {
                    onEvent?(.ended)
                }
                wasAtEOF = value
            }
        case ObservedProperty.trackList:
            handleTrackListChange(property)
        default:
            break
        }
    }

    /// track-list notifications arrive as NODE values; parse, then emit
    /// only on a real change (mpv already dedups the observation, but the
    /// initial pre-load notification carries an empty list that matches
    /// the idle state and must not surface as an event).
    private func handleTrackListChange(_ property: mpv_event_property) {
        guard property.format == MPV_FORMAT_NODE, let data = property.data else { return }
        let entries = Self.readTrackListEntries(data.assumingMemoryBound(to: mpv_node.self).pointee)
        // Presence only derives from a real list: the empty pre-load
        // notification is idle noise (same reasoning as the subtitle
        // mirror below), and re-notifies that keep the presence (sub-add,
        // selection flips) must not re-emit.
        if !entries.isEmpty {
            let hasVideo = MPVTrackEntry.hasVideoTrack(trackList: entries)
            if hasVideo != lastHasVideoTrack {
                lastHasVideoTrack = hasVideo
                onEvent?(.videoTrackPresenceChanged(hasVideo))
            }
        }
        let parsed = SubtitleTrack.parse(trackList: entries)
        guard parsed.tracks != subtitleTracks || parsed.selectedID != selectedSubtitleTrackID else { return }
        subtitleTracks = parsed.tracks
        selectedSubtitleTrackID = parsed.selectedID
        onEvent?(.subtitleTracksChanged(parsed.tracks, selectedID: parsed.selectedID))
    }

    /// Tears down the session. Idempotent; safe on window close at any
    /// playback stage. Order matters: render context first, in-flight
    /// stream reads second (so `mpv_terminate_destroy`'s thread join is not
    /// held by a parked read), handle third, bridge registration last (mpv
    /// must be unable to fire `open_fn` before the bridge drops its
    /// retained cookie).
    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        // Stop the rescue drive: its beat is checkpointed on `isShutdown`,
        // but cancelling here keeps a sleeping beat from touching the
        // render context after the teardown below has started.
        rescueTask?.cancel()
        renderer?.invalidate()
        renderer = nil
        bridge.cancelInFlightReads()
        if let handle {
            mpv_set_wakeup_callback(handle, nil, nil)
            mpv_terminate_destroy(handle)
            self.handle = nil
        }
        bridge.detach()
    }

    /// Queues an mpv command for asynchronous execution; failures are
    /// logged, never thrown (a failed seek/pause must not take the session
    /// down). mpv runs queued commands in arrival order, so relative
    /// ordering with the async screenshot-raw is preserved. Never blocks
    /// the caller: the old mpv_command took mpv's dispatch lock and could
    /// deadlock the main thread against a wedged core (2026-09-15 hang).
    /// Execution failures come back as MPV_EVENT_COMMAND_REPLY with
    /// userdata 0 and are logged in the drain.
    private func command(_ args: [String]) {
        guard let handle, !isShutdown else { return }
        var cArgs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) } + [nil]
        defer {
            for arg in cArgs { free(UnsafeMutablePointer(mutating: arg)) }
        }
        let result = mpv_command_async(handle, 0, &cArgs)
        if result < 0 {
            logger.error("mpv command \(args.first ?? "?") failed: \(String(cString: mpv_error_string(result)))")
        }
    }

    /// Pumps mpv's event queue on the main actor. Errors and mpv's own
    /// warnings go to TraceKit; nothing here blocks.
    private func drainEvents() {
        guard let handle, !isShutdown else { return }
        while let event = mpv_wait_event(handle, 0) {
            let eventID = event.pointee.event_id
            if eventID == MPV_EVENT_NONE { break }
            switch eventID {
            case MPV_EVENT_LOG_MESSAGE:
                if let data = event.pointee.data {
                    let message = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                    // Only warn+ is subscribed (mpv_request_log_messages), so
                    // map mpv's severity onto TraceKit instead of flattening
                    // everything to info: real problems stay visible.
                    let text = String(cString: message.text)
                    switch message.log_level {
                    case MPV_LOG_LEVEL_FATAL:
                        logger.fault("mpv: \(text)", privacy: .private)
                    case MPV_LOG_LEVEL_ERROR:
                        logger.error("mpv: \(text)", privacy: .private)
                    default:
                        logger.notice("mpv: \(text)", privacy: .private)
                    }
                }
            // Startup milestone chain, kept at debug now that playback is
            // stable. A black window with FILE_LOADED but no PLAYBACK_RESTART
            // means mpv is stuck buffering/decoding; no FILE_LOADED at all
            // means the demuxer never got far enough (see VideoStream logs).
            case MPV_EVENT_FILE_LOADED:
                logger.debug("mpv event: file loaded")
                onEvent?(.fileLoaded)
            case MPV_EVENT_VIDEO_RECONFIG:
                logger.debug("mpv event: video reconfig")
                let info = readVideoTrackInfo()
                if info != lastVideoTrackInfo {
                    lastVideoTrackInfo = info
                    if let info {
                        onEvent?(.videoInfoChanged(info))
                    }
                }
            case MPV_EVENT_AUDIO_RECONFIG:
                logger.debug("mpv event: audio reconfig")
            case MPV_EVENT_PLAYBACK_RESTART:
                logger.debug("mpv event: playback restart")
            case MPV_EVENT_PROPERTY_CHANGE:
                if let data = event.pointee.data {
                    handlePropertyChange(
                        data.assumingMemoryBound(to: mpv_event_property.self).pointee,
                        replyUserdata: event.pointee.reply_userdata
                    )
                }
            case MPV_EVENT_COMMAND_REPLY:
                let replyID = event.pointee.reply_userdata
                // Fire-and-forget async commands (command(_:), userdata 0)
                // reply here too; they carry no payload, so only failures
                // are worth a log line — this is the async replacement for
                // the old mpv_command return-code check.
                guard replyID >= Self.captureReplyBase else {
                    if event.pointee.error < 0 {
                        let detail = String(cString: mpv_error_string(event.pointee.error))
                        logger.error("mpv async command failed: \(detail)")
                    }
                    break
                }
                // `screenshot-raw` replies (captureCurrentFrame). The result
                // node's memory dies at the next wait_event, so the parse —
                // which copies the byte array out — happens right here.
                // A late reply for a capture whose waiter already timed
                // out: drop it (see `abandonedCaptureIDs`), never park it.
                guard Self.shouldStoreCaptureReply(
                    replyID: replyID, abandonedCaptureIDs: &abandonedCaptureIDs
                ) else { break }
                if let data = event.pointee.data,
                   let frame = Self.bgraFrame(
                       fromScreenshotReply: data
                           .assumingMemoryBound(to: mpv_event_command.self)
                           .pointee.result
                   ) {
                    capturedFrames[replyID] = frame
                } else {
                    logger.error("screenshot-raw reply unusable")
                }
            case MPV_EVENT_END_FILE:
                if let data = event.pointee.data {
                    let endFile = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                    if endFile.error < 0 {
                        let detail = String(cString: mpv_error_string(endFile.error))
                        logger.error("Playback ended with error: \(detail)", privacy: .private)
                        onEvent?(.playbackFailed(detail))
                    } else if !wasAtEOF {
                        // Defensive only: under keep-open a clean EOF keeps
                        // the file loaded and arrives as an eof-reached edge
                        // instead. A clean unload that slipped through still
                        // counts as ended, but never double-fires after the
                        // property edge.
                        logger.debug("mpv event: end of file (clean)")
                        onEvent?(.ended)
                    }
                }
            default:
                break
            }
        }
    }
}

/// Sendable hop target for mpv's wakeup callback, which fires on an
/// internal mpv thread. `handler` is written once on the main actor before
/// the callback is registered and only ever read back on the main queue,
/// so the `@unchecked` is a hop, not shared mutable state.
private final class MPVWakeupBox: @unchecked Sendable {
    var handler: (@Sendable () -> Void)?
}

/// mpv wakeup callback: never touch the core from mpv's thread, just
/// schedule the drain onto the main queue.
private func coveMPVWakeup(context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let box = Unmanaged<MPVWakeupBox>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async {
        box.handler?()
    }
}
