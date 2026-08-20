import XCTest
@testable import KeychainKit

final class KeychainKitTests: XCTestCase {
    // Unique service per run so repeated test runs never collide.
    private let service = "dev.biboyang.KeychainKitTests.\(UUID().uuidString)"
    private let account = "tester"

    override func tearDownWithError() throws {
        try? KeychainKit.deletePassword(service: service, account: account)
    }

    func testSaveReadDelete() throws {
        // Missing item reads as nil.
        XCTAssertNil(try KeychainKit.readPassword(service: service, account: account))

        try KeychainKit.savePassword("s3cret", service: service, account: account)
        XCTAssertEqual(try KeychainKit.readPassword(service: service, account: account), "s3cret")

        // Save overwrites.
        try KeychainKit.savePassword("upd4ted", service: service, account: account)
        XCTAssertEqual(try KeychainKit.readPassword(service: service, account: account), "upd4ted")

        try KeychainKit.deletePassword(service: service, account: account)
        XCTAssertNil(try KeychainKit.readPassword(service: service, account: account))

        // Deleting a missing item is not an error.
        XCTAssertNoThrow(try KeychainKit.deletePassword(service: service, account: account))
    }

    func testEmptyPasswordRoundTrips() throws {
        try KeychainKit.savePassword("", service: service, account: account)
        XCTAssertEqual(try KeychainKit.readPassword(service: service, account: account), "")
        try KeychainKit.deletePassword(service: service, account: account)
    }
}
