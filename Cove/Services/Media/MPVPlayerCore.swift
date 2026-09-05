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

    /// Property-observation reply IDs, matched against `reply_userdata` in
    /// the drain loop.
    private enum ObservedProperty {
        static let timePos: UInt64 = 1
        static let duration: UInt64 = 2
        static let pause: UInt64 = 3
        static let pausedForCache: UInt64 = 4
        static let eofReached: UInt64 = 5
    }

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
        default:
            break
        }
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

    /// Non-blocking mpv command; failures are logged, never thrown (a
    /// failed seek/pause must not take the session down).
    private func command(_ args: [String]) {
        guard let handle, !isShutdown else { return }
        var cArgs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) } + [nil]
        defer {
            for arg in cArgs { free(UnsafeMutablePointer(mutating: arg)) }
        }
        let result = mpv_command(handle, &cArgs)
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
