import XCTest
@testable import ComicKit

final class NaturalSortTests: XCTestCase {
    func testNumericRunsOrderByValue() {
        XCTAssertEqual(
            ["page10.jpg", "page2.jpg", "page1.jpg"].sorted(by: NaturalSort.areInIncreasingOrder),
            ["page1.jpg", "page2.jpg", "page10.jpg"]
        )
    }

    func testNumericRunsInsidePathPrefixes() {
        XCTAssertEqual(
            NaturalSort.compare("ch2/p10.jpg", "ch10/p1.jpg"),
            .orderedAscending
        )
    }

    func testCaseInsensitive() {
        XCTAssertEqual(NaturalSort.compare("Page2.JPG", "page10.jpg"), .orderedAscending)
    }

    func testNumericTieFallsBackToLiteralOrder() {
        // Same numeric value ("01" vs "1"): a deterministic tiebreak keeps
        // the order total (Swift's sort is unstable).
        XCTAssertEqual(NaturalSort.compare("a01.jpg", "a1.jpg"), .orderedAscending)
        XCTAssertEqual(NaturalSort.compare("a1.jpg", "a01.jpg"), .orderedDescending)
        XCTAssertEqual(NaturalSort.compare("a1.jpg", "a1.jpg"), .orderedSame)
    }

    func testPlainLexicographicOrderWithoutDigits() {
        XCTAssertEqual(NaturalSort.compare("alpha", "beta"), .orderedAscending)
        XCTAssertEqual(NaturalSort.compare("beta", "alpha"), .orderedDescending)
    }
}
