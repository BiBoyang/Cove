import Foundation
import Testing
@testable import Cove

@Suite("Reading progress store")
@MainActor
struct ReadingProgressStoreTests {
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
        suiteName: String = "ReadingProgressStoreTests-\(UUID().uuidString)"
    ) -> (ReadingProgressStore, Clock) {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let clock = Clock()
        return (ReadingProgressStore(defaults: defaults, capacity: capacity, now: { clock.next() }), clock)
    }

    @Test("save and read round-trip, and a later save overwrites")
    func saveAndRead() {
        let (store, _) = makeStore()
        #expect(store.page(forKey: "src|/comic-a") == nil)

        store.savePage(12, forKey: "src|/comic-a")
        #expect(store.page(forKey: "src|/comic-a") == 12)

        store.savePage(30, forKey: "src|/comic-a")
        #expect(store.page(forKey: "src|/comic-a") == 30)
    }

    @Test("keys for different sources stay independent")
    func keysAreIndependent() {
        let (store, _) = makeStore()
        store.savePage(3, forKey: "srcA|/comic")
        store.savePage(8, forKey: "srcB|/comic")
        #expect(store.page(forKey: "srcA|/comic") == 3)
        #expect(store.page(forKey: "srcB|/comic") == 8)
    }

    @Test("removing an entry deletes it; removing a missing key is a no-op")
    func removal() {
        let (store, _) = makeStore()
        store.savePage(42, forKey: "src|/comic-a")
        store.removePage(forKey: "src|/comic-a")
        #expect(store.page(forKey: "src|/comic-a") == nil)

        store.removePage(forKey: "src|/never-opened")
        store.savePage(1, forKey: "src|/comic-b")
        #expect(store.page(forKey: "src|/comic-b") == 1)
    }

    @Test("the least recently written entry is evicted beyond capacity")
    func eviction() {
        let (store, _) = makeStore(capacity: 3)
        store.savePage(1, forKey: "src|/a")
        store.savePage(2, forKey: "src|/b")
        store.savePage(3, forKey: "src|/c")

        store.savePage(4, forKey: "src|/d")
        #expect(store.page(forKey: "src|/a") == nil)
        #expect(store.page(forKey: "src|/b") == 2)
        #expect(store.page(forKey: "src|/d") == 4)

        // Rewriting an entry refreshes its recency: b is now newest.
        store.savePage(20, forKey: "src|/b")
        store.savePage(5, forKey: "src|/e")
        #expect(store.page(forKey: "src|/c") == nil)
        #expect(store.page(forKey: "src|/b") == 20)
    }

    @Test("entries survive a store re-creation on the same suite")
    func persistenceAcrossInstances() {
        let suiteName = "ReadingProgressStoreTests-\(UUID().uuidString)"
        let (store, _) = makeStore(suiteName: suiteName)
        store.savePage(77, forKey: "src|/comic-a")

        let defaults = UserDefaults(suiteName: suiteName)!
        let reloaded = ReadingProgressStore(defaults: defaults)
        #expect(reloaded.page(forKey: "src|/comic-a") == 77)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
