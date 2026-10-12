import AMSMB2
import Synchronization
import XCTest
@testable import SourceKit

/// Two-phase rendezvous for driving connect/disconnect interleavings: the
/// fake handshake announces it started, then parks until `open()`.
private final class HandshakeGate: @unchecked Sendable {
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

final class SMBSourceTests: XCTestCase {
    // MARK: - metadata field mapping

    func testContentItemMappingFromAttributes() {
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let attributes: [URLResourceKey: Any] = [
            .nameKey: "movie.mkv",
            .isDirectoryKey: true,
            .fileSizeKey: NSNumber(value: 1_234_567),
            .contentModificationDateKey: modified,
        ]
        let item = SMBSource.contentItem(from: attributes, path: "/videos/movie.mkv")
        XCTAssertEqual(item.name, "movie.mkv")
        XCTAssertEqual(item.path, "/videos/movie.mkv")
        XCTAssertTrue(item.isDirectory)
        XCTAssertEqual(item.size, 1_234_567)
        XCTAssertEqual(item.modifiedDate, modified)
    }

    func testContentItemMappingFallsBackToPathComponent() {
        let item = SMBSource.contentItem(from: [:], path: "/videos/clip.mp4")
        XCTAssertEqual(item.name, "clip.mp4")
        XCTAssertEqual(item.path, "/videos/clip.mp4")
        XCTAssertFalse(item.isDirectory)
        XCTAssertEqual(item.size, 0)
        XCTAssertNil(item.modifiedDate)
    }

    func testListMappingKeepsPrecomposedNamesByteForByte() {
        // NFC (precomposed) name, as stored on the server. AMSMB2's
        // `.pathKey` would hand back an NFD-normalized path that the server
        // cannot resolve; our mapping must preserve the raw name bytes.
        let nfcName = "\u{B8E8}\u{C5A3}-test.mp4"
        let entries: [[URLResourceKey: Any]] = [[
            .nameKey: nfcName,
            .isDirectoryKey: false,
            .fileSizeKey: NSNumber(value: 42),
        ]]
        let items = SMBSource.contentItems(from: entries, base: "/")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].path, "/\u{B8E8}\u{C5A3}-test.mp4")
        XCTAssertEqual(Array(items[0].path.utf8), Array("/\(nfcName)".utf8))
    }

    // MARK: - Actor regression: unconnected source under concurrent access

    /// list/read/metadata/disconnect fired concurrently at a source that was
    /// never connected must each throw `notConnected` or return cleanly —
    /// and must not crash or deadlock. (True racing semantics need a real
    /// NAS; here we verify the absence of crashes and data races, e.g. under
    /// the thread sanitizer.)
    func testUnconnectedSourceSurvivesConcurrentAccess() async {
        let source = SMBSource(host: "192.0.2.1", share: "media", username: "u", password: "p")
        await withTaskGroup(of: SourceError?.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    do {
                        _ = try await source.list(at: "/")
                        return nil
                    } catch let error as SourceError {
                        return error
                    } catch {
                        return nil
                    }
                }
                group.addTask {
                    do {
                        _ = try await source.read(at: "/file.bin")
                        return nil
                    } catch let error as SourceError {
                        return error
                    } catch {
                        return nil
                    }
                }
                group.addTask {
                    do {
                        _ = try await source.metadata(at: "/file.bin")
                        return nil
                    } catch let error as SourceError {
                        return error
                    } catch {
                        return nil
                    }
                }
                group.addTask {
                    await source.disconnect()
                    return nil
                }
            }
            for await error in group {
                if let error {
                    XCTAssertEqual(error, .notConnected)
                }
            }
        }

        // After the storm the source is still in a sane state: operations
        // keep failing with notConnected and disconnect stays idempotent.
        await source.disconnect()
        do {
            _ = try await source.list(at: "/")
            XCTFail("list on a never-connected source must throw")
        } catch let error as SourceError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - connect/disconnect reentrancy (actor-level generation guard)

    private static func makeOfflineClient(url: URL, credential: URLCredential) throws -> SMB2Manager {
        // Construction alone never touches the network — the handshake does.
        try XCTUnwrap(SMB2Manager(url: url, credential: credential))
    }

    func testConnectResumingAfterDisconnectDiscardsSession() async throws {
        let source = SMBSource(host: "192.0.2.1", share: "media", username: "u", password: "p")
        let gate = HandshakeGate()
        await source.setMakeClientOverride { url, credential in
            await gate.park()
            return try Self.makeOfflineClient(url: url, credential: credential)
        }

        let connectTask = Task { try await source.connect() }
        await gate.waitUntilEntered()
        // The disconnect lands while the handshake is parked.
        await source.disconnect()
        gate.open()

        do {
            try await connectTask.value
            XCTFail("a stale connect must not report success")
        } catch is CancellationError {
            // Expected: the attempt found its intent superseded.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        // No session was resurrected: reads still report not-connected.
        do {
            _ = try await source.list(at: "/")
            XCTFail("list must fail without a session")
        } catch let error as SourceError {
            XCTAssertEqual(error, .notConnected)
        }
    }

    func testConcurrentConnectsLetTheNewerWin() async throws {
        let source = SMBSource(host: "192.0.2.1", share: "media", username: "u", password: "p")
        let gate = HandshakeGate()
        let callCount = Mutex(0)
        await source.setMakeClientOverride { url, credential in
            let first = callCount.withLock { count -> Bool in
                count += 1
                return count == 1
            }
            if first {
                await gate.park()
            }
            return try Self.makeOfflineClient(url: url, credential: credential)
        }

        let firstConnect = Task { try await source.connect() }
        await gate.waitUntilEntered()
        // The second connect supersedes the parked first one.
        try await source.connect()
        gate.open()

        do {
            try await firstConnect.value
            XCTFail("the superseded connect must not report success")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        // A session exists (the newer connect's): the wire-level failure
        // proves the read reached a live client instead of bouncing off
        // `requireClient` with notConnected.
        do {
            _ = try await source.list(at: "/")
            XCTFail("list without a server must fail")
        } catch let error as SourceError {
            XCTAssertNotEqual(error, .notConnected)
        } catch {
            // Non-SourceError wire failure: also proves a client exists.
        }
    }

    func testDisconnectDuringRetryBackoffAbortsConnect() async throws {
        let source = SMBSource(host: "192.0.2.1", share: "media", username: "u", password: "p")
        let attempts = Mutex(0)
        // The gate is pre-opened: park() signals the attempt without blocking.
        let attempted = HandshakeGate()
        attempted.open()
        await source.setMakeClientOverride { _, _ in
            attempts.withLock { $0 += 1 }
            await attempted.park()
            throw POSIXError(.EIO) // retryable transport failure
        }

        let connectTask = Task { try await source.connect() }
        await attempted.waitUntilEntered()
        // The disconnect lands while the retry is in its backoff sleep.
        await source.disconnect()

        do {
            try await connectTask.value
            XCTFail("a superseded connect must not report success")
        } catch is CancellationError {
            // Expected: the stale hook aborted the retry.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        // The backoff never burned a second attempt.
        XCTAssertEqual(attempts.withLock { $0 }, 1)
    }
}
