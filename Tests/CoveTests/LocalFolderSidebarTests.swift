import Foundation
import Testing
@testable import Cove

/// TASK-local-folder-sidebar: the sidebar's "本地文件夹" section end to
/// end — the ViewModel row layout over both sections, and the
/// coordinator wiring for add (dedup + immediate open), remove (keeps
/// the current browse), and re-pick (bookmark swap + dedup). The panel
/// run itself stays in the View layer and is not covered here.
@Suite("Local folder sidebar")
@MainActor
struct LocalFolderSidebarTests {
    /// A coordinator over isolated stores, mirroring the browse suite's
    /// seam; seeded servers carry no Keychain password, so nothing here
    /// ever reaches the network.
    private func makeCoordinator(
        localFolderStore: LocalFolderStore,
        pinStore: VaultPinStore
    ) throws -> (LibraryCoordinator, () -> Void) {
        let suiteName = "LocalFolderSidebarTests-\(UUID().uuidString)"
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
            progressStore: PlaybackProgressStore(defaults: progressDefaults),
            localFolderStore: localFolderStore
        )
        let cleanup: () -> Void = {
            defaults.removePersistentDomain(forName: suiteName)
            UserDefaults(suiteName: settingsSuite)?.removePersistentDomain(forName: settingsSuite)
            progressDefaults.removePersistentDomain(forName: progressSuite)
        }
        return (coordinator, cleanup)
    }

    /// An isolated defaults pair for the local-folder and pin stores.
    private func makeStores(_ label: String) -> (LocalFolderStore, VaultPinStore, () -> Void) {
        let folderSuite = "LocalFolderSidebarTests-\(label)-folders-\(UUID().uuidString)"
        let pinSuite = "LocalFolderSidebarTests-\(label)-pins-\(UUID().uuidString)"
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

    /// A real temp folder with one file, plus its security-scoped
    /// bookmark (same stand-in pattern as the browse suite).
    private func makePickedFolder() throws -> (url: URL, bookmark: Data) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cove-sidebar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("video".utf8).write(to: url.appendingPathComponent("a.mp4"))
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return (url, bookmark)
    }

    // MARK: - ViewModel row layout

    @Test("rows map across both sections and the highlight row resolves by id")
    func rowLayout() {
        let server = ServerConfig(id: UUID(), host: "nas", username: "user")
        let viewModel = ServerListViewModel()
        let folders = [
            LocalFolderRow(id: "f1", name: "电影", isAvailable: true),
            LocalFolderRow(id: "f2", name: "漫画", isAvailable: false),
        ]

        // Zero folders: the section still renders its header (add button
        // stays reachable) but takes no extra height.
        viewModel.update(servers: [server])
        viewModel.update(localFolders: [])
        #expect(viewModel.rowCount == 3)
        #expect(viewModel.isLocalFolderHeaderRow(2))
        #expect(viewModel.localFolder(atTableRow: 2) == nil)
        #expect(viewModel.localFolder(atTableRow: 3) == nil)

        viewModel.update(localFolders: folders)
        // Rows: 0 服务器 header, 1 server, 2 本地文件夹 header, 3-4 folders.
        #expect(viewModel.rowCount == 5)
        #expect(viewModel.isGroupRow(0))
        #expect(viewModel.isGroupRow(2))
        #expect(!viewModel.isGroupRow(3))
        #expect(viewModel.server(atTableRow: 1) == server)
        #expect(viewModel.server(atTableRow: 3) == nil)
        #expect(viewModel.localFolder(atTableRow: 3) == folders[0])
        #expect(viewModel.localFolder(atTableRow: 4) == folders[1])
        #expect(viewModel.localFolder(atTableRow: 5) == nil)
        #expect(viewModel.tableRow(forLocalFolderID: "f2") == 4)
        #expect(viewModel.tableRow(forLocalFolderID: "gone") == nil)

        // A server-count change shifts the folder rows; the mapping
        // follows (highlight-sync prerequisite).
        viewModel.update(servers: [server, server])
        #expect(viewModel.rowCount == 6)
        #expect(viewModel.tableRow(forLocalFolderID: "f1") == 4)
        #expect(viewModel.localFolder(atTableRow: 5) == folders[1])
    }

    @Test("local folder updates report and carry the invalid state")
    func localFolderUpdates() {
        let viewModel = ServerListViewModel()
        var observed: [[LocalFolderRow]] = []
        viewModel.onLocalFoldersChange = { observed.append($0) }

        // Wiring the observer replays the current (empty) value, like
        // onStateChange.
        #expect(observed == [[]])

        let rows = [LocalFolderRow(id: "f1", name: "电影", isAvailable: false)]
        viewModel.update(localFolders: rows)
        #expect(viewModel.localFolders == rows)
        #expect(observed == [[], rows])
        // The invalid flag is what the row greys out on.
        #expect(viewModel.localFolders[0].isAvailable == false)
    }

    // MARK: - Coordinator wiring

    @Test("adding a folder refreshes the list and opens it right away",
          .timeLimit(.minutes(1)))
    func addRefreshesAndOpens() async throws {
        let (folderStore, pinStore, cleanupStores) = makeStores("add")
        let picked = try makePickedFolder()
        defer {
            cleanupStores()
            try? FileManager.default.removeItem(at: picked.url)
        }
        let (coordinator, cleanup) = try makeCoordinator(
            localFolderStore: folderStore, pinStore: pinStore
        )
        defer { cleanup() }
        coordinator.start()
        #expect(coordinator.serverListViewModel.localFolders.isEmpty)

        coordinator.addLocalFolder(name: "Movies", bookmark: picked.bookmark)

        let rows = coordinator.serverListViewModel.localFolders
        #expect(rows.count == 1)
        #expect(rows[0].name == "Movies")
        #expect(rows[0].isAvailable)
        let folderID = rows[0].id
        #expect(folderStore.load().entries.map(\.id) == [folderID])
        // The immediate open: the destination highlight anchors the row.
        #expect(coordinator.serverListViewModel.activeDestination == .localFolder(id: folderID))
        try await waitUntilSidebar("the folder listing never landed") {
            coordinator.browserViewModel.state.path == "/"
                && !coordinator.browserViewModel.state.isLoading
        }
        #expect(coordinator.browserViewModel.state.items.contains { $0.name == "a.mp4" })
    }

    @Test("adding the same path twice is refused with the dedup message",
          .timeLimit(.minutes(1)))
    func duplicatePathRefused() throws {
        let (folderStore, pinStore, cleanupStores) = makeStores("dedup")
        let picked = try makePickedFolder()
        defer {
            cleanupStores()
            try? FileManager.default.removeItem(at: picked.url)
        }
        let (coordinator, cleanup) = try makeCoordinator(
            localFolderStore: folderStore, pinStore: pinStore
        )
        defer { cleanup() }
        coordinator.start()

        coordinator.addLocalFolder(name: "Movies", bookmark: picked.bookmark)
        #expect(folderStore.load().entries.count == 1)

        // A second pick of the same folder yields a fresh bookmark blob
        // resolving to the same standardized path — refused (DoD 5).
        let samePathBookmark = try picked.url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var messages: [String] = []
        coordinator.onMessageError = { message, _ in messages.append(message) }
        coordinator.addLocalFolder(name: "Movies Again", bookmark: samePathBookmark)

        #expect(messages == ["该文件夹已添加。"])
        #expect(folderStore.load().entries.count == 1)
        #expect(coordinator.serverListViewModel.localFolders.count == 1)
    }

    @Test("removing the folder being browsed keeps the current browse",
          .timeLimit(.minutes(1)))
    func removeWhileBrowsingKeepsPane() async throws {
        let (folderStore, pinStore, cleanupStores) = makeStores("remove")
        let picked = try makePickedFolder()
        defer {
            cleanupStores()
            try? FileManager.default.removeItem(at: picked.url)
        }
        let (coordinator, cleanup) = try makeCoordinator(
            localFolderStore: folderStore, pinStore: pinStore
        )
        defer { cleanup() }
        coordinator.start()
        coordinator.addLocalFolder(name: "Movies", bookmark: picked.bookmark)
        let folderID = try #require(coordinator.serverListViewModel.localFolders.first?.id)
        try await waitUntilSidebar("the folder listing never landed") {
            coordinator.browserViewModel.state.path == "/"
                && !coordinator.browserViewModel.state.isLoading
        }
        var shown: [String] = []
        coordinator.onShowDetail = { viewController in
            shown.append(String(describing: type(of: viewController)))
        }

        coordinator.removeLocalFolder(id: folderID)

        // The row is gone from the sidebar and the store…
        #expect(coordinator.serverListViewModel.localFolders.isEmpty)
        #expect(folderStore.load().entries.isEmpty)
        // …but the browse is not forced away: the pane stays on the
        // folder's listing and the destination is not switched.
        #expect(shown.isEmpty)
        #expect(coordinator.serverListViewModel.activeDestination == .localFolder(id: folderID))
        #expect(coordinator.browserViewModel.state.path == "/")
        #expect(coordinator.browserViewModel.state.items.contains { $0.name == "a.mp4" })
        // Nothing on disk was touched.
        #expect(FileManager.default.fileExists(
            atPath: picked.url.appendingPathComponent("a.mp4").path
        ))
    }

    @Test("re-pick swaps the bookmark and refuses another entry's path",
          .timeLimit(.minutes(1)))
    func repickReplacesAndDedups() throws {
        let (folderStore, pinStore, cleanupStores) = makeStores("repick")
        let pickedA = try makePickedFolder()
        let pickedB = try makePickedFolder()
        defer {
            cleanupStores()
            try? FileManager.default.removeItem(at: pickedA.url)
            try? FileManager.default.removeItem(at: pickedB.url)
        }
        let (coordinator, cleanup) = try makeCoordinator(
            localFolderStore: folderStore, pinStore: pinStore
        )
        defer { cleanup() }
        coordinator.start()
        coordinator.addLocalFolder(name: "A", bookmark: pickedA.bookmark)
        coordinator.addLocalFolder(name: "B", bookmark: pickedB.bookmark)
        let rows = coordinator.serverListViewModel.localFolders
        #expect(rows.count == 2)
        let idA = rows[0].id
        let idB = rows[1].id

        // Re-picking B onto A's path collides with another entry —
        // refused, B's stored bookmark untouched.
        var messages: [String] = []
        coordinator.onMessageError = { message, _ in messages.append(message) }
        let aPathBookmark = try pickedA.url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        coordinator.repickLocalFolder(id: idB, bookmark: aPathBookmark)
        #expect(messages == ["该文件夹已添加。"])
        #expect(folderStore.resolve(id: idB).url?.standardizedFileURL
            == pickedB.url.standardizedFileURL)

        // A valid re-pick swaps the bookmark (here a fresh blob for B's
        // own path, which excludes itself from the dedup) and refreshes
        // the row.
        let freshB = try pickedB.url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        coordinator.repickLocalFolder(id: idB, bookmark: freshB)
        #expect(messages == ["该文件夹已添加。"])
        #expect(folderStore.resolve(id: idB).status == .ready)
        #expect(coordinator.serverListViewModel.localFolders.count == 2)
        #expect(coordinator.serverListViewModel.localFolders.allSatisfy { $0.isAvailable })
        #expect(folderStore.load().entries.map(\.id) == [idA, idB])
    }
}

/// Polls `condition` on the main actor until it holds, yielding between
/// checks so queued main-actor continuations can run. Throws (and thus
/// fails the test) on timeout instead of hanging. Same helper pattern as
/// the browse suite; each file keeps a private copy.
@MainActor
private func waitUntilSidebar(
    _ message: @autoclosure () -> String = "condition not met before timeout",
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
        if ContinuousClock.now > deadline {
            throw SidebarWaitTimeout(message: message())
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private struct SidebarWaitTimeout: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
