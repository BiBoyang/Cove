import Foundation
import SourceKit
import Synchronization
import Testing
@testable import Cove

/// Two-phase rendezvous for driving connect/disconnect interleavings: the
/// fake handshake announces it started, then parks until `open()`.
final class HandshakeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private var didEnter = false
    private var isOpen = false

    /// Resolves once the fake handshake has begun (and is now parked).
    func waitUntilEntered() async {
        let ready: Bool = lock.withLock { didEnter }
        if ready { return }
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                if didEnter {
                    return true
                }
                entered = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// Called by the fake handshake: signals entry, parks until `open()`.
    func park() async {
        lock.withLock {
            didEnter = true
            entered?.resume()
            entered = nil
        }
        let ready: Bool = lock.withLock { isOpen }
        if ready { return }
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                if isOpen {
                    return true
                }
                release = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        lock.withLock {
            isOpen = true
            release?.resume()
            release = nil
        }
    }
}

/// A content source whose handshake parks on a gate so tests can interleave
/// a disconnect or a second connect mid-flight.
private actor FakeContentSource: ContentSource {
    nonisolated let sourceID: String
    private let gate: HandshakeGate?
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0

    init(sourceID: String, gate: HandshakeGate? = nil) {
        self.sourceID = sourceID
        self.gate = gate
    }

    func connect() async throws {
        connectCount += 1
        await gate?.park()
    }

    func disconnect() async {
        disconnectCount += 1
    }

    func list(at path: String) async throws -> [ContentItem] { [] }

    func metadata(at path: String) async throws -> ContentItem {
        ContentItem(name: path, path: path, isDirectory: false, size: 0, modifiedDate: nil)
    }

    func read(at path: String, range: Range<Int64>) async throws -> Data { Data() }
}

@Suite("SMB session service reentrancy")
@MainActor
struct SMBSessionServiceTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "SMBSessionServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeServer() -> ServerConfig {
        // Loopback: the preheat reconnect fired by a successful connect
        // fails fast (connection refused) instead of riding out a timeout.
        ServerConfig(id: UUID(), host: "127.0.0.1", username: "user")
    }

    @Test("connect resuming after disconnect tears down and stays disconnected")
    func connectResumingAfterDisconnect() async throws {
        let gate = HandshakeGate()
        let fake = FakeContentSource(sourceID: "fake://a", gate: gate)
        let service = SMBSessionService(
            store: ServerStore(defaults: makeDefaults()),
            sourceFactory: { _, _, _, _ in fake },
            passwordProvider: { _ in "password" }
        )

        let connectTask = Task { try await service.connect(to: makeServer(), share: "media") }
        await gate.waitUntilEntered()
        // The explicit disconnect lands while the handshake is parked.
        await service.disconnect()
        gate.open()

        do {
            try await connectTask.value
            Issue.record("a stale connect must not report success")
        } catch is CancellationError {
            // Expected: the attempt found its intent superseded.
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }

        #expect(service.currentSourceID == nil)
        // The session the stale attempt built was torn down by itself.
        let disconnects = await fake.disconnectCount
        #expect(disconnects == 1)
    }

    @Test("connect parked while a newer connect lands never overwrites it")
    func connectParkedThenNewerConnect() async throws {
        let gate = HandshakeGate()
        let fakeA = FakeContentSource(sourceID: "fake://a", gate: gate)
        let fakeB = FakeContentSource(sourceID: "fake://b")
        let callCount = Mutex(0)
        let service = SMBSessionService(
            store: ServerStore(defaults: makeDefaults()),
            sourceFactory: { _, _, _, _ in
                let n = callCount.withLock { count -> Int in
                    count += 1
                    return count
                }
                return n == 1 ? fakeA : fakeB
            },
            passwordProvider: { _ in "password" }
        )

        let connectA = Task { try await service.connect(to: makeServer(), share: "media") }
        await gate.waitUntilEntered()
        // The newer connect wins while A's handshake is parked.
        try await service.connect(to: makeServer(), share: "media")
        gate.open()

        do {
            try await connectA.value
            Issue.record("the superseded connect must not report success")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }

        #expect(service.currentSourceID == "fake://b")
        // A's just-built session was torn down; B was never disconnected.
        let disconnectsA = await fakeA.disconnectCount
        let disconnectsB = await fakeB.disconnectCount
        #expect(disconnectsA == 1)
        #expect(disconnectsB == 0)
    }

    @Test("a plain successful connect installs the source")
    func successfulConnect() async throws {
        let fake = FakeContentSource(sourceID: "fake://only")
        let service = SMBSessionService(
            store: ServerStore(defaults: makeDefaults()),
            sourceFactory: { _, _, _, _ in fake },
            passwordProvider: { _ in "password" }
        )

        try await service.connect(to: makeServer(), share: "media")

        #expect(service.currentSourceID == "fake://only")
        let disconnects = await fake.disconnectCount
        #expect(disconnects == 0)
    }
}
