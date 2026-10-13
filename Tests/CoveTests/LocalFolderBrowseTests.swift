import Foundation
import SourceKit
import Testing
@testable import Cove

/// TASK-local-folder-browse: the coordinator opens a persisted local
/// folder as a virtual share over the vault's LocalFileSource pipeline,
/// read-only. Covers the success path (title, destination, provider,
/// sourceID), the bookmark-failure degradation, the generation guard,
/// the read-only unreachability pins, and the progress-key free fall
/// (DoD 4).
@Suite("Local folder browsing")
@MainActor
struct LocalFolderBrowseTests {
    /// A coordinator over isolated stores, mirroring the openHome-reset
    /// suite's seam; the local-folder store, pin store, and progress
    /// store are injected so assertions never touch the standard domain.
    /// Seeded servers carry no Keychain password, so nothing here ever
    /// reaches the network.
    private func makeCoordinator(
        localFolderStore: LocalFolderStore,
        pinStore: VaultPinStore
    ) throws -> (LibraryCoordinator, SMBSessionService, PlaybackProgressStore, () -> Void) {
        let suiteName = "LocalFolderBrowseTests-\(UUID().uuidString)"
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
            pinStore: pinStore,
            progressStore: progressStore,
            localFolderStore: localFolderStore
        )
        let cleanup: () -> Void = {
            defaults.removePersistentDomain(forName: suiteName)
            UserDefaults(suiteName: settingsSuite)?.removePersistentDomain(forName: settingsSuite)
            progressDefaults.removePersistentDomain(forName: progressSuite)
        }
        return (coordinator, service, progressStore, cleanup)
    }

    /// An isolated defaults pair for the local-folder and pin stores.
    private func makeStores(_ label: String) -> (LocalFolderStore, VaultPinStore, () -> Void) {
        let folderSuite = "LocalFolderBrowseTests-\(label)-folders-\(UUID().uuidString)"
        let pinSuite = "LocalFolderBrowseTests-\(label)-pins-\(UUID().uuidString)"
        let folderDefaults = UserDefaults(suiteName: folderSuite)!
        let pinDefaults = UserDefaults(suiteName: pinSuite)!
        folderDefaults.removePersistentDomain(forName: folderSuite)
        pinDefaults.removePersistentDomain(forName: pinSuite)
        return (
            LocalFolderStore(defaults: folderDefaults),
            VaultPinStore(defaults: pinDefaults),
            {
                folderDefaults.removePersistentDomain(forName: folderSuite)
                pinDefaults.removePersistentDomain(forName: pinSuite)
            }
        )
    }

    /// A real temp folder with one subdirectory and two files, plus its
    /// security-scoped bookmark (same stand-in pattern as
    /// `LocalFolderStoreShellTests`).
    private func makePickedFolder() throws -> (url: URL, bookmark: Data) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cove-browse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("Sub", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("video".utf8).write(to: url.appendingPathComponent("a.mp4"))
        try Data("text".utf8).write(to: url.appendingPathComponent("b.txt"))
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return (url, bookmark)
    }

    @Test("a successful open lands the folder as a read-only local share",
          .timeLimit(.minutes(1)))
    func openLocalFolderSuccess() async throws {
        let (folderStore, pinStore, cleanupStores) = makeStores("success")
        let picked = try makePickedFolder()
        defer {
            cleanupStores()
            try? FileManager.default.removeItem(at: picked.url)
        }
        let folderID = try #require(folderStore.add(name: "Movies", bookmark: picked.bookmark))
        let (coordinator, service, _, cleanup) = try makeCoordinator(
            localFolderStore: folderStore, pinStore: pinStore
        )
        defer { cleanup() }
        coordinator.start()

        var titles: [String] = []
        coordinator.onTitleChange = { titles.append($0) }
        coordinator.openLocalFolder(folderID: folderID)

        // Synchronous choreography, like `openVault`.
        #expect(coordinator.serverListViewModel.activeDestination == .localFolder(id: folderID))
        #expect(coordinator.browserViewController.browseMode == .local)
        #expect(coordinator.browserViewController.thumbnailProvider == nil)
        #expect(titles.last == "Movies")

        try await waitUntilLocal("the folder listing never landed") {
            coordinator.browserViewModel.state.path == "/"
                && !coordinator.browserViewModel.state.isLoading
        }

        #expect(service.currentSourceID == "local://\(folderID)")
        // Window title = displayName; browser root title follows it too.
        #expect(coordinator.browserViewModel.state.title == "Movies")
        #expect(coordinator.browserViewModel.state.items.map(\.name).sorted() == ["Sub", "a.mp4", "b.txt"])
        // Read-only context: no preheat pipeline, no pin capsule.
        #expect(coordinator.browserViewModel.state.preheat == .unavailable)
        #expect(coordinator.serverListViewModel.activePinPath == nil)
        // The provider is installed only after the connect succeeded.
        #expect(coordinator.browserViewController.thumbnailProvider != nil)
    }

    @Test("an unresolvable bookmark degrades to an error toast, not a crash or empty share")
    func openLocalFolderBookmarkInvalid() throws {
        let (folderStore, pinStore, cleanupStores) = makeStores("invalid")
        defer { cleanupStores() }
        // A base64-valid blob that is not a bookmark resolves to nil.
        let junkID = try #require(folderStore.add(name: "Junk", bookmark: Data("junk".utf8)))
        let (coordinator, _, _, cleanup) = try makeCoordinator(
            localFolderStore: folderStore, pinStore: pinStore
        )
        defer { cleanup() }
        coordinator.start()
        #expect(coordinator.serverListViewModel.activeDestination == .home)

        var messageErrors: [(message: String, title: String)] = []
        coordinator.onMessageError = { messageErrors.append(($0, $1)) }
        var errors = 0
        coordinator.onError = { _, _ in errors += 1 }

        // Unknown id and junk bookmark alike: the error path, no navigation.
        coordinator.openLocalFolder(folderID: UUID().uuidString)
        coordinator.openLocalFolder(folderID: junkID)

        #expect(messageErrors.count == 2)
        #expect(messageErrors.allSatisfy { $0.title == "打开本地文件夹失败" })
        #expect(messageErrors.allSatisfy { $0.message.contains("重新选择") })
        #expect(errors == 0)
        // The home page stays put; no browser pane, no mode flip.
        #expect(coordinator.serverListViewModel.activeDestination == .home)
        #expect(coordinator.browserViewController.browseMode == .remote)
    }

    @Test("a superseding navigation cancels the open at its generation guard",
          .timeLimit(.minutes(1)))
    func openLocalFolderGenerationGuard() async throws {
        let (folderStore, pinStore, cleanupStores) = makeStores("generation")
        let picked = try makePickedFolder()
        defer {
            cleanupStores()
            try? FileManager.default.removeItem(at: picked.url)
        }
        let folderID = try #require(folderStore.add(name: "Movies", bookmark: picked.bookmark))
        let (coordinator, _, _, cleanup) = try makeCoordinator(
            localFolderStore: folderStore, pinStore: pinStore
        )
        defer { cleanup() }
        coordinator.start()

        var errors = 0
        coordinator.onError = { _, _ in errors += 1 }
        coordinator.openLocalFolder(folderID: folderID)
        // The reset bumps the generation and cancels the in-flight open.
        coordinator.openHome()

        // Give the cancelled chain ample time to (not) land.
        try await Task.sleep(for: .milliseconds(300))
        #expect(coordinator.serverListViewModel.activeDestination == .home)
        #expect(errors == 0)
        // The stale open must never install its provider over the reset.
        #expect(coordinator.browserViewController.thumbnailProvider == nil)
    }

    @Test("local browsing offers no context actions and no download/delete/pin path is reachable",
          .timeLimit(.minutes(1)))
    func localContextIsReadOnly() async throws {
        let (folderStore, pinStore, cleanupStores) = makeStores("readonly")
        let picked = try makePickedFolder()
        defer {
            cleanupStores()
            try? FileManager.default.removeItem(at: picked.url)
        }
        let folderID = try #require(folderStore.add(name: "Movies", bookmark: picked.bookmark))
        let (coordinator, _, _, cleanup) = try makeCoordinator(
            localFolderStore: folderStore, pinStore: pinStore
        )
        defer { cleanup() }
        coordinator.start()
        coordinator.openLocalFolder(folderID: folderID)
        try await waitUntilLocal("the folder listing never landed") {
            coordinator.browserViewModel.state.path == "/"
                && !coordinator.browserViewModel.state.isLoading
        }

        let items = coordinator.browserViewModel.state.items
        let file = try #require(items.first { !$0.isDirectory && $0.name == "a.mp4" })
        let directory = try #require(items.first { $0.isDirectory })

        // The menu itself: empty for files and folders alike.
        #expect(BrowserViewController.contextMenuIntent(
            mode: .local, clickedRow: 0, items: [file], pinnedPaths: []) == [])
        #expect(BrowserViewController.contextMenuIntent(
            mode: .local, clickedRow: 0, items: [directory], pinnedPaths: []) == [])

        // Belt-and-suspenders: even a stray intent closure firing does
        // nothing in the local context.
        coordinator.browserViewController.onDownloadToVault?(file)
        #expect(coordinator.browserViewModel.state.download == nil)

        coordinator.browserViewController.onPinToSidebar?(directory)
        #expect(pinStore.load().entries.isEmpty)

        coordinator.browserViewController.onDeleteFromVault?(file)
        #expect(FileManager.default.fileExists(atPath: picked.url.appendingPathComponent("a.mp4").path))
    }

    @Test("playback progress falls into the store under the local:// key (DoD 4)",
          .timeLimit(.minutes(1)))
    func localProgressKey() async throws {
        let (folderStore, pinStore, cleanupStores) = makeStores("progress")
        let picked = try makePickedFolder()
        defer {
            cleanupStores()
            try? FileManager.default.removeItem(at: picked.url)
        }
        let folderID = try #require(folderStore.add(name: "Movies", bookmark: picked.bookmark))
        let (coordinator, service, progressStore, cleanup) = try makeCoordinator(
            localFolderStore: folderStore, pinStore: pinStore
        )
        defer { cleanup() }
        coordinator.start()
        coordinator.openLocalFolder(folderID: folderID)
        try await waitUntilLocal("the folder listing never landed") {
            coordinator.browserViewModel.state.path == "/"
                && !coordinator.browserViewModel.state.isLoading
        }

        // The player keys progress "sourceID|path"; with the local://
        // source id the record lands in the same store with no extra
        // plumbing.
        let sourceID = try #require(service.currentSourceID)
        #expect(sourceID.hasPrefix("local://"))
        let key = "\(sourceID)|/a.mp4"
        progressStore.savePosition(60, forKey: key, duration: 300)
        #expect(progressStore.position(forKey: "local://\(folderID)|/a.mp4") == 60)
    }
}

/// Polls `condition` on the main actor until it holds, yielding between
/// checks so queued main-actor continuations can run. Throws (and thus
/// fails the test) on timeout instead of hanging. Same helper as in
/// ContinueWatchingTests; each file keeps a private copy.
@MainActor
private func waitUntilLocal(
    _ message: @autoclosure () -> String = "condition not met before timeout",
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
        if ContinuousClock.now > deadline {
            throw LocalWaitTimeout(message: message())
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private struct LocalWaitTimeout: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
