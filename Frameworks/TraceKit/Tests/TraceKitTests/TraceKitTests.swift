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

    func testPrivacyLevelsSmoke() {
        let logger = TraceLogger(category: "tests")
        // Smoke: explicit privacy levels must be callable without crashing.
        logger.info("public smoke", privacy: .public)
        logger.info("private smoke", privacy: .private)
        logger.error("sensitive smoke", privacy: .sensitive)
    }

    func testCustomSubsystem() {
        let logger = TraceLogger(subsystem: "dev.test.custom", category: "c")
        XCTAssertEqual(logger.category, "c")
    }
}
