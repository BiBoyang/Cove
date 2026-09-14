import Foundation
import SourceKit
import Testing
@testable import Cove

@Suite("Continue watching state")
@MainActor
struct ContinueWatchingStateTests {
    private func record(
        _ key: String,
        lastWatched: Double,
        fileSize: Int64? = nil,
        modified: Double? = nil
    ) -> PlaybackProgressEntry {
        PlaybackProgressEntry(
            key: key,
            position: 60,
            duration: 300,
            fileSize: fileSize,
            modifiedDate: modified.map { Date(timeIntervalSince1970: $0) },
            lastWatched: Date(timeIntervalSince1970: lastWatched)
        )
    }

    @Test("the home grid carries the parsed entries, newest first")
    func refreshPopulatesGrid() {
        let records = [
            record("smb://n/s|/b.mp4", lastWatched: 2000),
            record("smb://n/s|/a.mp4", lastWatched: 1000),
        ]
        let viewModel = HomeViewModel(recentWatchRecords: { records }, serverCount: { 1 })
        #expect(viewModel.state.entries.isEmpty)

        viewModel.refresh()
        #expect(viewModel.state.entries.map(\.fileName) == ["b.mp4", "a.mp4"])
        #expect(viewModel.state.placeholder == nil)
    }

    @Test("servers without records show the no-records empty state")
    func emptyWithServers() {
        let viewModel = HomeViewModel(recentWatchRecords: { [] }, serverCount: { 2 })
        viewModel.refresh()
        #expect(viewModel.state.entries.isEmpty)
        #expect(viewModel.state.placeholder?.kind == .noRecords)
        #expect(viewModel.state.placeholder?.action == nil)
    }

    @Test("zero servers show the first-run empty state with an add action")
    func firstRunEmptyState() {
        let viewModel = HomeViewModel(recentWatchRecords: { [] }, serverCount: { 0 })
        viewModel.refresh()
        #expect(viewModel.state.entries.isEmpty)
        #expect(viewModel.state.placeholder?.kind == .noServers)
        #expect(viewModel.state.placeholder?.action == .addServer)
    }

    @Test("refresh drops a pruned entry while the page is on screen")
    func refreshAfterPrune() {
        var records = [
            record("smb://n/s|/a.mp4", lastWatched: 1000),
            record("smb://n/s|/b.mp4", lastWatched: 2000),
        ]
        let viewModel = HomeViewModel(recentWatchRecords: { records }, serverCount: { 1 })
        viewModel.refresh()
        #expect(viewModel.state.entries.count == 2)

        records.removeAll { $0.key == "smb://n/s|/a.mp4" }
        viewModel.refresh()
        #expect(viewModel.state.entries.map(\.fileName) == ["b.mp4"])
    }

    @Test("the home grid caps at thirty (Amendment 2 decision 4)")
    func capsAtThirty() {
        let records = (0..<35).map { index in
            record("smb://n/s|/\(index).mp4", lastWatched: Double(index))
        }
        let viewModel = HomeViewModel(recentWatchRecords: { records }, serverCount: { 1 })
        viewModel.refresh()
        #expect(viewModel.state.entries.count == HomeViewModel.recentCap)
        #expect(viewModel.state.entries.count == 30)
        // Newest first; the five oldest records dropped off the cap.
        #expect(viewModel.state.entries.first?.fileName == "34.mp4")
        #expect(viewModel.state.entries.last?.fileName == "5.mp4")
    }

    @Test("file facts flow from the record into the card model, legacy stays nil")
    func fileFactsFlowToEntries() {
        let records = [
            record(
                "smb://n/s|/new.mp4", lastWatched: 2000,
                fileSize: 123_456, modified: 1_730_000_000
            ),
            record("smb://n/s|/old.mp4", lastWatched: 1000),
        ]
        let viewModel = HomeViewModel(recentWatchRecords: { records }, serverCount: { 1 })
        viewModel.refresh()

        let entries = viewModel.state.entries
        #expect(entries.map(\.fileName) == ["new.mp4", "old.mp4"])
        #expect(entries[0].fileSize == 123_456)
        #expect(entries[0].modifiedDate == Date(timeIntervalSince1970: 1_730_000_000))
        // The pre-facts record degrades: no facts, no cover key — the card
        // keeps the film icon.
        #expect(entries[1].fileSize == nil)
        #expect(entries[1].modifiedDate == nil)
    }

    // MARK: Card location (TASK-player-ux-trio Step 3)

    @Test("location: vault prefixed with 本地仓库, smb share-relative")
    func locationTextBySource() throws {
        let smb = try #require(RecentWatchEntry.parse(record("smb://n/s|/share/dir/sub/m.mp4", lastWatched: 1000)))
        #expect(smb.locationText() == "/share/dir/sub")

        let vault = try #require(RecentWatchEntry.parse(record("vault://local|/Movies/a.mp4", lastWatched: 1000)))
        #expect(vault.locationText() == "本地仓库/Movies")

        // A file at the share root lives in "/".
        let root = try #require(RecentWatchEntry.parse(record("smb://n/s|/a.mp4", lastWatched: 1000)))
        #expect(root.locationText() == "/")
    }

    @Test("middle truncation keeps head and tail around one ellipsis")
    func middleTruncation() {
        #expect(RecentWatchEntry.middleTruncated("/short/path", maxLength: 20) == "/short/path")
        #expect(RecentWatchEntry.middleTruncated("/very/deep/nested/folder", maxLength: 12) == "/very…folder")
        #expect(RecentWatchEntry.middleTruncated("abcde", maxLength: 3) == "a…e")
    }

    @Test("the subtitle line appends the location segment")
    func subtitleAppendsLocation() throws {
        let entry = try #require(RecentWatchEntry.parse(record("smb://n/s|/a.mp4", lastWatched: 1_000_000)))
        let text = entry.subtitleText(relativeTo: Date(timeIntervalSince1970: 2_000_000))
        #expect(text.hasPrefix("已看至 1:00 · "))
        #expect(text.hasSuffix(" · /"))

        let vault = try #require(RecentWatchEntry.parse(record("vault://local|/Movies/a.mp4", lastWatched: 1_000_000)))
        #expect(vault.subtitleText(relativeTo: Date(timeIntervalSince1970: 2_000_000)).hasSuffix(" · 本地仓库/Movies"))
    }

}

@Suite("Continue watching deep link")
@MainActor
struct ContinueWatchingDeepLinkTests {
    private let progressKey = "smb://nas.local/media|/movies/a.mp4"

    /// A coordinator over isolated stores, mirroring the endpoint-switch
    /// suite's seam: seeded servers carry no Keychain password, so a
    /// connect fails fast and deterministically without any network.
    private func makeCoordinator(
        seedServers: [ServerConfig],
        vaultRoot: URL? = nil
    ) throws -> (LibraryCoordinator, PlaybackProgressStore, SMBSessionService, () -> Void) {
        let suiteName = "ContinueWatchingTests-\(UUID().uuidString)"
        let settingsSuite = "\(suiteName)-settings"
        let progressSuite = "\(suiteName)-progress"
        let defaults = UserDefaults(suiteName: suiteName)!
        try ServerStore(defaults: defaults).save(seedServers)
        let service = SMBSessionService(store: ServerStore(defaults: defaults))
        let settings = SettingsService(defaults: UserDefaults(suiteName: settingsSuite)!)
        let cache = makeTestCache()
        let preheat = PreheatService(settings: settings, cacheStore: cache)
        let vault = VaultService(
            root: vaultRoot
                ?? FileManager.default.temporaryDirectory
                    .appendingPathComponent("CoveTests-\(UUID().uuidString)", isDirectory: true)
        )
        let progressDefaults = UserDefaults(suiteName: progressSuite)!
        progressDefaults.removePersistentDomain(forName: progressSuite)
        let progressStore = PlaybackProgressStore(defaults: progressDefaults)
        let coordinator = LibraryCoordinator(
            sessionService: service,
            cache: cache,
            readerCoordinator: ReaderCoordinator(cache: cache, preheatService: preheat, settings: settings),
            preheatService: preheat,
            vaultService: vault,
            preferencesViewModel: PreferencesViewModel(
                settings: settings,
                cache: PreferencesCacheAdapter(store: cache),
                vault: vault
            ),
            shareOpenStore: ShareOpenStore(defaults: UserDefaults(suiteName: settingsSuite)!),
            progressStore: progressStore
        )
        let cleanup: () -> Void = {
            defaults.removePersistentDomain(forName: suiteName)
            UserDefaults(suiteName: settingsSuite)?.removePersistentDomain(forName: settingsSuite)
            progressDefaults.removePersistentDomain(forName: progressSuite)
        }
        return (coordinator, progressStore, service, cleanup)
    }

    private func smbEntry(host: String = "nas.local") -> RecentWatchEntry {
        RecentWatchEntry(
            key: "smb://\(host)/media|/movies/a.mp4",
            source: .smb(host: host, share: "media"),
            sourceID: "smb://\(host)/media",
            path: "/movies/a.mp4",
            directoryPath: "/movies",
            fileName: "a.mp4",
            position: 60,
            duration: 300,
            fileSize: nil,
            modifiedDate: nil,
            lastWatched: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    @Test("a deleted server config prunes the record and empties the grid")
    func deletedServerConfigPrunes() throws {
        // Another server keeps the home page (not the first-run guidance)
        // on screen, so the grid actually renders the doomed entry.
        let other = ServerConfig(id: UUID(), host: "other.local", username: "user")
        let (coordinator, store, _, cleanup) = try makeCoordinator(seedServers: [other])
        defer { cleanup() }
        let key = "smb://ghost.local/media|/movies/a.mp4"
        store.savePosition(60, forKey: key, duration: 300)
        coordinator.start()
        #expect(coordinator.homeViewModel.state.entries.count == 1)

        coordinator.homeViewController.onResumeWatch?(smbEntry(host: "ghost.local"))

        #expect(store.position(forKey: key) == nil)
        #expect(coordinator.homeViewModel.state.entries.isEmpty)
        // The user never left the home page; with the record gone it
        // levels down to the no-records empty state.
        #expect(coordinator.homeViewModel.state.placeholder?.kind == .noRecords)
    }

    @Test("a failed connect keeps the record and surfaces the retry placeholder", .timeLimit(.minutes(1)))
    func transientFailureKeepsRecord() async throws {
        let server = ServerConfig(id: UUID(), host: "nas.local", username: "user")
        let (coordinator, store, _, cleanup) = try makeCoordinator(seedServers: [server])
        defer { cleanup() }
        store.savePosition(60, forKey: progressKey, duration: 300)
        coordinator.start()
        var alerts = 0
        coordinator.onError = { _, _ in alerts += 1 }

        coordinator.homeViewController.onResumeWatch?(smbEntry())

        // Same surface as a manual connect failure (decision 4): the
        // placeholder with retry, never an alert, and the record stays.
        try await waitUntil("the failure placeholder never landed") {
            coordinator.shareGridViewModel.state.placeholder?.kind
                == .failure(symbol: "exclamationmark.triangle")
        }
        #expect(store.position(forKey: progressKey) == 60)
        #expect(alerts == 0)
    }

    @Test("navigating away mid-chain cancels the rest of the deep link", .timeLimit(.minutes(1)))
    func navigationCancelsChain() async throws {
        let server = ServerConfig(id: UUID(), host: "nas.local", username: "user")
        let (coordinator, store, _, cleanup) = try makeCoordinator(seedServers: [server])
        defer { cleanup() }
        store.savePosition(60, forKey: progressKey, duration: 300)
        coordinator.start()
        var alerts = 0
        coordinator.onError = { _, _ in alerts += 1 }
        coordinator.onMessageError = { _, _ in alerts += 1 }

        coordinator.homeViewController.onResumeWatch?(smbEntry())
        // Headless resume (Amendment 1, A1-2): the browser is never
        // navigated — the share grid keeps its idle guidance placeholder
        // while the connect runs; no loading state is imposed.
        #expect(coordinator.shareGridViewModel.state.placeholder?.kind
                == .info(symbol: "externaldrive"))
        // The user opens settings before the connect settles: the chain
        // must die quietly — no failure placeholder, no alert, no prune.
        coordinator.openSettings()

        try await Task.sleep(for: .milliseconds(200))
        #expect(coordinator.shareGridViewModel.state.placeholder?.kind
                == .info(symbol: "externaldrive"))
        #expect(store.position(forKey: progressKey) == 60)
        #expect(alerts == 0)
    }

    @Test("a gone vault file prunes the record without the generic error", .timeLimit(.minutes(1)))
    func vaultFileGonePrunes() async throws {
        let vaultRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoveTests-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let server = ServerConfig(id: UUID(), host: "other.local", username: "user")
        let (coordinator, store, _, cleanup) = try makeCoordinator(seedServers: [server], vaultRoot: vaultRoot)
        defer { cleanup() }
        let key = "vault://|/gone/a.mp4"
        store.savePosition(60, forKey: key, duration: 300)
        coordinator.start()
        var alerts = 0
        coordinator.onError = { _, _ in alerts += 1 }

        let entry = RecentWatchEntry(
            key: key,
            source: .vault,
            sourceID: "vault://",
            path: "/gone/a.mp4",
            directoryPath: "/gone",
            fileName: "a.mp4",
            position: 60,
            duration: 300,
            fileSize: nil,
            modifiedDate: nil,
            lastWatched: Date(timeIntervalSince1970: 1_000_000)
        )
        coordinator.homeViewController.onResumeWatch?(entry)

        // The drill fails, the completion reports it, and the record is
        // pruned — without the vault open's generic error alert.
        try await waitUntil("the record was never pruned") {
            store.position(forKey: key) == nil
        }
        #expect(alerts == 0)
    }

    /// TASK-playback-session-guard Minor 1: the reveal nils the thumbnail
    /// provider unconditionally, so the session-reuse branch must reinstate
    /// it too — previously only the fresh-connect branch did, leaving a
    /// reused session's browser thumbnails all dark.
    @Test("reveal on a reused session reinstalls the thumbnail provider",
          .timeLimit(.minutes(1)))
    func revealReuseReinstallsThumbnailProvider() async throws {
        let server = ServerConfig(id: UUID(), host: "nas.local", username: "user")
        let (coordinator, _, service, cleanup) = try makeCoordinator(seedServers: [server])
        defer { cleanup() }
        coordinator.start()
        // A live session matching the record's source id: the reveal takes
        // the reuse branch (no reconnect, no network).
        try await service.connectLocal(StubShareSource(id: "smb://nas.local/media"))
        #expect(coordinator.browserViewController.thumbnailProvider == nil)

        coordinator.homeViewController.onRevealInBrowser?(smbEntry())

        try await waitUntil("the thumbnail provider never came back") {
            coordinator.browserViewController.thumbnailProvider != nil
        }
    }
}

/// Polls `condition` on the main actor until it holds, yielding between
/// checks so queued main-actor continuations can run. Throws (and thus
/// fails the test) on timeout instead of hanging. Same helper as in
/// ServerEndpointTests; each file keeps a private copy.
@MainActor
private func waitUntil(
    _ message: @autoclosure () -> String = "condition not met before timeout",
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
        if ContinuousClock.now > deadline {
            throw WaitTimeout(message: message())
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private struct WaitTimeout: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
