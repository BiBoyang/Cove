import AppKit
import Foundation
import Testing
@testable import Cove

@Suite("Home destination highlight")
@MainActor
struct HomeDestinationHighlightTests {
    @Test("the home destination flows to the bar like any pinned destination")
    func homeDestinationTransitions() {
        let viewModel = ServerListViewModel()
        var observed: [SidebarDestination] = []
        viewModel.onActiveDestinationChange = { observed.append($0) }

        #expect(viewModel.activeDestination == .none)
        observed.removeAll()

        viewModel.setActiveDestination(.home)
        viewModel.setActiveDestination(.vault)
        viewModel.setActiveDestination(.home)
        // A server pane takes over: the home capsule clears.
        viewModel.setActiveDestination(.none)

        #expect(observed == [.home, .vault, .home, .none])
        #expect(viewModel.activeDestination == .none)
    }
}

@Suite("Home card right-click highlight")
@MainActor
struct HomeCardHighlightTests {
    private final class TwoItemDataSource: NSObject, NSCollectionViewDataSource {
        func collectionView(
            _ collectionView: NSCollectionView, numberOfItemsInSection section: Int
        ) -> Int { 2 }

        func collectionView(
            _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            NSCollectionViewItem()
        }
    }

    private func makeCollectionView(dataSource: TwoItemDataSource) -> NSCollectionView {
        let collectionView = NSCollectionView()
        collectionView.dataSource = dataSource
        collectionView.collectionViewLayout = NSCollectionViewFlowLayout()
        collectionView.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        collectionView.allowsMultipleSelection = false
        collectionView.reloadData()
        collectionView.layoutSubtreeIfNeeded()
        return collectionView
    }

    /// A1-1 root cause, reproduced: `selectItems` ADDS to the selection
    /// even with `allowsMultipleSelection = false` — so right-clicking
    /// cards in turn stacked their isSelected highlights, the exact
    /// "multi-select look" the owner reported. This test pins the AppKit
    /// behavior so the quirk can never silently flip back.
    @Test("selectItems is additive even under single selection (the A1-1 root cause)")
    func selectItemsStacksEvenInSingleSelection() {
        let collectionView = makeCollectionView(dataSource: TwoItemDataSource())
        collectionView.selectItems(at: [IndexPath(item: 0, section: 0)], scrollPosition: [])
        collectionView.selectItems(at: [IndexPath(item: 1, section: 0)], scrollPosition: [])
        #expect(collectionView.selectionIndexPaths
                == [IndexPath(item: 0, section: 0), IndexPath(item: 1, section: 0)])
    }

    /// The A1-1 fix: assigning `selectionIndexPaths` REPLACES the
    /// selection, which is what the card context menu's right-click
    /// selection now uses — after any right-click sequence at most one
    /// card carries the selection highlight.
    @Test("assigning selectionIndexPaths replaces, never stacks (the A1-1 fix)")
    func selectionIndexPathsAssignmentReplaces() {
        let collectionView = makeCollectionView(dataSource: TwoItemDataSource())
        collectionView.selectionIndexPaths = [IndexPath(item: 0, section: 0)]
        collectionView.selectionIndexPaths = [IndexPath(item: 1, section: 0)]
        #expect(collectionView.selectionIndexPaths == [IndexPath(item: 1, section: 0)])
    }
}

@Suite("openHome reset")
@MainActor
struct OpenHomeResetTests {
    /// A coordinator over isolated stores, mirroring the continue-watching
    /// suite's seam: seeded servers carry no Keychain password, so nothing
    /// here ever reaches the network.
    private func makeCoordinator(
        seedServers: [ServerConfig]
    ) throws -> (LibraryCoordinator, PlaybackProgressStore, () -> Void) {
        let suiteName = "HomeDestinationTests-\(UUID().uuidString)"
        let settingsSuite = "\(suiteName)-settings"
        let progressSuite = "\(suiteName)-progress"
        let defaults = UserDefaults(suiteName: suiteName)!
        try ServerStore(defaults: defaults).save(seedServers)
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
            progressStore: progressStore
        )
        let cleanup: () -> Void = {
            defaults.removePersistentDomain(forName: suiteName)
            UserDefaults(suiteName: settingsSuite)?.removePersistentDomain(forName: settingsSuite)
            progressDefaults.removePersistentDomain(forName: progressSuite)
        }
        return (coordinator, progressStore, cleanup)
    }

    @Test("from the settings pane: home page back with its cards, home highlighted")
    func openHomeFromSettings() throws {
        let server = ServerConfig(id: UUID(), host: "nas.local", username: "user")
        let (coordinator, store, cleanup) = try makeCoordinator(seedServers: [server])
        defer { cleanup() }
        store.savePosition(60, forKey: "smb://nas.local/media|/movies/a.mp4", duration: 300)
        coordinator.start()
        coordinator.openSettings()
        #expect(coordinator.serverListViewModel.activeDestination == .settings)

        var titles: [String] = []
        coordinator.onTitleChange = { titles.append($0) }
        var detailIsHome = false
        coordinator.onShowDetail = { detailIsHome = $0 === coordinator.homeViewController }

        coordinator.openHome()

        #expect(coordinator.serverListViewModel.activeDestination == .home)
        #expect(titles.last == "Cove")
        #expect(detailIsHome)
        // The home page is back, its grid carrying the watch record.
        #expect(coordinator.homeViewModel.state.entries.map(\.fileName) == ["a.mp4"])
        #expect(coordinator.homeViewModel.state.placeholder == nil)
    }

    @Test("from the vault pane: same reset, and a repeat tap is idempotent")
    func openHomeFromVaultAndRepeat() throws {
        let server = ServerConfig(id: UUID(), host: "nas.local", username: "user")
        let (coordinator, store, cleanup) = try makeCoordinator(seedServers: [server])
        defer { cleanup() }
        store.savePosition(60, forKey: "smb://nas.local/media|/movies/a.mp4", duration: 300)
        coordinator.start()
        coordinator.serverListViewController.onOpenVault?()
        #expect(coordinator.serverListViewModel.activeDestination == .vault)

        coordinator.openHome()

        // The reset lands synchronously; the cancelled vault open dies at
        // its generation guard, without an alert.
        #expect(coordinator.serverListViewModel.activeDestination == .home)
        #expect(coordinator.homeViewModel.state.entries.count == 1)
        #expect(coordinator.homeViewModel.state.placeholder == nil)

        // A second tap re-runs the same reset: nothing drifts.
        coordinator.openHome()
        #expect(coordinator.serverListViewModel.activeDestination == .home)
        #expect(coordinator.homeViewModel.state.entries.count == 1)
        #expect(coordinator.homeViewModel.state.placeholder == nil)
    }

    @Test("launch lands on the home page with the home row highlighted")
    func startHighlightsHome() throws {
        let server = ServerConfig(id: UUID(), host: "nas.local", username: "user")
        let (coordinator, _, cleanup) = try makeCoordinator(seedServers: [server])
        defer { cleanup() }
        var detailIsHome = false
        coordinator.onShowDetail = { detailIsHome = $0 === coordinator.homeViewController }

        coordinator.start()

        #expect(coordinator.serverListViewModel.activeDestination == .home)
        #expect(detailIsHome)
        // No records yet: the no-records level of the two-level empty state.
        #expect(coordinator.homeViewModel.state.entries.isEmpty)
        #expect(coordinator.homeViewModel.state.placeholder?.kind == .noRecords)
    }

    @Test("the home page's cover provider is wired at construction")
    func coverProviderWired() throws {
        let (coordinator, _, cleanup) = try makeCoordinator(seedServers: [])
        defer { cleanup() }
        // Read-only display-pool lookup, present from the start so cards can
        // resolve covers the moment records carry file facts.
        #expect(coordinator.homeViewController.thumbnailProvider != nil)
    }

    @Test("first run is the home page too: no-servers level with an add action")
    func firstRunHighlightsHome() throws {
        let (coordinator, _, cleanup) = try makeCoordinator(seedServers: [])
        defer { cleanup() }
        var detailIsHome = false
        coordinator.onShowDetail = { detailIsHome = $0 === coordinator.homeViewController }

        coordinator.start()

        #expect(coordinator.serverListViewModel.activeDestination == .home)
        #expect(detailIsHome)
        #expect(coordinator.homeViewModel.state.placeholder?.kind == .noServers)
        #expect(coordinator.homeViewModel.state.placeholder?.action == .addServer)
    }

    @Test("removing the current server resets to the home page with home highlighted")
    func removalResetHighlightsHome() throws {
        let server = ServerConfig(id: UUID(), host: "nas.local", username: "user")
        let (coordinator, store, cleanup) = try makeCoordinator(seedServers: [server])
        defer { cleanup() }
        store.savePosition(60, forKey: "smb://nas.local/media|/movies/a.mp4", duration: 300)
        coordinator.start()
        coordinator.openSettings()
        #expect(coordinator.serverListViewModel.activeDestination == .settings)

        // The deletion flow's reset, driven directly: the confirm alert
        // sheet around it needs a real window.
        coordinator.resetAfterRemovingCurrentServer()

        #expect(coordinator.serverListViewModel.activeDestination == .home)
        #expect(coordinator.homeViewModel.state.entries.count == 1)
        #expect(coordinator.homeViewModel.state.placeholder == nil)
    }

    /// Depth-first search for a label carrying the given text.
    private func hierarchyContains(_ root: NSView, text: String) -> Bool {
        if let field = root as? NSTextField, field.stringValue == text { return true }
        return root.subviews.contains { hierarchyContains($0, text: text) }
    }

    @Test("the continue-watching page title is in the home view hierarchy, records or not")
    func pageTitleStaysVisible() throws {
        let server = ServerConfig(id: UUID(), host: "nas.local", username: "user")
        let (withRecords, store, cleanupRecords) = try makeCoordinator(seedServers: [server])
        defer { cleanupRecords() }
        store.savePosition(60, forKey: "smb://nas.local/media|/movies/a.mp4", duration: 300)
        withRecords.start()
        #expect(withRecords.homeViewModel.state.placeholder == nil)
        #expect(hierarchyContains(withRecords.homeViewController.view, text: "继续观看"))

        let (firstRun, _, cleanupFirstRun) = try makeCoordinator(seedServers: [])
        defer { cleanupFirstRun() }
        firstRun.start()
        #expect(firstRun.homeViewModel.state.placeholder?.kind == .noServers)
        #expect(hierarchyContains(firstRun.homeViewController.view, text: "继续观看"))
    }
}
