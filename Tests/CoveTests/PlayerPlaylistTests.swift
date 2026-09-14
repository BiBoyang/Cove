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

    // MARK: Queue selection (TASK-player-ux-trio Step 2)

    private func audio(_ name: String) -> ContentItem {
        ContentItem(name: name, path: "/music/\(name)", isDirectory: false, size: 100, modifiedDate: nil)
    }

    @Test("folder mode queues same-kind items; singleVideo queues only the opened file")
    func queueSelectionByMode() {
        let videos = makeQueue()
        let audios = [audio("a.mp3"), audio("b.flac")]

        // Folder mode (the browser default) is unchanged: a video queues
        // the folder's videos, an audio file its audio.
        #expect(makePlayerQueue(selectedPath: "/movies/b.mkv", fileType: .video, videos: videos, audios: audios, mode: .folder).map(\.path) == ["/movies/a.mp4", "/movies/b.mkv", "/movies/c.mov"])
        #expect(makePlayerQueue(selectedPath: "/music/b.flac", fileType: .audio, videos: videos, audios: audios, mode: .folder).map(\.path) == ["/music/a.mp3", "/music/b.flac"])

        // Unknown types never queue, in either mode.
        #expect(makePlayerQueue(selectedPath: "/movies/n.txt", fileType: .text, videos: videos, audios: audios, mode: .folder).isEmpty)
        #expect(makePlayerQueue(selectedPath: "/movies/n.txt", fileType: nil, videos: videos, audios: audios, mode: .singleVideo).isEmpty)

        // Single-video mode (continue-watching resumes) keeps only the file.
        #expect(makePlayerQueue(selectedPath: "/movies/b.mkv", fileType: .video, videos: videos, audios: audios, mode: .singleVideo).map(\.path) == ["/movies/b.mkv"])
        #expect(makePlayerQueue(selectedPath: "/music/a.mp3", fileType: .audio, videos: videos, audios: audios, mode: .singleVideo).map(\.path) == ["/music/a.mp3"])

        // A path absent from the listing yields no queue; the open guard
        // surfaces its "无法定位媒体文件" error, same as folder mode.
        #expect(makePlayerQueue(selectedPath: "/movies/gone.mp4", fileType: .video, videos: videos, audios: audios, mode: .singleVideo).isEmpty)
    }

    @Test("a single-video queue greys out prev/next and never auto-advances")
    func singleVideoQueueTransport() {
        let item = video("only.mp4")
        let queue = makePlayerQueue(
            selectedPath: "/movies/only.mp4", fileType: .video,
            videos: [item], audios: [], mode: .singleVideo
        )
        #expect(queue.count == 1)
        let playlist = PlayerPlaylist(items: queue, selectedPath: "/movies/only.mp4")
        // The setTransportAvailability derivation: with one element the
        // playlist edges are false, so both buttons grey out — the
        // continue-watching single-video contract.
        #expect(playlist.canGoPrevious == false)
        #expect(playlist.canGoNext == false)
        #expect(playlist.autoAdvanceIndex(mode: .list) == nil)
        #expect(playlist.autoAdvanceIndex(mode: .single) == nil)
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
