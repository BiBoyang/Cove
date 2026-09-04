import Foundation
import XCTest
@testable import SourceKit

final class TransientRetryTests: XCTestCase {
    private actor AttemptCounter {
        var count = 0
        func next() -> Int {
            count += 1
            return count
        }
    }

    func testRetriesOnceOnTransportError() async throws {
        let counter = AttemptCounter()
        let value = try await TransientRetry.run { () throws -> Int in
            if await counter.next() == 1 {
                throw POSIXError(.EIO)
            }
            return 42
        }
        XCTAssertEqual(value, 42)
        let attempts = await counter.count
        XCTAssertEqual(attempts, 2)
    }

    func testDoesNotRetryAuthFailures() async {
        let counter = AttemptCounter()
        do {
            _ = try await TransientRetry.run { () throws -> Int in
                _ = await counter.next()
                throw POSIXError(.EAUTH)
            }
            XCTFail("expected the auth error to surface")
        } catch let error as POSIXError {
            XCTAssertEqual(error.code, .EAUTH)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let attempts = await counter.count
        XCTAssertEqual(attempts, 1)
    }

    func testDoesNotRetryNonPosixErrors() async {
        struct PlainError: Error {}
        let counter = AttemptCounter()
        do {
            _ = try await TransientRetry.run { () throws -> Int in
                _ = await counter.next()
                throw PlainError()
            }
            XCTFail("expected the error to surface")
        } catch is PlainError {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let attempts = await counter.count
        XCTAssertEqual(attempts, 1)
    }

    func testDoesNotRetryTimeouts() async {
        let counter = AttemptCounter()
        do {
            _ = try await TransientRetry.run { () throws -> Int in
                _ = await counter.next()
                throw POSIXError(.ETIMEDOUT)
            }
            XCTFail("expected the timeout to surface without a retry")
        } catch let error as POSIXError {
            XCTAssertEqual(error.code, .ETIMEDOUT)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let attempts = await counter.count
        XCTAssertEqual(attempts, 1)
    }

    func testSurfacesTheSecondErrorWhenBothAttemptsFail() async {
        let counter = AttemptCounter()
        do {
            _ = try await TransientRetry.run { () throws -> Int in
                let attempt = await counter.next()
                throw POSIXError(attempt == 1 ? .EIO : .ECONNRESET)
            }
            XCTFail("expected the second error to surface after the retry")
        } catch let error as POSIXError {
            XCTAssertEqual(error.code, .ECONNRESET)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let attempts = await counter.count
        XCTAssertEqual(attempts, 2)
    }
}
