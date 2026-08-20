import XCTest
@testable import SourceKit

/// Records the ranges it is asked to read, so the tests can verify what the
/// protocol's default whole-file read actually delegates to.
private actor MockSource: ContentSource {
    let sourceID = "mock://source"

    private(set) var requestedRanges: [Range<Int64>] = []

    func connect() async throws {}

    func list(at path: String) async throws -> [ContentItem] { [] }

    func metadata(at path: String) async throws -> ContentItem {
        ContentItem(name: "file.bin", path: path, isDirectory: false, size: 3, modifiedDate: nil)
    }

    func read(at path: String, range: Range<Int64>) async throws -> Data {
        requestedRanges.append(range)
        return Data([1, 2, 3])
    }

    func disconnect() async {}
}

final class ContentSourceTests: XCTestCase {
    func testDefaultWholeFileReadDelegatesToRangedRead() async throws {
        let mock = MockSource()
        let data = try await mock.read(at: "/file.bin")
        XCTAssertEqual(data, Data([1, 2, 3]))
        let ranges = await mock.requestedRanges
        XCTAssertEqual(ranges, [0..<Int64.max])
    }

    func testSMBSourceIDIsHostAndShare() {
        let source = SMBSource(host: "nas.local", share: "media", username: "u", password: "p")
        XCTAssertEqual(source.sourceID, "smb://nas.local/media")
    }
}
