import XCTest
@testable import ReaderKit

final class ReaderKitTests: XCTestCase {
    func testDocumentPreservesPageOrderAndIdentity() {
        let document = ReaderDocument(pages: [
            ReaderPage(id: "/chapter/2.jpg", title: "2.jpg"),
            ReaderPage(id: "/chapter/10.jpg", title: "10.jpg"),
        ])

        XCTAssertEqual(document.pages.map(\.id), ["/chapter/2.jpg", "/chapter/10.jpg"])
        XCTAssertEqual(document.pages.map(\.title), ["2.jpg", "10.jpg"])
    }

    func testEmptyDocumentIsRepresentableAndValidatedByCaller() {
        let document = ReaderDocument(pages: [])

        XCTAssertTrue(document.pages.isEmpty)
    }
}
