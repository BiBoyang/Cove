import CacheKit
import Foundation
import Testing
@testable import Cove

@Suite("Player view model")
@MainActor
struct PlayerViewModelTests {
    @MainActor
    private final class FakeController: PlayerPlaybackControlling {
        enum Command: Equatable {
            case togglePause
            case seekBy(Int)
            case seekTo(Double)
            case setVolume(Double)
            case setSpeed(Double)
            case setSubtitle(Int?)
        }

        private(set) var commands: [Command] = []
        /// Frame the next `captureCurrentFrame()` returns; nil = the engine
        /// failed to grab one.
        var frameToCapture: BGRAVideoFrame?
        private(set) var captureCount = 0
        /// Stub for the `sub-margin-y` baseline read-back; 0 keeps legacy
        /// tests on the same rest position they have always had.
        var stubbedMarginBaseline = 0
        /// Every subtitle bottom margin handed to the engine, in order.
        private(set) var subtitleMargins: [Int] = []

        var subtitleBottomMarginBaseline: Int { stubbedMarginBaseline }

        func setSubtitleBottomMargin(_ points: Int) {
            subtitleMargins.append(points)
        }

        func togglePause() { commands.append(.togglePause) }
        func seek(bySeconds seconds: Int) { commands.append(.seekBy(seconds)) }
        func seekTo(seconds: Double) { commands.append(.seekTo(seconds)) }
        func setVolume(_ volume: Double) { commands.append(.setVolume(volume)) }
        func setSpeed(_ speed: Double) { commands.append(.setSpeed(speed)) }
        func setSubtitle(trackID: Int?) { commands.append(.setSubtitle(trackID)) }
        func captureCurrentFrame() -> BGRAVideoFrame? {
            captureCount += 1
            return frameToCapture
        }
    }

    private func makeViewModel(
        idleHideInterval: TimeInterval = 2.5
    ) -> (PlayerViewModel, FakeController) {
        let controller = FakeController()
        return (PlayerViewModel(controller: controller, idleHideInterval: idleHideInterval), controller)
    }

    /// Drives the view model into the playing state (file loaded, not
    /// paused), which is the only state where idle auto-hide can engage.
    private func reachPlaying(_ viewModel: PlayerViewModel) {
        viewModel.apply(.fileLoaded)
        viewModel.apply(.pauseChanged(false))
    }

    @Test("stays loading until the file is loaded, then follows pause")
    func loadingThenPlaying() {
        let (viewModel, _) = makeViewModel()
        // mpv sends observed properties' initial values before file-loaded;
        // they must not flip the state out of loading early.
        viewModel.apply(.pauseChanged(false))
        #expect(viewModel.state == .loading)

        viewModel.apply(.fileLoaded)
        #expect(viewModel.state == .playing)

        viewModel.apply(.pauseChanged(true))
        #expect(viewModel.state == .paused)
        viewModel.apply(.pauseChanged(false))
        #expect(viewModel.state == .playing)
    }

    @Test("buffering overrides play/pause and unwinds to the prior state")
    func buffering() {
        let (viewModel, _) = makeViewModel()
        viewModel.apply(.fileLoaded)
        viewModel.apply(.pauseChanged(false))

        viewModel.apply(.bufferingChanged(true))
        #expect(viewModel.state == .buffering)

        viewModel.apply(.pauseChanged(true))
        #expect(viewModel.state == .buffering)
        viewModel.apply(.bufferingChanged(false))
        #expect(viewModel.state == .paused)
    }

    @Test("playback failure is sticky and reported")
    func failure() {
        let (viewModel, _) = makeViewModel()
        var reported: String?
        viewModel.onError = { reported = $0 }

        viewModel.apply(.fileLoaded)
        viewModel.apply(.playbackFailed("stream error"))
        #expect(viewModel.state == .error)
        #expect(reported == "stream error")
        // The central failure placeholder renders this detail verbatim.
        #expect(viewModel.errorDetail == "stream error")
        #expect(viewModel.isProgressEnabled == false)

        viewModel.apply(.pauseChanged(false))
        #expect(viewModel.state == .error)
    }

    @Test("video info from reconfigs lands for the codec chips")
    func videoInfoLands() {
        let (viewModel, _) = makeViewModel()
        #expect(viewModel.videoInfo == nil)

        let info = VideoTrackInfo(
            hardwareDecoded: true, codec: "hevc", width: 1920, height: 1080, bitrate: 8_000_000
        )
        viewModel.apply(.videoInfoChanged(info))
        #expect(viewModel.videoInfo == info)

        let software = VideoTrackInfo(
            hardwareDecoded: false, codec: "mpeg4", width: 720, height: 576, bitrate: 0
        )
        viewModel.apply(.videoInfoChanged(software))
        #expect(viewModel.videoInfo == software)
    }

    @Test("clean EOF fires the auto-advance hook")
    func endedFiresHook() {
        let (viewModel, _) = makeViewModel()
        var endedCount = 0
        viewModel.onEnded = { endedCount += 1 }

        viewModel.apply(.ended)
        #expect(endedCount == 1)
    }

    @Test("progress updates follow time-pos unless scrubbing")
    func progressUpdates() {
        let (viewModel, controller) = makeViewModel()
        viewModel.apply(.fileLoaded)
        viewModel.apply(.durationChanged(120))
        viewModel.apply(.timePosChanged(10))
        #expect(viewModel.currentTime == 10)
        #expect(viewModel.duration == 120)
        // Split timecodes for the capsule's lower row.
        #expect(viewModel.elapsedText == "0:10")
        #expect(viewModel.totalText == "2:00")

        viewModel.beginScrubbing()
        viewModel.apply(.timePosChanged(40))
        #expect(viewModel.currentTime == 10)

        viewModel.scrubTo(80)
        #expect(viewModel.currentTime == 80)
        viewModel.endScrubbing()
        #expect(controller.commands == [.seekTo(80)])
        #expect(viewModel.isScrubbing == false)
    }

    @Test("scrubbing is rejected before the file is loaded")
    func scrubRequiresLoad() {
        let (viewModel, controller) = makeViewModel()
        viewModel.beginScrubbing()
        #expect(viewModel.isScrubbing == false)
        viewModel.endScrubbing()
        #expect(controller.commands.isEmpty)
    }

    @Test("transport intents forward to the controller")
    func intents() {
        let (viewModel, controller) = makeViewModel()
        viewModel.togglePause()
        viewModel.seekBy(seconds: 10)
        viewModel.setVolume(150)
        #expect(controller.commands == [.togglePause, .seekBy(10), .setVolume(100)])
        #expect(viewModel.volume == 100)
    }

    @Test("speed changes forward to the controller and clamp to sanity")
    func speedIntents() {
        let (viewModel, controller) = makeViewModel()
        viewModel.setSpeed(1.5)
        viewModel.setSpeed(99)
        #expect(controller.commands == [.setSpeed(1.5), .setSpeed(4)])
        #expect(viewModel.speed == 4)
    }

    @Test("subtitle track events land for the picker and reset on file switch")
    func subtitleTracksLand() {
        let (viewModel, _) = makeViewModel()
        #expect(viewModel.subtitleTracks.isEmpty)
        #expect(viewModel.selectedSubtitleTrackID == nil)
        #expect(viewModel.hasSubtitleTracks == false)

        let tracks = [
            SubtitleTrack(id: 1, title: "中文", lang: "chi", codec: "subrip", external: false, displayName: "中文"),
            SubtitleTrack(id: 2, title: nil, lang: "eng", codec: "ass", external: false, displayName: "eng"),
        ]
        viewModel.apply(.subtitleTracksChanged(tracks, selectedID: 1))
        #expect(viewModel.subtitleTracks == tracks)
        #expect(viewModel.selectedSubtitleTrackID == 1)
        #expect(viewModel.hasSubtitleTracks)

        // A file switch re-emits through the core: the new file's list
        // (here: none) replaces the old one.
        viewModel.apply(.subtitleTracksChanged([], selectedID: nil))
        #expect(viewModel.subtitleTracks.isEmpty)
        #expect(viewModel.selectedSubtitleTrackID == nil)
        #expect(viewModel.hasSubtitleTracks == false)
    }

    @Test("subtitle intents forward to the controller, nil means off")
    func subtitleIntents() {
        let (viewModel, controller) = makeViewModel()
        viewModel.setSubtitle(trackID: 2)
        viewModel.setSubtitle(trackID: nil)
        #expect(controller.commands == [.setSubtitle(2), .setSubtitle(nil)])
    }

    @Test("replay seeks to zero and clears a parked pause")
    func replayFromStart() {
        let (viewModel, controller) = makeViewModel()
        // Parked at EOF: paused with the position at the end.
        viewModel.apply(.fileLoaded)
        viewModel.apply(.durationChanged(120))
        viewModel.apply(.timePosChanged(120))
        viewModel.apply(.pauseChanged(true))

        viewModel.replayFromStart()
        #expect(controller.commands == [.seekTo(0), .togglePause])

        // While playing (not paused) a replay only seeks.
        viewModel.apply(.pauseChanged(false))
        viewModel.replayFromStart()
        #expect(controller.commands.last == .seekTo(0))
    }

    @Test("time formatting")
    func timeFormatting() {
        #expect(PlayerViewModel.formatTime(0) == "0:00")
        #expect(PlayerViewModel.formatTime(65) == "1:05")
        #expect(PlayerViewModel.formatTime(3661) == "1:01:01")
        #expect(PlayerViewModel.formatTime(-3) == "0:00")
    }

    // MARK: Idle auto-hide

    /// Idle intervals are injected tiny; "past the timeout" sleeps use a
    /// generous 4x margin. The negative cases (paused/scrubbing/hover) are
    /// gated by state, not timing, so they stay robust under CI load.
    @Test("controls hide after the idle timeout while playing")
    func idleHidesControls() async throws {
        let (viewModel, _) = makeViewModel(idleHideInterval: 0.05)
        reachPlaying(viewModel)
        #expect(viewModel.controlsVisible)

        try await Task.sleep(for: .milliseconds(200))
        #expect(viewModel.controlsVisible == false)
    }

    @Test("paused playback never hides the controls")
    func pausedKeepsControls() async throws {
        let (viewModel, _) = makeViewModel(idleHideInterval: 0.05)
        reachPlaying(viewModel)
        viewModel.apply(.pauseChanged(true))
        #expect(viewModel.state == .paused)

        try await Task.sleep(for: .milliseconds(200))
        #expect(viewModel.controlsVisible)
    }

    @Test("scrubbing holds the controls; releasing restarts the countdown")
    func scrubbingKeepsControls() async throws {
        let (viewModel, _) = makeViewModel(idleHideInterval: 0.05)
        reachPlaying(viewModel)
        viewModel.apply(.durationChanged(120))
        viewModel.beginScrubbing()

        try await Task.sleep(for: .milliseconds(200))
        #expect(viewModel.controlsVisible)

        viewModel.endScrubbing()
        try await Task.sleep(for: .milliseconds(200))
        #expect(viewModel.controlsVisible == false)
    }

    @Test("mouse activity restores the controls and resets the countdown")
    func mouseActivityRestoresControls() async throws {
        let (viewModel, _) = makeViewModel(idleHideInterval: 0.05)
        reachPlaying(viewModel)

        try await Task.sleep(for: .milliseconds(200))
        #expect(viewModel.controlsVisible == false)

        viewModel.noteMouseActivity()
        #expect(viewModel.controlsVisible)

        // The countdown restarted with the activity, so it hides again.
        try await Task.sleep(for: .milliseconds(200))
        #expect(viewModel.controlsVisible == false)
    }

    @Test("hovering the capsule keeps the controls up")
    func hoverKeepsControls() async throws {
        let (viewModel, _) = makeViewModel(idleHideInterval: 0.05)
        reachPlaying(viewModel)
        viewModel.setPointerOverControls(true)

        try await Task.sleep(for: .milliseconds(200))
        #expect(viewModel.controlsVisible)

        viewModel.setPointerOverControls(false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(viewModel.controlsVisible == false)
    }

    @Test("arrow-key volume counts as activity and reveals the controls")
    func volumeKeyRevealsControls() async throws {
        let (viewModel, controller) = makeViewModel(idleHideInterval: 0.05)
        reachPlaying(viewModel)

        try await Task.sleep(for: .milliseconds(200))
        #expect(viewModel.controlsVisible == false)

        viewModel.adjustVolume(by: -5)
        #expect(viewModel.controlsVisible)
        #expect(viewModel.volume == 95)
        #expect(controller.commands == [.setVolume(95)])
    }

    // MARK: Subtitle clearance

    @Test("visible controls lift subtitles by baseline + clearance + gap")
    func subtitleLiftWhenVisible() {
        let (viewModel, controller) = makeViewModel()
        controller.stubbedMarginBaseline = 7
        // Fed before the file loads: the baseline is not known yet, so
        // nothing may be written (the rest position is read back, never
        // assumed).
        viewModel.subtitleClearance = 40.2
        #expect(controller.subtitleMargins.isEmpty)

        viewModel.apply(.fileLoaded)
        // 7 + ceil(40.2) + 8 = 56.
        #expect(controller.subtitleMargins == [56])
    }

    @Test("hidden controls return subtitles to the baseline")
    func subtitleRestWhenHidden() async throws {
        let (viewModel, controller) = makeViewModel(idleHideInterval: 0.05)
        controller.stubbedMarginBaseline = 7
        viewModel.subtitleClearance = 40
        reachPlaying(viewModel)
        // Controls start visible: 7 + 40 + 8 = 55.
        #expect(controller.subtitleMargins == [55])

        try await Task.sleep(for: .milliseconds(200))
        #expect(viewModel.controlsVisible == false)
        #expect(controller.subtitleMargins == [55, 7])
    }

    @Test("clearance changes re-lift while visible; unchanged values dedup")
    func subtitleClearanceChanges() {
        let (viewModel, controller) = makeViewModel()
        controller.stubbedMarginBaseline = 7
        reachPlaying(viewModel)
        // Baseline ready, clearance still 0: 7 + 0 + 8 = 15.
        #expect(controller.subtitleMargins == [15])

        viewModel.subtitleClearance = 40 // 7 + 40 + 8 = 55
        viewModel.subtitleClearance = 40.4 // ceil(40.4) = 41: 7 + 41 + 8 = 56
        // Re-assigning 40.4 recomputes the already-applied 56; the dedup
        // must swallow the write.
        viewModel.subtitleClearance = 40.4
        #expect(controller.subtitleMargins == [15, 55, 56])
    }

    @Test("engines without margin support stay on the protocol defaults")
    func subtitleMarginProtocolDefaults() {
        // A minimal engine implementing nothing beyond the original
        // requirements: the extension's default baseline (0) and no-op
        // setter must keep it compilable and runnable.
        final class MinimalController: PlayerPlaybackControlling {
            func togglePause() {}
            func seek(bySeconds seconds: Int) {}
            func seekTo(seconds: Double) {}
            func setVolume(_ volume: Double) {}
            func setSpeed(_ speed: Double) {}
            func setSubtitle(trackID: Int?) {}
        }
        let viewModel = PlayerViewModel(controller: MinimalController(), idleHideInterval: 2.5)
        viewModel.subtitleClearance = 40
        viewModel.apply(.fileLoaded)
        viewModel.apply(.pauseChanged(false))
        #expect(viewModel.state == .playing)
    }

    // MARK: Resume position

    private final class FakeProgressStore: PlaybackProgressStoring {
        var positions: [String: Double] = [:]
        private(set) var saves: [Double] = []
        private(set) var savedDurations: [Double] = []
        private(set) var removals: [String] = []

        func position(forKey key: String) -> Double? { positions[key] }

        func savePosition(_ position: Double, forKey key: String, duration: Double) {
            positions[key] = position
            saves.append(position)
            savedDurations.append(duration)
        }

        func removePosition(forKey key: String) {
            positions[key] = nil
            removals.append(key)
        }
    }

    private func makeProgressViewModel(
        savedPosition: Double? = nil
    ) -> (PlayerViewModel, FakeController, FakeProgressStore) {
        let controller = FakeController()
        let store = FakeProgressStore()
        if let savedPosition { store.positions["src|/a.mp4"] = savedPosition }
        return (
            PlayerViewModel(controller: controller, progressStore: store, progressKey: "src|/a.mp4"),
            controller,
            store
        )
    }

    @Test("a mid-video record resumes with a single seek once duration is known")
    func resumesMidVideo() {
        let (viewModel, controller, _) = makeProgressViewModel(savedPosition: 60)
        viewModel.apply(.fileLoaded)
        // No resume while the duration is still unknown.
        #expect(controller.commands.isEmpty)

        viewModel.apply(.durationChanged(120))
        #expect(controller.commands == [.seekTo(60)])

        // A later duration correction must not seek again.
        viewModel.apply(.durationChanged(121))
        #expect(controller.commands == [.seekTo(60)])
    }

    @Test("resume also fires when the duration arrives before file-loaded")
    func resumesWhenDurationComesFirst() {
        let (viewModel, controller, _) = makeProgressViewModel(savedPosition: 60)
        viewModel.apply(.durationChanged(120))
        #expect(controller.commands.isEmpty)
        viewModel.apply(.fileLoaded)
        #expect(controller.commands == [.seekTo(60)])
    }

    @Test("a position within the first 5 seconds is not resumed")
    func ignoresBarelyStarted() {
        let (viewModel, controller, store) = makeProgressViewModel(savedPosition: 5)
        viewModel.apply(.fileLoaded)
        viewModel.apply(.durationChanged(120))
        #expect(controller.commands.isEmpty)
        #expect(store.removals.isEmpty)
    }

    @Test("a finished record is deleted and the replay starts from the top")
    func forgetsFinished() {
        let (viewModel, controller, store) = makeProgressViewModel(savedPosition: 118)
        viewModel.apply(.fileLoaded)
        viewModel.apply(.durationChanged(120))
        #expect(controller.commands.isEmpty)
        #expect(store.removals == ["src|/a.mp4"])
        #expect(store.positions.isEmpty)
    }

    @Test("progress writes are throttled to one per 5s of movement")
    func throttledWrites() {
        let (viewModel, _, store) = makeProgressViewModel()
        viewModel.apply(.fileLoaded)
        viewModel.apply(.durationChanged(120))
        viewModel.apply(.pauseChanged(false))

        viewModel.apply(.timePosChanged(1))
        viewModel.apply(.timePosChanged(4))
        #expect(store.saves.isEmpty)

        viewModel.apply(.timePosChanged(7))
        #expect(store.saves == [7])

        viewModel.apply(.timePosChanged(9))
        #expect(store.saves == [7])
        viewModel.apply(.timePosChanged(12))
        #expect(store.saves == [7, 12])
    }

    @Test("pausing persists the position immediately")
    func pausePersists() {
        let (viewModel, _, store) = makeProgressViewModel()
        viewModel.apply(.fileLoaded)
        viewModel.apply(.durationChanged(120))
        viewModel.apply(.timePosChanged(30))

        viewModel.apply(.pauseChanged(true))
        #expect(store.saves.last == 30)
    }

    @Test("closing the window persists the final position")
    func closePersists() {
        let (viewModel, _, store) = makeProgressViewModel()
        viewModel.apply(.fileLoaded)
        viewModel.apply(.durationChanged(120))
        viewModel.apply(.timePosChanged(30))

        viewModel.persistProgressOnClose()
        #expect(store.saves.last == 30)
    }

    @Test("positions past 95% delete the record instead of saving")
    func finishThresholdDeletes() {
        let (viewModel, _, store) = makeProgressViewModel(savedPosition: 60)
        viewModel.apply(.fileLoaded)
        viewModel.apply(.durationChanged(120))

        viewModel.apply(.timePosChanged(119))
        #expect(store.saves.isEmpty)
        #expect(store.removals == ["src|/a.mp4"])
    }

    @Test("a clean end deletes the record")
    func endedDeletes() {
        let (viewModel, _, store) = makeProgressViewModel(savedPosition: 60)
        viewModel.apply(.fileLoaded)
        viewModel.apply(.durationChanged(120))
        #expect(store.positions["src|/a.mp4"] == 60)

        viewModel.apply(.ended)
        #expect(store.removals == ["src|/a.mp4"])
        #expect(store.positions.isEmpty)
    }

    @Test("positions are not persisted while scrubbing")
    func scrubbingSkipsWrites() {
        let (viewModel, _, store) = makeProgressViewModel()
        viewModel.apply(.fileLoaded)
        viewModel.apply(.durationChanged(120))

        viewModel.beginScrubbing()
        viewModel.apply(.timePosChanged(50))
        viewModel.scrubTo(80)
        viewModel.endScrubbing()
        #expect(store.saves.isEmpty)

        // Playback resumes from the drop point; normal ticks persist again.
        viewModel.apply(.timePosChanged(85))
        #expect(store.saves == [85])
    }

    // MARK: Video-cover capture (TASK-video-thumbnails)

    /// 2×2 opaque BGRA frame; content is irrelevant, dimensions honest.
    private func captureFrame() -> BGRAVideoFrame {
        BGRAVideoFrame(
            data: Data(repeating: 200, count: 16), width: 2, height: 2, stride: 8
        )
    }

    private func makeCaptureViewModel(
        _ controller: FakeController,
        cache: CacheStore,
        modified: Date,
        hasWriter: Bool = true
    ) -> PlayerViewModel {
        PlayerViewModel(
            controller: controller,
            progressStore: FakeProgressStore(),
            progressKey: "src|/a.mp4",
            thumbnailWriter: hasWriter ? VideoThumbnailWriter(cache: cache) : nil,
            thumbnailFacts: hasWriter
                ? ThumbnailFileFacts(sourceID: "src", path: "/a.mp4", fileSize: 4096, modified: modified)
                : nil
        )
    }

    /// Waits until the (detached) writer's encode landed in the display pool.
    private func waitForPool(_ cache: CacheStore, key: CacheKey) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !cache.contains(forKey: key, pool: .display) {
            if ContinuousClock.now > deadline {
                Issue.record("cover never reached the display pool")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("closing persists and captures the cover in the same turn")
    func closeCapturesCover() async throws {
        let controller = FakeController()
        controller.frameToCapture = captureFrame()
        let cache = makeTestCache()
        let modified = Date(timeIntervalSince1970: 1_730_000_000)
        let viewModel = makeCaptureViewModel(controller, cache: cache, modified: modified)
        viewModel.apply(.fileLoaded)
        viewModel.apply(.durationChanged(120))
        viewModel.apply(.timePosChanged(30))

        viewModel.persistProgressOnClose()

        // Synchronous by contract: the capture is recorded before this
        // returns, because the window controller tears the session down
        // right after.
        #expect(controller.captureCount == 1)

        let key = try #require(VideoThumbnailStore.cacheKey(
            sourceID: "src", path: "/a.mp4", fileSize: 4096, modified: modified
        ))
        try await waitForPool(cache, key: key)
    }

    @Test("a throttled persist tick defers the capture out of the event drain")
    func tickCapturesCover() async throws {
        let controller = FakeController()
        controller.frameToCapture = captureFrame()
        let cache = makeTestCache()
        let modified = Date(timeIntervalSince1970: 1_730_000_000)
        let viewModel = makeCaptureViewModel(controller, cache: cache, modified: modified)
        viewModel.apply(.fileLoaded)
        viewModel.apply(.durationChanged(120))

        viewModel.apply(.timePosChanged(10))
        // Not synchronously: the capture must never nest inside the event
        // drain this apply may be running in.
        #expect(controller.captureCount == 0)
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.captureCount == 1)

        let key = try #require(VideoThumbnailStore.cacheKey(
            sourceID: "src", path: "/a.mp4", fileSize: 4096, modified: modified
        ))
        try await waitForPool(cache, key: key)
    }

    @Test("a failed capture degrades to no cover")
    func failedCaptureStoresNothing() async throws {
        let controller = FakeController()  // frameToCapture = nil
        let cache = makeTestCache()
        let modified = Date(timeIntervalSince1970: 1_730_000_000)
        let viewModel = makeCaptureViewModel(controller, cache: cache, modified: modified)
        viewModel.apply(.fileLoaded)
        viewModel.apply(.durationChanged(120))
        viewModel.apply(.timePosChanged(30))

        viewModel.persistProgressOnClose()
        #expect(controller.captureCount == 1)
        try await Task.sleep(for: .milliseconds(100))

        let key = try #require(VideoThumbnailStore.cacheKey(
            sourceID: "src", path: "/a.mp4", fileSize: 4096, modified: modified
        ))
        #expect(!cache.contains(forKey: key, pool: .display))
    }

    @Test("sessions without a writer or video track never capture")
    func captureSkippedWithoutWriterOrVideo() {
        let writerless = FakeController()
        let cache = makeTestCache()
        makeCaptureViewModel(writerless, cache: cache, modified: Date(), hasWriter: false)
            .persistProgressOnClose()
        #expect(writerless.captureCount == 0)

        let audio = FakeController()
        audio.frameToCapture = captureFrame()
        let audioViewModel = makeCaptureViewModel(audio, cache: cache, modified: Date())
        audioViewModel.apply(.fileLoaded)
        audioViewModel.apply(.durationChanged(120))
        audioViewModel.apply(.videoTrackPresenceChanged(false))
        audioViewModel.apply(.timePosChanged(30))
        audioViewModel.persistProgressOnClose()
        #expect(audio.captureCount == 0)
    }
}
