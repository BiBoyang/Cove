import Foundation

/// One transparent retry for transport-level connect failures.
///
/// Observed on real hardware: a connect issued within the first seconds of
/// process launch can fail with `EIO` (the socket dies mid-handshake) while
/// the same connect succeeds moments later. Rather than surface that as a
/// "connection failed" alert, retry once after a short delay. Only
/// transport errors qualify — authentication and path failures are
/// definitive and must come back immediately. `ETIMEDOUT` is deliberately
/// excluded: with the 15s connect timeout, a retry would only double the
/// wait for a blackholed host, while the remaining codes fail fast and a
/// retry is cheap.
enum TransientRetry {
    /// POSIX codes worth one retry: the socket/transport died before any
    /// credentials or paths were evaluated.
    private static let retryable: Set<POSIXErrorCode> = [
        .EIO, .ECONNRESET, .ECONNREFUSED, .ENOTCONN,
        .EHOSTUNREACH, .EHOSTDOWN, .ENETUNREACH, .EPIPE,
    ]

    private static let delayNanoseconds: UInt64 = 500_000_000

    /// Runs `operation`; on a retryable transport failure, waits ~0.5s and
    /// runs it once more. `operation` must be safely repeatable (build a
    /// fresh client per attempt — a failed libsmb2 context is destroyed).
    static func run<T>(_ operation: sending () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as POSIXError where retryable.contains(error.code) {
            try await Task.sleep(nanoseconds: delayNanoseconds)
            return try await operation()
        }
    }
}
