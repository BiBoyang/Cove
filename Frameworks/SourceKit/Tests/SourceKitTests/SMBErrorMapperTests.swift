import XCTest
@testable import SourceKit

final class SMBErrorMapperTests: XCTestCase {
    // MARK: - connectError

    func testConnectErrorMapsAuthFailures() {
        for code: POSIXErrorCode in [.EACCES, .EPERM, .EAUTH] {
            XCTAssertEqual(
                SMBErrorMapper.connectError(POSIXError(code), host: "h", resource: "s"),
                .authenticationFailed,
                "\(code) should map to authenticationFailed"
            )
        }
    }

    func testConnectErrorMapsMissingResource() {
        for code: POSIXErrorCode in [.ENOENT, .ENODEV] {
            XCTAssertEqual(
                SMBErrorMapper.connectError(POSIXError(code), host: "h", resource: "s"),
                .pathNotFound("s"),
                "\(code) should map to pathNotFound"
            )
        }
    }

    func testConnectErrorMapsNetworkFailures() {
        for code: POSIXErrorCode in [
            .ETIMEDOUT, .ECONNREFUSED, .EHOSTUNREACH, .ENETUNREACH,
            .ENOTCONN, .ECONNRESET, .EPIPE, .EHOSTDOWN,
        ] {
            guard case .connectionFailed =
                    SMBErrorMapper.connectError(POSIXError(code), host: "h", resource: "s") else {
                XCTFail("\(code) should map to connectionFailed")
                continue
            }
        }
    }

    func testConnectErrorFallsBackToConnectionFailed() {
        guard case .connectionFailed =
                SMBErrorMapper.connectError(POSIXError(.EIO), host: "h", resource: "s") else {
            return XCTFail("unhandled POSIX codes should map to connectionFailed")
        }
        struct NonPOSIX: Error {}
        guard case .connectionFailed =
                SMBErrorMapper.connectError(NonPOSIX(), host: "h", resource: "s") else {
            return XCTFail("non-POSIX errors should map to connectionFailed")
        }
    }

    // MARK: - pathError

    func testPathErrorMapsNotFoundAndPermission() {
        XCTAssertEqual(
            SMBErrorMapper.pathError(POSIXError(.ENOENT), path: "/a", operation: "list"),
            .pathNotFound("/a")
        )
        for code: POSIXErrorCode in [.EACCES, .EPERM] {
            XCTAssertEqual(
                SMBErrorMapper.pathError(POSIXError(code), path: "/a", operation: "read"),
                .permissionDenied("/a"),
                "\(code) should map to permissionDenied"
            )
        }
    }

    func testPathErrorMapsNetworkFailuresToConnectionFailed() {
        for code: POSIXErrorCode in [
            .ENOTCONN, .ETIMEDOUT, .ECONNRESET, .ECONNABORTED, .ENETDOWN,
            .ENETRESET, .EPIPE, .EHOSTUNREACH, .EHOSTDOWN, .ENETUNREACH,
        ] {
            guard case .connectionFailed =
                    SMBErrorMapper.pathError(POSIXError(code), path: "/a", operation: "read") else {
                XCTFail("\(code) should map to connectionFailed")
                continue
            }
        }
    }

    func testPathErrorFallsBackToOperationFailed() {
        guard case .operationFailed =
                SMBErrorMapper.pathError(POSIXError(.EIO), path: "/a", operation: "read") else {
            return XCTFail("unhandled POSIX codes should map to operationFailed")
        }
        struct NonPOSIX: Error {}
        guard case .operationFailed =
                SMBErrorMapper.pathError(NonPOSIX(), path: "/a", operation: "read") else {
            return XCTFail("non-POSIX errors should map to operationFailed")
        }
    }
}
