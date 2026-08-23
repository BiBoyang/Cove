import XCTest
@testable import SourceKit

final class LocalFileSourceTests: XCTestCase {
    private var root: URL!
    private var source: LocalFileSource!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFileSourceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Fixture: a.txt at the root, a sub directory with b.bin, plus
        // noise that listings must hide.
        try Data("hello".utf8).write(to: root.appendingPathComponent("a.txt"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub"), withIntermediateDirectories: true
        )
        try Data([0, 1, 2, 3, 4, 5, 6, 7]).write(to: root.appendingPathComponent("sub/b.bin"))
        try Data("junk".utf8).write(to: root.appendingPathComponent(".DS_Store"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("__MACOSX"), withIntermediateDirectories: true
        )
        source = LocalFileSource(root: root)
        try await source.connect()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSourceIDDefaultsToVaultScheme() {
        XCTAssertEqual(source.sourceID, "vault://")
        XCTAssertEqual(LocalFileSource(root: root, sourceID: "local://x").sourceID, "local://x")
    }

    func testListRootMapsFilesAndFiltersNoise() async throws {
        let items = try await source.list(at: "/")
        XCTAssertEqual(Set(items.map(\.name)), ["a.txt", "sub"])

        let file = try XCTUnwrap(items.first { $0.name == "a.txt" })
        XCTAssertEqual(file.path, "/a.txt")
        XCTAssertFalse(file.isDirectory)
        XCTAssertEqual(file.size, 5)
        XCTAssertNotNil(file.modifiedDate)
        XCTAssertEqual(file.fileType, .text)

        let directory = try XCTUnwrap(items.first { $0.name == "sub" })
        XCTAssertEqual(directory.path, "/sub")
        XCTAssertTrue(directory.isDirectory)
        XCTAssertEqual(directory.size, 0)
    }

    func testListSubdirectory() async throws {
        let items = try await source.list(at: "/sub")
        XCTAssertEqual(items.map(\.path), ["/sub/b.bin"])
    }

    func testListMissingPathThrowsNotFound() async {
        do {
            _ = try await source.list(at: "/nope")
            XCTFail("expected pathNotFound")
        } catch {
            XCTAssertEqual(error as? SourceError, .pathNotFound("/nope"))
        }
    }

    func testListOnMissingRootIsEmpty() async throws {
        let missing = LocalFileSource(root: root.appendingPathComponent("not-created-yet"))
        try await missing.connect()
        let items = try await missing.list(at: "/")
        XCTAssertTrue(items.isEmpty)
    }

    func testConnectRejectsNonDirectoryRoot() async {
        let fileRoot = LocalFileSource(root: root.appendingPathComponent("a.txt"))
        do {
            try await fileRoot.connect()
            XCTFail("expected connect to fail for a file root")
        } catch {
            guard case .operationFailed = error as? SourceError else {
                return XCTFail("expected operationFailed, got \(error)")
            }
        }
    }

    func testMetadata() async throws {
        let item = try await source.metadata(at: "/sub/b.bin")
        XCTAssertEqual(item.name, "b.bin")
        XCTAssertEqual(item.path, "/sub/b.bin")
        XCTAssertFalse(item.isDirectory)
        XCTAssertEqual(item.size, 8)
    }

    func testWholeFileReadUsesOpenEndedRange() async throws {
        let data = try await source.read(at: "/a.txt")
        XCTAssertEqual(data, Data("hello".utf8))
    }

    func testRangedRead() async throws {
        let data = try await source.read(at: "/sub/b.bin", range: 2..<5)
        XCTAssertEqual(data, Data([2, 3, 4]))
    }

    func testRangedReadPastEOFTruncates() async throws {
        let data = try await source.read(at: "/a.txt", range: 3..<100)
        XCTAssertEqual(data, Data("lo".utf8))
    }

    func testReadMissingFileThrowsNotFound() async {
        do {
            _ = try await source.read(at: "/nope.bin")
            XCTFail("expected pathNotFound")
        } catch {
            XCTAssertEqual(error as? SourceError, .pathNotFound("/nope.bin"))
        }
    }

    func testPathEscapingRootIsDenied() async {
        do {
            _ = try await source.read(at: "/../outside.txt")
            XCTFail("expected permissionDenied")
        } catch {
            guard case .permissionDenied = error as? SourceError else {
                return XCTFail("expected permissionDenied, got \(error)")
            }
        }
    }
}
