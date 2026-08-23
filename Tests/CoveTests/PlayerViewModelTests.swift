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

    private func makeViewModel() -> (PlayerViewModel, FakeController) {
        let controller = FakeController()
        return (PlayerViewModel(controller: controller), controller)
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
}
