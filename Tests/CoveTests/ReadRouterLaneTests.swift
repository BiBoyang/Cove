import Foundation
import SourceKit
import Testing
@testable import Cove

/// Minimal ContentSource double: every read returns a fixed payload so a
/// lane test can tell which source served the bytes.
private struct FakeLaneSource: ContentSource {
    let sourceID: String
    let payload: Data

    func connect() async throws {}
    func list(at path: String) async throws -> [ContentItem] { [] }
    func metadata(at path: String) async throws -> ContentItem {
        ContentItem(name: path, path: path, isDirectory: false, size: 0, modifiedDate: nil)
    }
    func read(at path: String, range: Range<Int64>) async throws -> Data { payload }
    func disconnect() async {}
}

@Suite("Read router lane")
struct ReadRouterLaneTests {
    @Test("a preheat-lane read uses the preheat source once it is installed")
    func preheatLaneServesFromPreheatSource() async throws {
        let main = SMBReadRouter()
        main.update(FakeLaneSource(sourceID: "main", payload: Data("main".utf8)))
        let preheat = SMBReadRouter()
        preheat.update(FakeLaneSource(sourceID: "preheat", payload: Data("preheat".utf8)))

        let data = try await preheat.read(at: "/a.jpg", fallback: main)

        #expect(data == Data("preheat".utf8))
    }

    @Test("a preheat-lane read falls back to the main lane while no preheat source is installed")
    func preheatLaneFallsBackToMainLane() async throws {
        let main = SMBReadRouter()
        main.update(FakeLaneSource(sourceID: "main", payload: Data("main".utf8)))
        let preheat = SMBReadRouter()

        let data = try await preheat.read(at: "/a.jpg", fallback: main)

        #expect(data == Data("main".utf8))
    }

    @Test("a lane read reports notConnected only when both lanes are empty")
    func bothLanesEmptyThrowsNotConnected() async throws {
        let main = SMBReadRouter()
        let preheat = SMBReadRouter()

        await #expect(throws: SourceError.notConnected) {
            try await preheat.read(at: "/a.jpg", fallback: main)
        }
    }
}
