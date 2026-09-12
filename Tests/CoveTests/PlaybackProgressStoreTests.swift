import Foundation
import Testing
@testable import Cove

@Suite("Playback progress store")
@MainActor
struct PlaybackProgressStoreTests {
    /// Isolated UserDefaults suite + an injected clock so eviction order is
    /// deterministic. The clock hands out strictly increasing timestamps.
    private final class Clock {
        var tick: Double = 0
        func next() -> Date {
            tick += 1
            return Date(timeIntervalSince1970: tick)
        }
    }

    private func makeStore(
        capacity: Int = 200,
        suiteName: String = "PlaybackProgressStoreTests-\(UUID().uuidString)"
    ) -> (PlaybackProgressStore, Clock) {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let clock = Clock()
        return (PlaybackProgressStore(defaults: defaults, capacity: capacity, now: { clock.next() }), clock)
    }

    @Test("save and read round-trip, and a later save overwrites")
    func saveAndRead() {
        let (store, _) = makeStore()
        #expect(store.position(forKey: "src|/a.mp4") == nil)

        store.savePosition(61.5, forKey: "src|/a.mp4", duration: 100)
        #expect(store.position(forKey: "src|/a.mp4") == 61.5)

        store.savePosition(120, forKey: "src|/a.mp4", duration: 100)
        #expect(store.position(forKey: "src|/a.mp4") == 120)
    }

    @Test("keys for different sources stay independent")
    func keysAreIndependent() {
        let (store, _) = makeStore()
        store.savePosition(30, forKey: "srcA|/movie.mp4", duration: 100)
        store.savePosition(80, forKey: "srcB|/movie.mp4", duration: 100)
        #expect(store.position(forKey: "srcA|/movie.mp4") == 30)
        #expect(store.position(forKey: "srcB|/movie.mp4") == 80)
    }

    @Test("removing an entry deletes it; removing a missing key is a no-op")
    func removal() {
        let (store, _) = makeStore()
        store.savePosition(42, forKey: "src|/a.mp4", duration: 100)
        store.removePosition(forKey: "src|/a.mp4")
        #expect(store.position(forKey: "src|/a.mp4") == nil)

        store.removePosition(forKey: "src|/never-saved.mp4")
        store.savePosition(10, forKey: "src|/b.mp4", duration: 100)
        #expect(store.position(forKey: "src|/b.mp4") == 10)
    }

    @Test("the least recently written entry is evicted beyond capacity")
    func eviction() {
        let (store, _) = makeStore(capacity: 3)
        store.savePosition(1, forKey: "src|/a.mp4", duration: 100)
        store.savePosition(2, forKey: "src|/b.mp4", duration: 100)
        store.savePosition(3, forKey: "src|/c.mp4", duration: 100)

        store.savePosition(4, forKey: "src|/d.mp4", duration: 100)
        #expect(store.position(forKey: "src|/a.mp4") == nil)
        #expect(store.position(forKey: "src|/b.mp4") == 2)
        #expect(store.position(forKey: "src|/d.mp4") == 4)

        // Rewriting an entry refreshes its recency: b is now newest.
        store.savePosition(20, forKey: "src|/b.mp4", duration: 100)
        store.savePosition(5, forKey: "src|/e.mp4", duration: 100)
        #expect(store.position(forKey: "src|/c.mp4") == nil)
        #expect(store.position(forKey: "src|/b.mp4") == 20)
    }

    @Test("entries survive a store re-creation on the same suite")
    func persistenceAcrossInstances() {
        let suiteName = "PlaybackProgressStoreTests-\(UUID().uuidString)"
        let (store, _) = makeStore(suiteName: suiteName)
        store.savePosition(77, forKey: "src|/a.mp4", duration: 100)

        let defaults = UserDefaults(suiteName: suiteName)!
        let reloaded = PlaybackProgressStore(defaults: defaults)
        #expect(reloaded.position(forKey: "src|/a.mp4") == 77)
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@Suite("Playback progress durations and entries")
@MainActor
struct PlaybackProgressEntryTests {
    private func makeStore(
        suiteName: String = "PlaybackProgressEntryTests-\(UUID().uuidString)"
    ) -> (PlaybackProgressStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (PlaybackProgressStore(defaults: defaults), defaults)
    }

    @Test("duration rides along on save and reads back through allEntries")
    func durationRoundTrip() {
        let (store, _) = makeStore()
        store.savePosition(61.5, forKey: "smb://nas/media|/a.mp4", duration: 120)

        let entries = store.allEntries()
        #expect(entries.count == 1)
        #expect(entries[0].key == "smb://nas/media|/a.mp4")
        #expect(entries[0].position == 61.5)
        #expect(entries[0].duration == 120)
        #expect(entries[0].lastWatched.timeIntervalSince1970 > 0)
    }

    @Test("records written before durations existed read with a nil duration")
    func legacyFormatTolerated() {
        let (store, defaults) = makeStore()
        // Simulate the pre-duration on-disk shape: position + lastWatched only.
        defaults.set(
            ["smb://nas/media|/old.mp4": ["position": 42.0, "lastWatched": 1_000_000.0]],
            forKey: "cove.playbackProgress.entries"
        )

        let entries = store.allEntries()
        #expect(entries.count == 1)
        #expect(entries[0].position == 42)
        #expect(entries[0].duration == nil)
        #expect(entries[0].lastWatched == Date(timeIntervalSince1970: 1_000_000))
        // The legacy record still serves plain resume lookups.
        #expect(store.position(forKey: "smb://nas/media|/old.mp4") == 42)
    }

    @Test("a malformed entry without a position is skipped, not fatal")
    func malformedEntrySkipped() {
        let (store, defaults) = makeStore()
        defaults.set(
            [
                "smb://nas/media|/broken.mp4": ["lastWatched": 1_000_000.0],
                "smb://nas/media|/good.mp4": ["position": 10.0, "duration": 100.0, "lastWatched": 1_000_001.0],
            ],
            forKey: "cove.playbackProgress.entries"
        )

        let entries = store.allEntries()
        #expect(entries.count == 1)
        #expect(entries[0].key == "smb://nas/media|/good.mp4")
    }

    @Test("saving without duration fields is impossible; new writes always carry one")
    func newWritesCarryDuration() {
        let (store, _) = makeStore()
        store.savePosition(10, forKey: "vault://|/a.mp4", duration: 60)
        store.savePosition(20, forKey: "smb://nas/media|/b.mp4", duration: 200)
        #expect(store.allEntries().allSatisfy { $0.duration != nil })
    }
}

@Suite("Recent watch entry parsing")
@MainActor
struct RecentWatchEntryParsingTests {
    private func record(
        _ key: String,
        position: Double = 90,
        duration: Double? = 300,
        lastWatched: Double = 1_000_000
    ) -> PlaybackProgressEntry {
        PlaybackProgressEntry(
            key: key,
            position: position,
            duration: duration,
            lastWatched: Date(timeIntervalSince1970: lastWatched)
        )
    }

    @Test("an SMB record splits into source, names, and directory")
    func smbParsing() throws {
        let entry = try #require(RecentWatchEntry.parse(record("smb://nas.local/media|/movies/科幻/片.mp4")))
        #expect(entry.source == .smb(host: "nas.local", share: "media"))
        #expect(!entry.isVault)
        #expect(entry.sourceID == "smb://nas.local/media")
        #expect(entry.path == "/movies/科幻/片.mp4")
        #expect(entry.fileName == "片.mp4")
        #expect(entry.directoryPath == "/movies/科幻")
        #expect(entry.position == 90)
        #expect(entry.duration == 300)
    }

    @Test("a share-root video resolves its directory to the root")
    func smbRootDirectory() throws {
        let entry = try #require(RecentWatchEntry.parse(record("smb://nas/media|/a.mp4")))
        #expect(entry.directoryPath == "/")
    }

    @Test("a vault record is flagged and needs no host pair")
    func vaultParsing() throws {
        let entry = try #require(RecentWatchEntry.parse(record("vault://|/downloads/a.mp4")))
        #expect(entry.source == .vault)
        #expect(entry.isVault)
        #expect(entry.directoryPath == "/downloads")
    }

    @Test("paths may contain a pipe; only the first one splits the key")
    func pipeInPath() throws {
        let entry = try #require(RecentWatchEntry.parse(record("smb://nas/media|/a|b/c.mp4")))
        #expect(entry.path == "/a|b/c.mp4")
        #expect(entry.fileName == "c.mp4")
        #expect(entry.directoryPath == "/a|b")
    }

    @Test("malformed keys are skipped")
    func malformedKeys() {
        let malformed = [
            record("no-separator"),
            record("smb://nas/media|"),
            record("smb://nas/media|/"),
            record("smb://nas-only|/a.mp4"),
            record("smb:///media|/a.mp4"),
            record("ftp://nas/media|/a.mp4"),
            record("|/a.mp4"),
        ]
        #expect(malformed.compactMap(RecentWatchEntry.parse).isEmpty)
    }

    @Test("the list sorts by recency and caps at ten")
    func sortingAndCap() {
        let records = (0..<15).map { index in
            record("smb://nas/media|/\(index).mp4", lastWatched: 1_000_000 + Double(index))
        }
        let list = RecentWatchEntry.recentList(from: records)
        #expect(list.count == 10)
        // Newest first; the five oldest records dropped off the cap.
        #expect(list.first?.fileName == "14.mp4")
        #expect(list.last?.fileName == "5.mp4")
        for (newer, older) in zip(list, list.dropFirst()) {
            #expect(newer.lastWatched > older.lastWatched)
        }
    }

    @Test("progress fraction needs a usable duration")
    func progressFraction() throws {
        let withDuration = try #require(RecentWatchEntry.parse(record("smb://n/s|/a.mp4", position: 60, duration: 120)))
        #expect(withDuration.progressFraction == 0.5)

        let legacy = try #require(RecentWatchEntry.parse(record("smb://n/s|/b.mp4", position: 60, duration: nil)))
        #expect(legacy.progressFraction == nil)

        let zeroDuration = try #require(RecentWatchEntry.parse(record("smb://n/s|/c.mp4", position: 60, duration: 0)))
        #expect(zeroDuration.progressFraction == nil)

        // A skewed record clamps into 0…1 instead of overdrawing the bar.
        let overrun = try #require(RecentWatchEntry.parse(record("smb://n/s|/d.mp4", position: 180, duration: 120)))
        #expect(overrun.progressFraction == 1)
    }

    @Test("the subtitle line carries the timecode and a relative time")
    func subtitleLine() throws {
        let entry = try #require(RecentWatchEntry.parse(record("smb://n/s|/a.mp4", position: 3723)))
        let text = entry.subtitleText(relativeTo: Date())
        #expect(text.hasPrefix("已看至 1:02:03 · "))
    }
}
