import AppKit
import CacheKit
import Foundation
import SourceKit
import Testing
@testable import Cove

/// Player window lifecycle: the close path's reference drop must be
/// synchronous even when a timed-out capture defers the mpv teardown, and
/// the deferred teardown must bind the outgoing core — never a newer one.
@Suite("Player window close")
@MainActor
struct PlayerWindowCloseTests {
    @MainActor
    private final class SpyCore: PlayerWindowCore {
        let videoLayer = MPVVideoLayer()
        var onEvent: ((PlayerCoreEvent) -> Void)?
        private(set) var loadCount = 0
        private(set) var shutdownCount = 0
        /// When set, `waitForCaptureRescue` parks until the gate opens.
        var rescueGate: HandshakeGate?
        var stubCaptureDidTimeOut = false

        func load() { loadCount += 1 }
        func shutdown() { shutdownCount += 1 }
        func waitForCaptureRescue() async { await rescueGate?.park() }
        func captureCurrentFrame() -> BGRAVideoFrame? { nil }
        var captureDidTimeOut: Bool { stubCaptureDidTimeOut }

        func togglePause() {}
        func seek(bySeconds seconds: Int) {}
        func seekTo(seconds: Double) {}
        func setVolume(_ volume: Double) {}
        func setSpeed(_ speed: Double) {}
        func setSubtitle(trackID: Int?) {}
        func addExternalSubtitle(path: String) {}
    }

    /// Scripted session factory: records every requested item, hands out
    /// spy cores, and fails on demand.
    @MainActor
    private final class SessionScript {
        private(set) var requestedPaths: [String] = []
        private(set) var cores: [SpyCore] = []
        var failAll = false
        var thumbnailWriter: VideoThumbnailWriter?

        func makeSession(for item: ContentItem) -> PlayerCoordinator.Session? {
            requestedPaths.append(item.path)
            if failAll { return nil }
            let core = SpyCore()
            cores.append(core)
            let viewModel = PlayerViewModel(
                controller: core,
                thumbnailWriter: thumbnailWriter,
                thumbnailFacts: ThumbnailFileFacts(
                    sourceID: "test", path: item.path, fileSize: item.size, modified: nil
                )
            )
            return (core, viewModel)
        }
    }

    private func makeItem(_ path: String) -> ContentItem {
        ContentItem(
            name: (path as NSString).lastPathComponent,
            path: path, isDirectory: false, size: 1024, modifiedDate: nil
        )
    }

    private func makeWriter() -> VideoThumbnailWriter {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayerWindowCloseTests.\(UUID().uuidString)")
        return VideoThumbnailWriter(
            cache: CacheStore(rootDirectory: root, capacityBytes: 1_000_000, ttl: 60)
        )
    }

    private let reader: VideoStreamBridge.RangedReader = { _, _ in Data() }

    /// Suspends (yielding the main actor) until `condition` holds.
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("condition not met within the wait budget")
    }

    @Test("timed-out close drops the reference at once; a reopen gets a fresh window whose core the old teardown never touches")
    func timedOutCloseReopen() async {
        let script = SessionScript()
        script.thumbnailWriter = makeWriter()
        let coordinator = PlayerCoordinator(sessionFactory: script.makeSession)
        var sessionClosed = false
        coordinator.onSessionClosed = { sessionClosed = true }

        let itemA = makeItem("/a/a1.mkv")
        coordinator.open(items: [itemA], siblings: [], selectedPath: itemA.path, sourceID: "test", reader: reader)
        let windowA = try? #require(coordinator.windowController)
        let coreA = try? #require(script.cores.first)
        guard let windowA, let coreA else { return }
        #expect(coreA.loadCount == 1)

        // Arm the timed-out capture: persistProgressOnClose reports a
        // wedge, the rescue drive parks on the gate.
        let gate = HandshakeGate()
        coreA.stubCaptureDidTimeOut = true
        coreA.rescueGate = gate

        windowA.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        // The window-closed fact lands synchronously, rescue still parked.
        #expect(coordinator.windowController == nil)
        #expect(!coordinator.hasActiveSession)
        #expect(!sessionClosed)

        // Reopen inside the rescue gap: a fresh window on a fresh core.
        let itemB = makeItem("/b/b1.mkv")
        coordinator.open(items: [itemB], siblings: [], selectedPath: itemB.path, sourceID: "test", reader: reader)
        let windowB = try? #require(coordinator.windowController)
        guard let windowB else { return }
        #expect(windowB !== windowA)
        let coreB = try? #require(script.cores.last)
        guard let coreB else { return }
        #expect(coreB !== coreA)
        #expect(coreB.loadCount == 1)

        // The rescue finishes: only the outgoing core is torn down, and
        // the session-closed signal lands after the teardown.
        gate.open()
        await waitUntil { coreA.shutdownCount == 1 }
        #expect(coreA.shutdownCount == 1)
        #expect(coreB.shutdownCount == 0)
        #expect(sessionClosed)

        windowB.close()
    }

    @Test("clean close tears the core down synchronously and signals session end")
    func cleanClose() {
        let script = SessionScript()
        script.thumbnailWriter = makeWriter()
        let coordinator = PlayerCoordinator(sessionFactory: script.makeSession)
        var sessionClosed = false
        coordinator.onSessionClosed = { sessionClosed = true }

        let itemA = makeItem("/a/a1.mkv")
        coordinator.open(items: [itemA], siblings: [], selectedPath: itemA.path, sourceID: "test", reader: reader)
        guard let windowA = coordinator.windowController, let coreA = script.cores.first else {
            Issue.record("open did not install a session")
            return
        }

        windowA.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        #expect(coreA.shutdownCount == 1)
        #expect(sessionClosed)
        #expect(coordinator.windowController == nil)
    }

    @Test("a failed open leaves the previous playlist driving the transport")
    func failedOpenKeepsPlaylist() {
        let script = SessionScript()
        let coordinator = PlayerCoordinator(sessionFactory: script.makeSession)

        let a1 = makeItem("/a/a1.mkv")
        let a2 = makeItem("/a/a2.mkv")
        coordinator.open(items: [a1, a2], siblings: [], selectedPath: a1.path, sourceID: nil, reader: reader)
        guard let windowA = coordinator.windowController else {
            Issue.record("open did not install a session")
            return
        }
        #expect(script.requestedPaths == ["/a/a1.mkv"])

        // The follow-up open fails to build: the queue must not swap.
        script.failAll = true
        let b1 = makeItem("/b/b1.mkv")
        coordinator.open(items: [b1], siblings: [], selectedPath: b1.path, sourceID: nil, reader: reader)
        #expect(script.requestedPaths == ["/a/a1.mkv", "/b/b1.mkv"])
        #expect(coordinator.windowController === windowA)

        // Transport still walks the OLD playlist: next builds a2, not b1.
        script.failAll = false
        windowA.onNextTrack?()
        #expect(script.requestedPaths.last == "/a/a2.mkv")
        #expect(script.cores.last?.loadCount == 1)

        windowA.close()
    }
}
