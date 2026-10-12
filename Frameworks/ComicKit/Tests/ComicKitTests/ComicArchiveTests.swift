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

    // MARK: - Untrusted-size hardening

    /// Patches the uncompressed-size fields of the single-entry archive's
    /// local file header (offset 22 after the `PK\\x03\\x04` signature) and
    /// central directory record (offset 24 after `PK\\x01\\x02`) to `value`,
    /// simulating a hostile or corrupted ZIP header. Sizes are patched
    /// in place (UInt32, little-endian) so the archive stays parseable.
    private func patchingDeclaredUncompressedSize(of data: Data, to value: UInt32) -> Data {
        var bytes = [UInt8](data)
        let patches: [(signature: [UInt8], offset: Int)] = [
            ([0x50, 0x4B, 0x03, 0x04], 22), // local file header
            ([0x50, 0x4B, 0x01, 0x02], 24), // central directory
        ]
        for (signature, offset) in patches {
            guard let start = bytes.firstRange(of: signature) else {
                XCTFail("fixture is missing its ZIP signature")
                continue
            }
            let field = start.lowerBound + offset
            bytes[field] = UInt8(value & 0xFF)
            bytes[field + 1] = UInt8((value >> 8) & 0xFF)
            bytes[field + 2] = UInt8((value >> 16) & 0xFF)
            bytes[field + 3] = UInt8((value >> 24) & 0xFF)
        }
        return Data(bytes)
    }

    func testExtractRejectsHeaderClaimingFourGigabytes() throws {
        let payload = bytes("small real content")
        let data = patchingDeclaredUncompressedSize(
            of: try makeArchiveBytes(entries: [("page1.jpg", payload)]),
            to: 0xFFFFFFFF // ~4 GB declared: above the 512 MiB cap
        )
        let archive = try ComicArchive(data: data)
        XCTAssertThrowsError(try archive.extractImage(named: "page1.jpg")) { error in
            XCTAssertEqual(error as? ComicArchiveError, .entryTooLarge("page1.jpg"))
        }
    }

    func testExtractRejectsDeclaredSmallButActuallyLarger() throws {
        // Lower the cap so the running-total guard is exercised without
        // decompressing real hundreds of megabytes.
        ComicArchive.setEntrySizeCapOverrideForTesting(1024)
        defer { ComicArchive.setEntrySizeCapOverrideForTesting(nil) }
        let payload = Data(repeating: 0x61, count: 8192)
        // Deflate, not stored: the extractor sizes a stored read by the
        // declared field, but a compressed entry inflates its whole stream —
        // this is the realistic zip-bomb shape. The patched header claims
        // 512 bytes (under the cap) while the stream really inflates to
        // 8 KB, tripping the running total mid-extraction.
        let writable = try Archive(data: Data(), accessMode: .create)
        try writable.addEntry(
            with: "page1.jpg",
            type: .file,
            uncompressedSize: Int64(payload.count),
            compressionMethod: .deflate
        ) { (position: Int64, size: Int) in
            let lower = Int(position)
            return payload.subdata(in: lower ..< min(lower + size, payload.count))
        }
        let compressed = try XCTUnwrap(writable.data)
        let data = patchingDeclaredUncompressedSize(of: compressed, to: 512)
        let archive = try ComicArchive(data: data)
        XCTAssertThrowsError(try archive.extractImage(named: "page1.jpg")) { error in
            XCTAssertEqual(error as? ComicArchiveError, .entryTooLarge("page1.jpg"))
        }
    }

    func testDuplicateEntryNamesKeepFirstOccurrenceOnly() throws {
        let data = try makeArchiveBytes(entries: [
            ("page1.jpg", bytes("first")),
            ("page2.jpg", bytes("two")),
            ("page1.jpg", bytes("second")),
        ])
        let archive = try ComicArchive(data: data)
        XCTAssertEqual(archive.imageEntries, ["page1.jpg", "page2.jpg"])
        XCTAssertEqual(try archive.extractImage(named: "page1.jpg"), bytes("first"))
    }
}
