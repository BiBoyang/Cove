import Foundation
import SourceKit
import Testing
@testable import Cove

@Suite("External subtitle discovery")
struct SubtitleDiscoveryTests {
    private func item(_ name: String, isDirectory: Bool = false) -> ContentItem {
        ContentItem(name: name, path: "/share/dir/\(name)", isDirectory: isDirectory, size: 100, modifiedDate: nil)
    }

    @Test("exact same-name sidecars match, srt and ass alike")
    func exactMatches() {
        let matches = SubtitleDiscovery.matches(videoName: "Movie.mkv", siblings: [
            item("Movie.srt"),
            item("Movie.ass"),
            item("Other.srt"),
        ])
        #expect(matches.map(\.name) == ["Movie.ass", "Movie.srt"])
    }

    @Test("language-tagged sidecars match across separator styles")
    func languageSuffixes() {
        let matches = SubtitleDiscovery.matches(videoName: "Movie.mkv", siblings: [
            item("Movie.chi.srt"),
            item("Movie_zh.ass"),
            item("Movie-eng.srt"),
            item("Movie big5.srt"),
        ])
        #expect(matches.count == 4)
    }

    @Test("non-language remainders and foreign stems never match")
    func nonMatches() {
        let matches = SubtitleDiscovery.matches(videoName: "Movie.mkv", siblings: [
            item("Movie-2.srt"),       // episode number, not a language tag
            item("MovieX.srt"),         // longer stem
            item("Movie.srt.txt"),      // wrong extension
            item("Movie.vtt"),          // unsupported subtitle format
            item("Movie.srt2"),         // wrong extension
            item("Movie..srt"),         // empty tag
        ])
        #expect(matches.isEmpty)
    }

    @Test("extension and stem comparisons are case-insensitive")
    func caseInsensitive() {
        let matches = SubtitleDiscovery.matches(videoName: "MOVIE.MKV", siblings: [
            item("movie.SRT"),
            item("Movie.CHI.srt"),
            item("movie.ass"),
        ])
        #expect(matches.map(\.name) == ["movie.ass", "movie.SRT", "Movie.CHI.srt"])
    }

    @Test("ordering: exact matches first, tagged ones in natural order")
    func ordering() {
        let matches = SubtitleDiscovery.matches(videoName: "Show 01.mkv", siblings: [
            item("Show 01.eng.srt"),
            item("Show 01.chi.srt"),
            item("Show 01.ass"),
            item("Show 01.srt"),
        ])
        #expect(matches.map(\.name) == [
            "Show 01.ass",
            "Show 01.srt",
            "Show 01.chi.srt",
            "Show 01.eng.srt",
        ])
    }

    @Test("directories, other files and the video itself are excluded")
    func exclusions() {
        let matches = SubtitleDiscovery.matches(videoName: "Movie.mkv", siblings: [
            item("Movie.srt", isDirectory: true), // same-name directory
            item("subs", isDirectory: true),
            item("Movie.mkv"),                    // the video itself
            item("Movie.jpg"),
            item("Movie.nfo"),
        ])
        #expect(matches.isEmpty)
    }

    @Test("no sidecars: empty result")
    func noMatches() {
        #expect(SubtitleDiscovery.matches(videoName: "Movie.mkv", siblings: []).isEmpty)
        #expect(SubtitleDiscovery.matches(videoName: "Movie.mkv", siblings: [item("Backdrop.jpg")]).isEmpty)
    }
}

@Suite("External subtitle staging")
struct ExternalSubtitleLoaderTests {
    private func item(_ name: String) -> ContentItem {
        ContentItem(name: name, path: "/share/dir/\(name)", isDirectory: false, size: 100, modifiedDate: nil)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoveSubtitleLoaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("stages every sidecar byte-for-byte and returns the local URLs in order")
    func stagesAllFiles() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payloads: [String: Data] = [
            "/share/dir/Movie.srt": Data("1\n00:00:01 --> 00:00:02\nhi".utf8),
            "/share/dir/Movie.chi.ass": Data("[Script Info]".utf8),
        ]
        let loader = ExternalSubtitleLoader(reader: { path, range in
            #expect(range == 0..<ExternalSubtitleLoader.maxBytes)
            return payloads[path] ?? Data()
        })
        let staged = await loader.stage([item("Movie.srt"), item("Movie.chi.ass")], into: directory)
        #expect(staged.map(\.lastPathComponent) == ["Movie.srt", "Movie.chi.ass"])
        for (path, bytes) in payloads {
            let suffix = (path as NSString).lastPathComponent
            let url = try #require(staged.first { $0.path.hasSuffix(suffix) })
            #expect(try Data(contentsOf: url) == bytes)
        }
    }

    @Test("a failed fetch is skipped; the rest still stage")
    func perFileFailureIsolation() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        struct FetchFailure: Error {}
        let loader = ExternalSubtitleLoader(reader: { path, _ in
            if path.hasSuffix("broken.srt") { throw FetchFailure() }
            return Data("ok".utf8)
        })
        let staged = await loader.stage([item("broken.srt"), item("fine.ass")], into: directory)
        #expect(staged.map(\.lastPathComponent) == ["fine.ass"])
    }

    @Test("empty payloads are skipped without writing a file")
    func emptyPayloadSkipped() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = ExternalSubtitleLoader(reader: { _, _ in Data() })
        let staged = await loader.stage([item("Movie.srt")], into: directory)
        #expect(staged.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("case-insensitive name collisions get an index suffix instead of overwriting")
    func caseCollisionsDisambiguated() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = ExternalSubtitleLoader(reader: { path, _ in
            Data((path.hasSuffix("SRT") ? "upper" : "lower").utf8)
        })
        let staged = await loader.stage([item("Movie.srt"), item("Movie.SRT")], into: directory)
        #expect(staged.map(\.lastPathComponent) == ["Movie.srt", "Movie-2.SRT"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
    }

    @Test("cancelling the session stops staging between files")
    func cancellationStopsStaging() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = ExternalSubtitleLoader(reader: { _, _ in
            // Long enough that cancellation (issued right after the task is
            // created) always lands before the first post-read check.
            try? await Task.sleep(for: .milliseconds(500))
            return Data("payload".utf8)
        })
        let task = Task {
            await loader.stage([item("A.srt"), item("B.ass")], into: directory)
        }
        task.cancel()
        let staged = await task.value
        #expect(staged.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("session directory: created under CoveSubtitles, removable, removal is idempotent")
    func sessionDirectoryLifecycle() throws {
        let directory = try #require(ExternalSubtitleLoader.makeSessionDirectory())
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("CoveSubtitles", isDirectory: true)
        #expect(directory.path.hasPrefix(root.path))
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir) && isDir.boolValue)

        ExternalSubtitleLoader.removeSessionDirectory(directory)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        // A second removal (e.g. window close after a failed swap already
        // cleaned) must not trap.
        ExternalSubtitleLoader.removeSessionDirectory(directory)
    }
}
