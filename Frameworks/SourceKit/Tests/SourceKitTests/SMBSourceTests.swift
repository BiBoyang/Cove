import XCTest
@testable import SourceKit

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
}
