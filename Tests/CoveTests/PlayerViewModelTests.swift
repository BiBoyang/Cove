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
        }

        private(set) var commands: [Command] = []

        func togglePause() { commands.append(.togglePause) }
        func seek(bySeconds seconds: Int) { commands.append(.seekBy(seconds)) }
        func seekTo(seconds: Double) { commands.append(.seekTo(seconds)) }
        func setVolume(_ volume: Double) { commands.append(.setVolume(volume)) }
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
        #expect(viewModel.statusText == "缓冲中…")

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
        #expect(viewModel.isProgressEnabled == false)

        viewModel.apply(.pauseChanged(false))
        #expect(viewModel.state == .error)
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
        #expect(viewModel.timeText == "0:10 / 2:00")

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

    // MARK: Resume position

    private final class FakeProgressStore: PlaybackProgressStoring {
        var positions: [String: Double] = [:]
        private(set) var saves: [Double] = []
        private(set) var removals: [String] = []

        func position(forKey key: String) -> Double? { positions[key] }

        func savePosition(_ position: Double, forKey key: String) {
            positions[key] = position
            saves.append(position)
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
}
