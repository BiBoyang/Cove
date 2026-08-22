import Foundation
import SourceKit
import XCTest
@testable import PreheatKit

final class FolderEnumeratorTests: XCTestCase {
    /// The mock tree used by most tests:
    /// ```
    /// /root: a.jpg, sub1/, .DS_Store, ._x.jpg, note.txt
    /// /root/sub1: b.png, sub2/
    /// /root/sub1/sub2: c.gif
    /// ```
    private func makeListing() -> [String: [ContentItem]] {
        func file(_ name: String, _ path: String) -> ContentItem {
            ContentItem(name: name, path: path, isDirectory: false, size: 10, modifiedDate: nil)
        }
        func directory(_ name: String, _ path: String) -> ContentItem {
            ContentItem(name: name, path: path, isDirectory: true, size: 0, modifiedDate: nil)
        }
        return [
            "/root": [
                file("a.jpg", "/root/a.jpg"),
                directory("sub1", "/root/sub1"),
                file(".DS_Store", "/root/.DS_Store"),
                file("._x.jpg", "/root/._x.jpg"),
                file("note.txt", "/root/note.txt"),
            ],
            "/root/sub1": [
                file("b.png", "/root/sub1/b.png"),
                directory("sub2", "/root/sub1/sub2"),
            ],
            "/root/sub1/sub2": [
                file("c.gif", "/root/sub1/sub2/c.gif"),
            ],
        ]
    }

    func testCollectsImagesBreadthFirstSkippingHiddenAndNonImages() async throws {
        let source = MockSource(listings: makeListing())
        let images = try await FolderEnumerator.collectImages(source: source, root: "/root")
        XCTAssertEqual(images.map(\.path), ["/root/a.jpg", "/root/sub1/b.png", "/root/sub1/sub2/c.gif"])
    }

    func testRootWithoutLeadingSlashIsNormalized() async throws {
        let source = MockSource(listings: makeListing())
        let images = try await FolderEnumerator.collectImages(source: source, root: "root")
        XCTAssertEqual(images.count, 3)
    }

    func testRootListingFailureThrows() async {
        let source = MockSource(listings: [:])
        do {
            _ = try await FolderEnumerator.collectImages(source: source, root: "/nope")
            XCTFail("an unreadable root must throw")
        } catch {
            XCTAssertEqual(error as? SourceError, .pathNotFound("/nope"))
        }
    }

    func testUnreadableSubdirectoryIsSkipped() async throws {
        var listings = makeListing()
        listings["/root"]!.append(
            ContentItem(name: "broken", path: "/root/broken", isDirectory: true, size: 0, modifiedDate: nil)
        )
        let source = MockSource(listings: listings)
        let images = try await FolderEnumerator.collectImages(source: source, root: "/root")
        XCTAssertEqual(images.map(\.path), ["/root/a.jpg", "/root/sub1/b.png", "/root/sub1/sub2/c.gif"])
    }

    func testMaxFilesCapStopsCollection() async throws {
        let source = MockSource(listings: makeListing())
        let images = try await FolderEnumerator.collectImages(source: source, root: "/root", maxFiles: 1)
        XCTAssertEqual(images.map(\.path), ["/root/a.jpg"])
    }

    func testMaxDirectoriesCapStopsTraversal() async throws {
        // A chain of nested directories deeper than the cap; no images.
        var listings: [String: [ContentItem]] = [:]
        for depth in 0..<10 {
            let path = depth == 0 ? "/root" : "/root/" + (1...depth).map { "d\($0)" }.joined(separator: "/")
            let childName = "d\(depth + 1)"
            listings[path] = [
                ContentItem(name: childName, path: path + "/" + childName, isDirectory: true, size: 0, modifiedDate: nil),
            ]
        }
        let source = MockSource(listings: listings)
        let images = try await FolderEnumerator.collectImages(source: source, root: "/root", maxDirectories: 3)
        XCTAssertTrue(images.isEmpty)
        // 3 directories visited, traversal stopped there — the mock would
        // have thrown (and failed the test) on a 4th distinct listing... the
        // enumerator swallows subdirectory errors, so instead assert via the
        // shallower cap variant below that still finds images.
        let cappedWithImages = MockSource(listings: makeListing())
        let partial = try await FolderEnumerator.collectImages(
            source: cappedWithImages, root: "/root", maxDirectories: 2
        )
        // Visited /root and /root/sub1, never /root/sub1/sub2.
        XCTAssertEqual(partial.map(\.path), ["/root/a.jpg", "/root/sub1/b.png"])
    }
}
