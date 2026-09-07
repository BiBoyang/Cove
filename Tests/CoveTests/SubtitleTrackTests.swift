import Foundation
import Testing
@testable import Cove

@Suite("Subtitle track list parsing")
struct SubtitleTrackTests {
    private func entry(
        id: Int,
        type: String = "sub",
        title: String? = nil,
        lang: String? = nil,
        codec: String? = "subrip",
        isSelected: Bool = false
    ) -> MPVTrackEntry {
        MPVTrackEntry(id: id, type: type, title: title, lang: lang, codec: codec, isSelected: isSelected)
    }

    @Test("no tracks: empty list, no selection")
    func noTracks() {
        let parsed = SubtitleTrack.parse(trackList: [])
        #expect(parsed.tracks.isEmpty)
        #expect(parsed.selectedID == nil)
    }

    @Test("video/audio entries are filtered out, including their selection")
    func filtersNonSubtitleTracks() {
        let parsed = SubtitleTrack.parse(trackList: [
            entry(id: 1, type: "video", codec: "h264", isSelected: true),
            entry(id: 2, type: "audio", lang: "eng", codec: "aac", isSelected: true),
            entry(id: 3, type: "sub", lang: "chi"),
        ])
        #expect(parsed.tracks == [
            SubtitleTrack(id: 3, title: nil, lang: "chi", codec: "subrip", displayName: "chi"),
        ])
        #expect(parsed.selectedID == nil)
    }

    @Test("single track: title wins as label, selection surfaces")
    func singleTrack() {
        let parsed = SubtitleTrack.parse(trackList: [
            entry(id: 1, title: "简繁英双语", lang: "chi", codec: "ass", isSelected: true),
        ])
        #expect(parsed.tracks == [
            SubtitleTrack(id: 1, title: "简繁英双语", lang: "chi", codec: "ass", displayName: "简繁英双语"),
        ])
        #expect(parsed.selectedID == 1)
    }

    @Test("multiple tracks: missing title/lang fall back down the label chain")
    func labelFallbacks() {
        let parsed = SubtitleTrack.parse(trackList: [
            entry(id: 1, title: "导演评论", lang: "eng", codec: "subrip"), // title
            entry(id: 2, lang: "jpn", codec: "subrip"),                    // lang
            entry(id: 3, codec: "ass"),                                    // codec
            entry(id: 4, codec: nil),                                      // position
        ])
        #expect(parsed.tracks.map(\.displayName) == ["导演评论", "jpn", "ass", "字幕 4"])
        #expect(parsed.tracks.map(\.id) == [1, 2, 3, 4])
    }

    @Test("empty strings count as missing metadata")
    func emptyStringsAreMissing() {
        let parsed = SubtitleTrack.parse(trackList: [
            entry(id: 1, title: "", lang: "eng"),
            entry(id: 2, title: "", lang: "", codec: ""),
        ])
        #expect(parsed.tracks.map(\.displayName) == ["eng", "字幕 2"])
        #expect(parsed.tracks[1].codec == "")
    }

    @Test("selection: first selected subtitle track wins, none selected means off")
    func selection() {
        let none = SubtitleTrack.parse(trackList: [
            entry(id: 1, lang: "eng"),
            entry(id: 2, lang: "chi"),
        ])
        #expect(none.selectedID == nil)

        // Defensive only: the app never sets secondary-sid, so mpv selects
        // at most one subtitle track; if more arrive, the first one wins.
        let multiple = SubtitleTrack.parse(trackList: [
            entry(id: 1, lang: "eng", isSelected: true),
            entry(id: 2, lang: "chi", isSelected: true),
        ])
        #expect(multiple.selectedID == 1)
    }
}
