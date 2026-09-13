import Foundation
import SourceKit
import Testing
@testable import Cove

/// TASK-audio-playback coverage: badge presentation, queue derivation and
/// the no-video-track shell seam. Lives in its own file because
/// ViewModelTests.swift was owned by a parallel task at dispatch time.
@Suite("Audio playback")
@MainActor
struct AudioPlaybackTests {
    private func item(_ name: String, directory: Bool = false) -> ContentItem {
        ContentItem(name: name, path: "/media/\(name)", isDirectory: directory, size: 100, modifiedDate: nil)
    }

    @Test("audio rows tint with the new badge token; neighbours unchanged")
    func audioBadgeTint() {
        #expect(BrowserViewController.placeholderTint(for: item("song.mp3")) == CoveStyle.badgeTintAudio)
        #expect(BrowserViewController.placeholderTint(for: item("song.flac")) == CoveStyle.badgeTintAudio)
        // Non-audio mappings stay on their own tokens.
        #expect(BrowserViewController.placeholderTint(for: item("clip.mp4")) == CoveStyle.badgeTintVideo)
        #expect(BrowserViewController.placeholderTint(for: item("a.bin")) == CoveStyle.badgeTintOther)
    }

    @Test("audioItems derives the audio queue from a mixed listing")
    func audioItemsDerivation() {
        let viewModel = BrowserViewModel()
        viewModel.display(items: [
            item("a.mp4"), item("song1.mp3"), item("notes.txt"),
            item("song2.flac"), item("b.mkv"), item("cover.png"),
        ], path: "/media", title: "media")
        #expect(viewModel.audioItems.map(\.name) == ["song1.mp3", "song2.flac"])
        // The video queue is unaffected by the new sibling.
        #expect(viewModel.videoItems.map(\.name) == ["a.mp4", "b.mkv"])
        #expect(viewModel.item(atPath: "/media/song1.mp3")?.fileType == .audio)
    }

    @Test("track-list video presence: only a real video track counts")
    func hasVideoTrackParsing() {
        func entry(_ type: String) -> MPVTrackEntry {
            MPVTrackEntry(id: 1, type: type, title: nil, lang: nil, codec: nil, isSelected: true, isExternal: false)
        }
        #expect(MPVTrackEntry.hasVideoTrack(trackList: []) == false)
        #expect(MPVTrackEntry.hasVideoTrack(trackList: [entry("audio")]) == false)
        #expect(MPVTrackEntry.hasVideoTrack(trackList: [entry("audio"), entry("sub")]) == false)
        #expect(MPVTrackEntry.hasVideoTrack(trackList: [entry("video"), entry("audio")]))
        // Embedded album art arrives as a video track and renders as cover.
        #expect(MPVTrackEntry.hasVideoTrack(trackList: [entry("audio"), entry("video")]))
    }

    @MainActor
    private final class FakeController: PlayerPlaybackControlling {
        func togglePause() {}
        func seek(bySeconds seconds: Int) {}
        func seekTo(seconds: Double) {}
        func setVolume(_ volume: Double) {}
        func setSpeed(_ speed: Double) {}
        func setSubtitle(trackID: Int?) {}
    }

    @Test("audio shell only shows in the steady states of a video-less session")
    func audioShellGating() {
        let viewModel = PlayerViewModel(controller: FakeController())
        // A fresh session assumes video: ordinary opens never flash the shell.
        #expect(viewModel.hasVideoTrack)
        #expect(viewModel.showsAudioShell == false)

        // Presence lands while still loading: the spinner keeps the center.
        viewModel.apply(.videoTrackPresenceChanged(false))
        #expect(viewModel.hasVideoTrack == false)
        #expect(viewModel.showsAudioShell == false)

        viewModel.apply(.fileLoaded)
        viewModel.apply(.pauseChanged(false))
        #expect(viewModel.state == .playing)
        #expect(viewModel.showsAudioShell)

        // Pausing keeps the shell; buffering hands the center to the spinner.
        viewModel.apply(.pauseChanged(true))
        #expect(viewModel.state == .paused)
        #expect(viewModel.showsAudioShell)
        viewModel.apply(.pauseChanged(false))
        viewModel.apply(.bufferingChanged(true))
        #expect(viewModel.showsAudioShell == false)
        viewModel.apply(.bufferingChanged(false))
        #expect(viewModel.showsAudioShell)

        // A failure hands the center to the error placeholder.
        viewModel.apply(.playbackFailed("boom"))
        #expect(viewModel.state == .error)
        #expect(viewModel.showsAudioShell == false)
    }

    @Test("build matrix keeps the five standalone audio demuxers")
    func audioDemuxerConstraint() throws {
        // Regression guard for TASK-audio-playback Fix 1: the forest once
        // shipped video-container demuxers only and every standalone audio
        // file failed to open. #file = Tests/CoveTests/AudioPlaybackTests.swift.
        let repoRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(
            contentsOf: repoRoot.appendingPathComponent("scripts/build-libmpv.sh"),
            encoding: .utf8
        )
        let demuxerLine = try #require(
            script.split(separator: "\n").first { $0.contains("--enable-demuxer=") },
            "build-libmpv.sh lost its --enable-demuxer line"
        )
        let demuxers = demuxerLine
            .split(separator: "=", maxSplits: 1)[1]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        for name in ["mp3", "flac", "ogg", "wav", "aac"] {
            #expect(demuxers.contains(name), "demuxer line lost \(name)")
        }
    }

    @Test("a video session never shows the audio shell")
    func videoSessionNeverShowsShell() {
        let viewModel = PlayerViewModel(controller: FakeController())
        viewModel.apply(.fileLoaded)
        viewModel.apply(.pauseChanged(false))
        #expect(viewModel.showsAudioShell == false)
        viewModel.apply(.videoTrackPresenceChanged(true))
        #expect(viewModel.hasVideoTrack)
        #expect(viewModel.showsAudioShell == false)
    }
}
