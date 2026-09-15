import Foundation
import SourceKit
import Testing
@testable import Cove

/// Minimal ContentSource double: every read returns a fixed payload so a
/// lane test can tell which source served the bytes; `listItems` does the
/// same for directory listings.
private struct FakeLaneSource: ContentSource {
    let sourceID: String
    let payload: Data
    var listItems: [ContentItem] = []

    func connect() async throws {}
    func list(at path: String) async throws -> [ContentItem] { listItems }
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

    @Test("a preheat-lane list uses the preheat source once it is installed")
    func preheatLaneListServesFromPreheatSource() async throws {
        let mainEntry = ContentItem(
            name: "main-item", path: "/listed-by-main", isDirectory: false, size: 0, modifiedDate: nil
        )
        let preheatEntry = ContentItem(
            name: "preheat-item", path: "/listed-by-preheat", isDirectory: false, size: 0, modifiedDate: nil
        )
        let main = SMBReadRouter()
        main.update(FakeLaneSource(sourceID: "main", payload: Data(), listItems: [mainEntry]))
        let preheat = SMBReadRouter()
        preheat.update(FakeLaneSource(sourceID: "preheat", payload: Data(), listItems: [preheatEntry]))

        let items = try await preheat.list(at: "/dir", fallback: main)

        #expect(items.map(\.path) == ["/listed-by-preheat"])
    }

    @Test("a preheat-lane list falls back to the main lane while no preheat source is installed")
    func preheatLaneListFallsBackToMainLane() async throws {
        let mainEntry = ContentItem(
            name: "main-item", path: "/listed-by-main", isDirectory: false, size: 0, modifiedDate: nil
        )
        let main = SMBReadRouter()
        main.update(FakeLaneSource(sourceID: "main", payload: Data(), listItems: [mainEntry]))
        let preheat = SMBReadRouter()

        let items = try await preheat.list(at: "/dir", fallback: main)

        #expect(items.map(\.path) == ["/listed-by-main"])
    }

    @Test("a lane list reports notConnected only when both lanes are empty")
    func bothLanesEmptyListThrowsNotConnected() async throws {
        let main = SMBReadRouter()
        let preheat = SMBReadRouter()

        await #expect(throws: SourceError.notConnected) {
            try await preheat.list(at: "/dir", fallback: main)
        }
    }
}
