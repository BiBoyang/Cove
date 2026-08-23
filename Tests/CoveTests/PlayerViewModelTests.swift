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
}
