import Foundation
import SourceKit
import Testing
@testable import Cove

@Suite("Player playlist")
struct PlayerPlaylistTests {
    private func video(_ name: String) -> ContentItem {
        ContentItem(name: name, path: "/movies/\(name)", isDirectory: false, size: 100, modifiedDate: nil)
    }

    private func makeQueue() -> [ContentItem] {
        [video("a.mp4"), video("b.mkv"), video("c.mov")]
    }

    @Test("starts on the selected path; an unknown path falls back to the first")
    func selection() {
        var playlist = PlayerPlaylist(items: makeQueue(), selectedPath: "/movies/b.mkv")
        #expect(playlist.current?.name == "b.mkv")
        #expect(playlist.canGoPrevious)
        #expect(playlist.canGoNext)

        playlist = PlayerPlaylist(items: makeQueue(), selectedPath: "/movies/gone.mp4")
        #expect(playlist.current?.name == "a.mp4")
        #expect(playlist.canGoPrevious == false)
    }

    @Test("setCurrentIndex moves within bounds and ignores out-of-range jumps")
    func setCurrentIndexBounds() {
        var playlist = PlayerPlaylist(items: makeQueue(), selectedPath: "/movies/a.mp4")
        playlist.setCurrentIndex(2)
        #expect(playlist.current?.name == "c.mov")
        playlist.setCurrentIndex(99)
        #expect(playlist.current?.name == "c.mov")
        playlist.setCurrentIndex(-1)
        #expect(playlist.current?.name == "c.mov")
    }

    @Test("linear stepIndex moves and stops at the queue edges")
    func linearStep() {
        var playlist = PlayerPlaylist(items: makeQueue(), selectedPath: "/movies/a.mp4")
        #expect(playlist.stepIndex(delta: -1, mode: .list) == nil)
        #expect(playlist.stepIndex(delta: 1, mode: .list) == 1)
        playlist.setCurrentIndex(2)
        #expect(playlist.stepIndex(delta: 1, mode: .list) == nil)
        #expect(playlist.stepIndex(delta: -1, mode: .list) == 1)
        // Repeat-one and single still step linearly on manual skips.
        #expect(playlist.stepIndex(delta: 1, mode: .repeatOne) == nil)
        #expect(playlist.stepIndex(delta: -1, mode: .single) == 1)
    }

    @Test("list-loop steps wrap around both edges")
    func loopStepWraps() {
        var playlist = PlayerPlaylist(items: makeQueue(), selectedPath: "/movies/a.mp4")
        #expect(playlist.stepIndex(delta: -1, mode: .listLoop) == 2)
        playlist.setCurrentIndex(2)
        #expect(playlist.stepIndex(delta: 1, mode: .listLoop) == 0)
    }

    @Test("shuffle steps land on a different index while one exists")
    func shuffleStep() {
        let playlist = PlayerPlaylist(items: makeQueue(), selectedPath: "/movies/b.mkv")
        for _ in 0..<20 {
            let next = playlist.stepIndex(delta: 1, mode: .shuffle)
            #expect(next != nil)
            #expect(next != 1)
        }
        // A single-video queue has nowhere to shuffle to.
        let single = PlayerPlaylist(items: [video("only.mp4")], selectedPath: "/movies/only.mp4")
        #expect(single.stepIndex(delta: 1, mode: .shuffle) == nil)
    }

    @Test("auto-advance follows the play mode")
    func autoAdvanceByMode() {
        var playlist = PlayerPlaylist(items: makeQueue(), selectedPath: "/movies/b.mkv")
        #expect(playlist.autoAdvanceIndex(mode: .single) == nil)
        #expect(playlist.autoAdvanceIndex(mode: .repeatOne) == 1)
        #expect(playlist.autoAdvanceIndex(mode: .list) == 2)
        #expect(playlist.autoAdvanceIndex(mode: .listLoop) == 2)

        playlist.setCurrentIndex(2)
        #expect(playlist.autoAdvanceIndex(mode: .list) == nil)
        #expect(playlist.autoAdvanceIndex(mode: .listLoop) == 0)

        for _ in 0..<20 {
            #expect(playlist.autoAdvanceIndex(mode: .shuffle) != 2)
        }
    }

    @Test("an empty queue has no current and never advances")
    func emptyQueue() {
        let empty = PlayerPlaylist(items: [], selectedPath: "/movies/x.mp4")
        #expect(empty.current == nil)
        #expect(empty.canGoNext == false)
        #expect(empty.autoAdvanceIndex(mode: .listLoop) == nil)
        #expect(empty.stepIndex(delta: 1, mode: .shuffle) == nil)
        #expect(empty.autoAdvanceIndex(mode: .repeatOne) == nil)
    }
}
