import XCTest
@testable import SourceKit

final class ContentItemTests: XCTestCase {
    private func item(_ name: String, isDirectory: Bool = false) -> ContentItem {
        ContentItem(name: name, path: "/\(name)", isDirectory: isDirectory, size: 42, modifiedDate: nil)
    }

    func testFileTypeClassification() {
        XCTAssertEqual(item("movie.MKV").fileType, .video)
        XCTAssertEqual(item("clip.mp4").fileType, .video)
        XCTAssertEqual(item("photo.HEIC").fileType, .image)
        XCTAssertEqual(item("scan.png").fileType, .image)
        XCTAssertEqual(item("raw.CR2").fileType, .image)
        XCTAssertEqual(item("raw.cr3").fileType, .image)
        XCTAssertEqual(item("raw.NEF").fileType, .image)
        XCTAssertEqual(item("raw.arw").fileType, .image)
        XCTAssertEqual(item("raw.DNG").fileType, .image)
        XCTAssertEqual(item("raw.raf").fileType, .image)
        XCTAssertEqual(item("raw.ORF").fileType, .image)
        XCTAssertEqual(item("raw.rw2").fileType, .image)
        XCTAssertEqual(item("photo.JFIF").fileType, .image)
        XCTAssertEqual(item("photo.jpe").fileType, .image)
        XCTAssertEqual(item("doc.pdf").fileType, .pdf)
        XCTAssertEqual(item("notes.txt").fileType, .text)
        XCTAssertEqual(item("subs.srt").fileType, .text)
        XCTAssertEqual(item("archive.cbz").fileType, .comic)
        XCTAssertEqual(item("archive.CBZ").fileType, .comic)
        // Only CBZ is supported; RAR/TAR comic archives stay unclassified.
        XCTAssertEqual(item("archive.cbr").fileType, .other)
        XCTAssertEqual(item("archive.cbt").fileType, .other)
        XCTAssertEqual(item("noextension").fileType, .other)
    }

    func testDirectoriesAreNotClassified() {
        XCTAssertNil(item("Movies", isDirectory: true).fileType)
    }

    func testStoredFields() {
        let date = Date(timeIntervalSince1970: 1_000)
        let entry = ContentItem(name: "a.txt", path: "/docs/a.txt", isDirectory: false, size: 7, modifiedDate: date)
        XCTAssertEqual(entry.name, "a.txt")
        XCTAssertEqual(entry.path, "/docs/a.txt")
        XCTAssertFalse(entry.isDirectory)
        XCTAssertEqual(entry.size, 7)
        XCTAssertEqual(entry.modifiedDate, date)
    }

    func testSourceErrorDescriptions() {
        // Smoke: every case renders a non-empty description.
        for error in [
            SourceError.notConnected,
            .connectionFailed("x"),
            .authenticationFailed,
            .pathNotFound("/x"),
            .permissionDenied("/x"),
            .operationFailed("x"),
        ] {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }
}
