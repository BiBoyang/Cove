import Foundation
import SourceKit
import Testing
@testable import Cove

@Suite("Share open records")
struct ShareOpenRecordsTests {
    private let serverA = UUID()
    private let serverB = UUID()
    /// Round epoch values so the Double-based plist form round-trips
    /// bit-exactly.
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test("record then read round-trips; a later record overwrites")
    func recordAndRead() {
        var records = ShareOpenRecords()
        #expect(records.lastOpened(serverID: serverA, share: "media") == nil)

        records.recordOpen(serverID: serverA, share: "media", at: t0)
        #expect(records.lastOpened(serverID: serverA, share: "media") == t0)

        let t1 = t0.addingTimeInterval(60)
        records.recordOpen(serverID: serverA, share: "media", at: t1)
        #expect(records.lastOpened(serverID: serverA, share: "media") == t1)
    }

    @Test("same share name on different servers stays independent")
    func keysArePerServer() {
        var records = ShareOpenRecords()
        records.recordOpen(serverID: serverA, share: "media", at: t0)
        #expect(records.lastOpened(serverID: serverB, share: "media") == nil)
        #expect(records.lastOpened(serverID: serverA, share: "other") == nil)
    }

    @Test("removing a server drops only its own entries")
    func removeServer() {
        var records = ShareOpenRecords()
        records.recordOpen(serverID: serverA, share: "media", at: t0)
        records.recordOpen(serverID: serverA, share: "public", at: t0)
        records.recordOpen(serverID: serverB, share: "media", at: t0)

        records.removeServer(serverA)
        #expect(records.lastOpened(serverID: serverA, share: "media") == nil)
        #expect(records.lastOpened(serverID: serverA, share: "public") == nil)
        #expect(records.lastOpened(serverID: serverB, share: "media") == t0)
    }

    @Test("plist dictionary round-trip preserves entries")
    func dictionaryRoundTrip() {
        var records = ShareOpenRecords()
        records.recordOpen(serverID: serverA, share: "media", at: t0)
        records.recordOpen(serverID: serverB, share: "public", at: t0.addingTimeInterval(120))

        let restored = ShareOpenRecords(dictionary: records.dictionary)
        #expect(restored == records)
    }
}

@Suite("Share open store")
@MainActor
struct ShareOpenStoreTests {
    /// Isolated UserDefaults suite + an injected clock, so reads return a
    /// deterministic timestamp (same harness as PlaybackProgressStoreTests).
    private func makeStore() -> (ShareOpenStore, UserDefaults) {
        let suiteName = "ShareOpenStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = ShareOpenStore(defaults: defaults, now: { Date(timeIntervalSince1970: 2_000_000) })
        return (store, defaults)
    }

    @Test("record and read round-trip through UserDefaults")
    func roundTrip() {
        let (store, _) = makeStore()
        let server = UUID()
        #expect(store.lastOpened(forServer: server, share: "media") == nil)

        store.recordOpen(forServer: server, share: "media")
        #expect(store.lastOpened(forServer: server, share: "media") == Date(timeIntervalSince1970: 2_000_000))
    }

    @Test("removing a server's records persists to the suite")
    func removalPersists() {
        let (store, defaults) = makeStore()
        let server = UUID()
        store.recordOpen(forServer: server, share: "media")
        store.removeRecords(forServer: server)

        let reloaded = ShareOpenStore(defaults: defaults)
        #expect(reloaded.lastOpened(forServer: server, share: "media") == nil)
    }
}

@Suite("Share card assembly")
@MainActor
struct ShareCardAssemblyTests {
    private let serverID = UUID()
    private let plain = SMBShareInfo(name: "public", comment: "")

    /// All four comment × record combinations in one grid: each metadata
    /// line appears only when its data exists, and a bare share renders
    /// exactly the old one-line card.
    @Test("comment and record combinations map to the two metadata lines")
    func fourCombinations() {
        let opened = Date(timeIntervalSince1970: 1_000_000)
        let recordedShares: Set<String> = ["media", "downloads"]
        let viewModel = ShareGridViewModel(lastOpened: { _, share in
            recordedShares.contains(share) ? opened : nil
        })
        let shares = [
            SMBShareInfo(name: "media", comment: "电影库"),
            SMBShareInfo(name: "tmp", comment: "临时文件"),
            SMBShareInfo(name: "downloads", comment: ""),
            SMBShareInfo(name: "public", comment: ""),
        ]
        viewModel.display(shares: shares, serverID: serverID)

        let cards = viewModel.state.cards
        #expect(cards.count == 4)
        // comment + record: both lines.
        #expect(cards[0].comment == "电影库")
        #expect(cards[0].lastOpenedText != nil)
        // comment, no record: comment line only.
        #expect(cards[1].comment == "临时文件")
        #expect(cards[1].lastOpenedText == nil)
        // no comment, record: last-opened line only.
        #expect(cards[2].comment == nil)
        #expect(cards[2].lastOpenedText != nil)
        // neither: identical to the pre-metadata card.
        #expect(cards[3].comment == nil)
        #expect(cards[3].lastOpenedText == nil)
        #expect(viewModel.state.placeholder == nil)
    }

    @Test("refresh re-assembles the lines after a new record")
    func refreshPicksUpNewRecords() {
        var recorded: Date?
        let viewModel = ShareGridViewModel(lastOpened: { _, _ in recorded })
        viewModel.display(shares: [plain], serverID: serverID)
        #expect(viewModel.state.cards[0].lastOpenedText == nil)

        recorded = Date()
        viewModel.refreshCards()
        #expect(viewModel.state.cards[0].lastOpenedText != nil)
    }

    @Test("a placeholder owns no cards, so refreshing it is a no-op")
    func placeholderClearsContext() {
        let viewModel = ShareGridViewModel(lastOpened: { _, _ in Date() })
        viewModel.display(shares: [plain], serverID: serverID)
        viewModel.showLoading()
        viewModel.refreshCards()
        #expect(viewModel.state.cards.isEmpty)
        #expect(viewModel.state.placeholder?.kind == .loading)
    }

    @Test("a future record clamps to now instead of announcing a future open")
    func futureClampsToNow() {
        let now = Date()
        typealias Card = ShareGridViewModel.ShareCardInfo
        let future = Card.relativeText(for: now.addingTimeInterval(3600), relativeTo: now)
        let justNow = Card.relativeText(for: now, relativeTo: now)
        #expect(future == justNow)
        #expect(!Card.relativeText(for: now.addingTimeInterval(-300), relativeTo: now).isEmpty)
    }
}
