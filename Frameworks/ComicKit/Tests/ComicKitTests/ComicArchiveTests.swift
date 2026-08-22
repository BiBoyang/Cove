import Foundation
import XCTest
import ZIPFoundation
@testable import ComicKit

final class ComicArchiveTests: XCTestCase {
    /// Builds a real in-memory ZIP via ZIPFoundation's writer, so the read
    /// side is exercised against genuine archive bytes.
    private func makeArchiveBytes(entries: [(path: String, data: Data)]) throws -> Data {
        let archive = try Archive(data: Data(), accessMode: .create)
        for entry in entries {
            try archive.addEntry(
                with: entry.path,
                type: .file,
                uncompressedSize: Int64(entry.data.count)
            ) { (position: Int64, size: Int) in
                // The writer asks for (position, chunkSize) slices; clamp the
                // tail chunk to the actual byte count. (Explicit parameter
                // types pin the modern, non-deprecated addEntry overload.)
                let lower = Int(position)
                return entry.data.subdata(in: lower ..< min(lower + size, entry.data.count))
            }
        }
        return try XCTUnwrap(archive.data)
    }

    private func bytes(_ string: String) -> Data {
        Data(string.utf8)
    }

    func testImageEntriesAreFilteredAndNaturallySorted() throws {
        let data = try makeArchiveBytes(entries: [
            ("page10.jpg", bytes("ten")),
            ("notes.txt", bytes("text")),
            ("page2.jpg", bytes("two")),
            ("__MACOSX/page3.jpg", bytes("junk")),
            ("._page4.jpg", bytes("junk")),
            ("page1.png", bytes("one")),
            ("chapter/page5.webp", bytes("five")),
        ])
        let archive = try ComicArchive(data: data)
        XCTAssertEqual(
            archive.imageEntries,
            ["chapter/page5.webp", "page1.png", "page2.jpg", "page10.jpg"]
        )
    }

    func testExtractImageRoundTripsBytes() throws {
        let payload = Data((0 ..< 4096).map { UInt8($0 % 251) })
        let data = try makeArchiveBytes(entries: [
            ("page1.jpg", bytes("one")),
            ("page2.jpg", payload),
        ])
        let archive = try ComicArchive(data: data)
        XCTAssertEqual(try archive.extractImage(named: "page2.jpg"), payload)
    }

    func testExtractUnknownEntryThrows() throws {
        let data = try makeArchiveBytes(entries: [("page1.jpg", bytes("one"))])
        let archive = try ComicArchive(data: data)
        XCTAssertThrowsError(try archive.extractImage(named: "nope.jpg")) { error in
            XCTAssertEqual(error as? ComicArchiveError, .entryNotFound("nope.jpg"))
        }
    }

    func testUnreadableBytesThrow() {
        XCTAssertThrowsError(try ComicArchive(data: bytes("definitely not a zip archive"))) { error in
            XCTAssertEqual(error as? ComicArchiveError, .unreadableArchive)
        }
    }

    func testArchiveWithoutImagesThrows() throws {
        let data = try makeArchiveBytes(entries: [("notes.txt", bytes("text"))])
        XCTAssertThrowsError(try ComicArchive(data: data)) { error in
            XCTAssertEqual(error as? ComicArchiveError, .noImageEntries)
        }
    }
}
