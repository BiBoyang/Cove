import Foundation
import SourceKit
import Testing
@testable import Cove

/// TASK-local-folder-home: the home page's continue-watching grid
/// understands `local://<folderID>` records — parse (valid/invalid
/// keys, display-name resolution), the resume/reveal routes' certain-
/// failure prune on an unresolvable bookmark, and the stat branch.
@Suite("Local folder home integration")
@MainActor
struct LocalFolderHomeTests {
    private func record(
        _ key: String,
        lastWatched: Double = 1_000_000
    ) -> PlaybackProgressEntry {
        PlaybackProgressEntry(
            key: key,
            position: 60,
            duration: 300,
            fileSize: nil,
            modifiedDate: nil,
            lastWatched: Date(timeIntervalSince1970: lastWatched)
        )
    }

    // MARK: Parse (DoD 1)

    @Test("a local record parses with the folder id and the store's display name")
    func localParsing() throws {
        let id = UUID().uuidString
        let entry = try #require(RecentWatchEntry.parse(
            record("local://\(id)|/Movies/a.mp4"),
            localFolderNames: [id: "动漫"]
        ))
        #expect(entry.source == .localFolder(folderID: id, name: "动漫"))
        #expect(entry.sourceID == "local://\(id)")
        #expect(entry.path == "/Movies/a.mp4")
        #expect(entry.directoryPath == "/Movies")
        #expect(entry.fileName == "a.mp4")
        #expect(!entry.isVault)
        #expect(entry.locationText() == "动漫/Movies")
    }

    @Test("a local record for an unknown folder id falls back to the generic label")
    func localParsingFallbackName() throws {
        let id = UUID().uuidString
        let entry = try #require(RecentWatchEntry.parse(record("local://\(id)|/a.mp4")))
        #expect(entry.source == .localFolder(
            folderID: id, name: RecentWatchEntry.fallbackLocalFolderName
        ))
        #expect(entry.locationText() == "本地文件夹/")
    }

    @Test("malformed local keys are skipped")
    func localMalformedKeys() {
        let malformed = [
            record("local://|/a.mp4"),   // empty folder id
            record("local://\(UUID().uuidString)|"),  // empty path
            record("local://\(UUID().uuidString)|/"), // root-only path
        ]
        #expect(malformed.compactMap { RecentWatchEntry.parse($0) }.isEmpty)
    }

    // MARK: Coordinator routes

    /// A coordinator over isolated stores, mirroring the browse suite's
    /// seam: the local-folder store and progress store are injected so
    /// assertions never touch the standard domain, and no seeded server
    /// means nothing here ever reaches the network.
    private func makeCoordinator(
        localFolderStore: LocalFolderStore
    ) throws -> (LibraryCoordinator, PlaybackProgressStore, SMBSessionService, VaultService, () -> Void) {
        let suiteName = "LocalFolderHomeTests-\(UUID().uuidString)"
        let settingsSuite = "\(suiteName)-settings"
        let progressSuite = "\(suiteName)-progress"
        let defaults = UserDefaults(suiteName: suiteName)!
        let service = SMBSessionService(store: ServerStore(defaults: defaults))
        let settings = SettingsService(defaults: UserDefaults(suiteName: settingsSuite)!)
        let cache = makeTestCache()
        let preheat = PreheatService(settings: settings, cacheStore: cache)
        let vault = VaultService(
            root: FileManager.default.temporaryDirectory
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
            progressStore: progressStore,
            localFolderStore: localFolderStore
        )
        let cleanup: () -> Void = {
            defaults.removePersistentDomain(forName: suiteName)
            UserDefaults(suiteName: settingsSuite)?.removePersistentDomain(forName: settingsSuite)
            progressDefaults.removePersistentDomain(forName: progressSuite)
        }
        return (coordinator, progressStore, service, vault, cleanup)
    }

    private func makeFolderStore(_ label: String) -> (LocalFolderStore, () -> Void) {
        let suite = "LocalFolderHomeTests-\(label)-folders-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (LocalFolderStore(defaults: defaults), {
            defaults.removePersistentDomain(forName: suite)
        })
    }

    private func localEntry(folderID: String, name: String = "Movies") -> RecentWatchEntry {
        RecentWatchEntry(
            key: "local://\(folderID)|/Movies/a.mp4",
            source: .localFolder(folderID: folderID, name: name),
            sourceID: "local://\(folderID)",
            path: "/Movies/a.mp4",
            directoryPath: "/Movies",
            fileName: "a.mp4",
            position: 60,
            duration: 300,
            fileSize: nil,
            modifiedDate: nil,
            lastWatched: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    @Test("resume with an unresolvable bookmark prunes the record (DoD: 书签失效 prune)")
    func resumeInvalidBookmarkPrunes() throws {
        let (folderStore, cleanupStore) = makeFolderStore("resume")
        let (coordinator, progressStore, _, _, cleanup) = try makeCoordinator(
            localFolderStore: folderStore
        )
        defer { cleanupStore(); cleanup() }
        // The folder id was never added to the store (or its bookmark no
        // longer resolves): the record is a certain failure.
        let folderID = UUID().uuidString
        let key = "local://\(folderID)|/Movies/a.mp4"
        progressStore.savePosition(60, forKey: key, duration: 300)
        coordinator.start()
        #expect(coordinator.homeViewModel.state.entries.count == 1)
        var errors = 0
        coordinator.onError = { _, _ in errors += 1 }
        coordinator.onMessageError = { _, _ in errors += 1 }

        coordinator.homeViewController.onResumeWatch?(localEntry(folderID: folderID))

        #expect(progressStore.position(forKey: key) == nil)
        #expect(coordinator.homeViewModel.state.entries.isEmpty)
        // The prune alert needs a host window the tests don't have; no
        // other error path may fire.
        #expect(errors == 0)
    }

    @Test("reveal with an unresolvable bookmark prunes the record")
    func revealInvalidBookmarkPrunes() throws {
        let (folderStore, cleanupStore) = makeFolderStore("reveal")
        let (coordinator, progressStore, _, _, cleanup) = try makeCoordinator(
            localFolderStore: folderStore
        )
        defer { cleanupStore(); cleanup() }
        let folderID = UUID().uuidString
        let key = "local://\(folderID)|/Movies/a.mp4"
        progressStore.savePosition(60, forKey: key, duration: 300)
        coordinator.start()
        #expect(coordinator.homeViewModel.state.entries.count == 1)

        coordinator.homeViewController.onRevealInBrowser?(localEntry(folderID: folderID))

        #expect(progressStore.position(forKey: key) == nil)
        #expect(coordinator.homeViewModel.state.entries.isEmpty)
    }

    // MARK: statFileFacts (DoD 4)

    @Test("the stat branch resolves the bookmark and reads local file facts", .timeLimit(.minutes(1)))
    func statLocalBranch() async throws {
        let (folderStore, cleanupStore) = makeFolderStore("stat")
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cove-home-stat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folderURL.appendingPathComponent("Movies", isDirectory: true),
            withIntermediateDirectories: true
        )
        let fileURL = folderURL.appendingPathComponent("Movies/a.mp4")
        try Data("video".utf8).write(to: fileURL)
        defer {
            cleanupStore()
            try? FileManager.default.removeItem(at: folderURL)
        }
        let bookmark = try folderURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let folderID = try #require(folderStore.add(name: "Movies", bookmark: bookmark))
        let (_, _, service, vault, cleanup) = try makeCoordinator(localFolderStore: folderStore)
        defer { cleanup() }

        let item = await LibraryCoordinator.statFileFacts(
            of: localEntry(folderID: folderID),
            sessionService: service,
            vaultService: vault,
            localFolderStore: folderStore
        )
        let facts = try #require(item)
        #expect(facts.path == "/Movies/a.mp4")
        #expect(facts.size == Int64("video".utf8.count))
    }

    @Test("the stat branch degrades to nil on an unresolvable bookmark")
    func statLocalBranchInvalidBookmark() async throws {
        let (folderStore, cleanupStore) = makeFolderStore("stat-invalid")
        let (_, _, service, vault, cleanup) = try makeCoordinator(localFolderStore: folderStore)
        defer { cleanupStore(); cleanup() }

        let item = await LibraryCoordinator.statFileFacts(
            of: localEntry(folderID: UUID().uuidString),
            sessionService: service,
            vaultService: vault,
            localFolderStore: folderStore
        )
        #expect(item == nil)
    }
}
