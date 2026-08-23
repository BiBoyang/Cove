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

        store.savePosition(61.5, forKey: "src|/a.mp4")
        #expect(store.position(forKey: "src|/a.mp4") == 61.5)

        store.savePosition(120, forKey: "src|/a.mp4")
        #expect(store.position(forKey: "src|/a.mp4") == 120)
    }

    @Test("keys for different sources stay independent")
    func keysAreIndependent() {
        let (store, _) = makeStore()
        store.savePosition(30, forKey: "srcA|/movie.mp4")
        store.savePosition(80, forKey: "srcB|/movie.mp4")
        #expect(store.position(forKey: "srcA|/movie.mp4") == 30)
        #expect(store.position(forKey: "srcB|/movie.mp4") == 80)
    }

    @Test("removing an entry deletes it; removing a missing key is a no-op")
    func removal() {
        let (store, _) = makeStore()
        store.savePosition(42, forKey: "src|/a.mp4")
        store.removePosition(forKey: "src|/a.mp4")
        #expect(store.position(forKey: "src|/a.mp4") == nil)

        store.removePosition(forKey: "src|/never-saved.mp4")
        store.savePosition(10, forKey: "src|/b.mp4")
        #expect(store.position(forKey: "src|/b.mp4") == 10)
    }

    @Test("the least recently written entry is evicted beyond capacity")
    func eviction() {
        let (store, _) = makeStore(capacity: 3)
        store.savePosition(1, forKey: "src|/a.mp4")
        store.savePosition(2, forKey: "src|/b.mp4")
        store.savePosition(3, forKey: "src|/c.mp4")

        store.savePosition(4, forKey: "src|/d.mp4")
        #expect(store.position(forKey: "src|/a.mp4") == nil)
        #expect(store.position(forKey: "src|/b.mp4") == 2)
        #expect(store.position(forKey: "src|/d.mp4") == 4)

        // Rewriting an entry refreshes its recency: b is now newest.
        store.savePosition(20, forKey: "src|/b.mp4")
        store.savePosition(5, forKey: "src|/e.mp4")
        #expect(store.position(forKey: "src|/c.mp4") == nil)
        #expect(store.position(forKey: "src|/b.mp4") == 20)
    }

    @Test("entries survive a store re-creation on the same suite")
    func persistenceAcrossInstances() {
        let suiteName = "PlaybackProgressStoreTests-\(UUID().uuidString)"
        let (store, _) = makeStore(suiteName: suiteName)
        store.savePosition(77, forKey: "src|/a.mp4")

        let defaults = UserDefaults(suiteName: suiteName)!
        let reloaded = PlaybackProgressStore(defaults: defaults)
        #expect(reloaded.position(forKey: "src|/a.mp4") == 77)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
