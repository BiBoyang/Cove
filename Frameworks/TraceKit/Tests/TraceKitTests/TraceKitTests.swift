import XCTest
@testable import TraceKit

final class TraceKitTests: XCTestCase {
    func testSubsystemConstant() {
        XCTAssertEqual(Trace.subsystem, "com.biboyang.cove")
    }

    func testLoggerSmoke() {
        let logger = TraceLogger(category: "tests")
        XCTAssertEqual(logger.category, "tests")
        // Smoke: every level must be callable without crashing.
        logger.debug("debug smoke")
        logger.info("info smoke")
        logger.notice("notice smoke")
        logger.error("error smoke")
        logger.fault("fault smoke")
    }

    func testCustomSubsystem() {
        let logger = TraceLogger(subsystem: "dev.test.custom", category: "c")
        XCTAssertEqual(logger.category, "c")
    }
}
