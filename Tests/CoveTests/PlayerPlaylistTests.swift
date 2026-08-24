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

    @Test("advance/back move and clamp at the queue ends")
    func advanceAndClamp() {
        var playlist = PlayerPlaylist(items: makeQueue(), selectedPath: "/movies/a.mp4")
        // `#expect` evaluates its expression in a closure, so mutating
        // calls happen outside the macro.
        var moved = playlist.back()
        #expect(moved == false)
        #expect(playlist.current?.name == "a.mp4")

        moved = playlist.advance()
        #expect(moved)
        moved = playlist.advance()
        #expect(moved)
        #expect(playlist.current?.name == "c.mov")
        #expect(playlist.canGoNext == false)
        moved = playlist.advance()
        #expect(moved == false)
        #expect(playlist.current?.name == "c.mov")

        moved = playlist.back()
        #expect(moved)
        #expect(playlist.current?.name == "b.mkv")
    }

    @Test("a single-video queue goes nowhere; an empty one has no current")
    func singleAndEmpty() {
        var single = PlayerPlaylist(items: [video("only.mp4")], selectedPath: "/movies/only.mp4")
        #expect(single.canGoPrevious == false)
        #expect(single.canGoNext == false)
        let advanced = single.advance()
        let wentBack = single.back()
        #expect(advanced == false)
        #expect(wentBack == false)

        let empty = PlayerPlaylist(items: [], selectedPath: "/movies/x.mp4")
        #expect(empty.current == nil)
        #expect(empty.canGoNext == false)
    }
}
