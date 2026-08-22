import XCTest
@testable import CacheKit

final class CacheKeyTests: XCTestCase {
    private let base = CacheKey(
        sourceID: "smb://nas/photos",
        path: "/2024/cat.jpg",
        fileSize: 123_456,
        modifiedTimestamp: Date(timeIntervalSince1970: 1_700_000_000),
        variant: "raw"
    )

    func testFileNameIsStable() {
        let twin = CacheKey(
            sourceID: base.sourceID,
            path: base.path,
            fileSize: base.fileSize,
            modifiedTimestamp: base.modifiedTimestamp,
            variant: base.variant
        )
        XCTAssertEqual(base.fileName, twin.fileName)
    }

    func testFileNameFormat() {
        XCTAssertEqual(base.fileName.count, 64)
        XCTAssertTrue(base.fileName.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testFileNameChangesWithEveryField() {
        XCTAssertNotEqual(
            base.fileName,
            CacheKey(
                sourceID: "smb://other/photos",
                path: base.path,
                fileSize: base.fileSize,
                modifiedTimestamp: base.modifiedTimestamp,
                variant: base.variant
            ).fileName
        )
        XCTAssertNotEqual(
            base.fileName,
            CacheKey(
                sourceID: base.sourceID,
                path: "/2024/dog.jpg",
                fileSize: base.fileSize,
                modifiedTimestamp: base.modifiedTimestamp,
                variant: base.variant
            ).fileName
        )
        XCTAssertNotEqual(
            base.fileName,
            CacheKey(
                sourceID: base.sourceID,
                path: base.path,
                fileSize: base.fileSize + 1,
                modifiedTimestamp: base.modifiedTimestamp,
                variant: base.variant
            ).fileName
        )
        XCTAssertNotEqual(
            base.fileName,
            CacheKey(
                sourceID: base.sourceID,
                path: base.path,
                fileSize: base.fileSize,
                modifiedTimestamp: base.modifiedTimestamp.addingTimeInterval(1),
                variant: base.variant
            ).fileName
        )
        XCTAssertNotEqual(
            base.fileName,
            CacheKey(
                sourceID: base.sourceID,
                path: base.path,
                fileSize: base.fileSize,
                modifiedTimestamp: base.modifiedTimestamp,
                variant: "2048px"
            ).fileName
        )
    }

    func testFieldBoundariesCannotShift() {
        // Separator injection must not alias another key.
        let injected = CacheKey(
            sourceID: "smb://nas/photos\u{1F}/2024/cat.jpg",
            path: "",
            fileSize: base.fileSize,
            modifiedTimestamp: base.modifiedTimestamp,
            variant: base.variant
        )
        XCTAssertNotEqual(base.fileName, injected.fileName)
    }
}
