import XCTest
@testable import SourceKit

final class SMBShareInfoTests: XCTestCase {
    func testBrowsableFilterDropsIPCAndDollarSuffixShares() {
        let shares = [
            SMBShareInfo(name: "media", comment: "Movies"),
            SMBShareInfo(name: "IPC$", comment: "Remote IPC"),
            SMBShareInfo(name: "C$", comment: "Default share"),
            SMBShareInfo(name: "ADMIN$", comment: ""),
            SMBShareInfo(name: "photos", comment: ""),
            SMBShareInfo(name: "time-machine", comment: "Backups"),
        ]
        let names = SMBShareInfo.browsable(shares).map(\.name)
        XCTAssertEqual(names, ["media", "photos", "time-machine"])
    }

    func testBrowsableFilterKeepsComments() {
        let shares = [SMBShareInfo(name: "media", comment: "Movies")]
        XCTAssertEqual(SMBShareInfo.browsable(shares).first?.comment, "Movies")
    }

    func testDollarSignInsideNameDoesNotMakeShareHidden() {
        XCTAssertTrue(SMBShareInfo(name: "my$share", comment: "").isBrowsable)
        XCTAssertFalse(SMBShareInfo(name: "share$", comment: "").isBrowsable)
        XCTAssertFalse(SMBShareInfo(name: "IPC$", comment: "").isBrowsable)
    }

    func testBrowsableFilterOnEmptyInput() {
        XCTAssertTrue(SMBShareInfo.browsable([]).isEmpty)
    }
}
