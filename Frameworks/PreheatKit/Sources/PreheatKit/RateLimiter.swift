import Foundation

/// Token-bucket rate limiter with debt: a charge may exceed the current
/// allowance, and the caller then sleeps off the negative balance before
/// spending. Pure state machine — time is injected, so tests never sleep.
struct RateLimiter: Sendable {
    /// Refill rate in bytes per second.
    let bytesPerSecond: Double
    /// Remaining spendable bytes; negative while in debt.
    private(set) var allowance: Double
    /// Last time the bucket was refilled (seconds since 1970).
    private var lastTick: TimeInterval

    init(bytesPerSecond: Int64, now: TimeInterval) {
        self.bytesPerSecond = Double(max(1, bytesPerSecond))
        // Start with one second of budget so a fresh limiter permits a short
        // initial burst instead of stalling the very first file.
        self.allowance = self.bytesPerSecond
        self.lastTick = now
    }

    /// Charges `bytes` against the bucket (refilled up to `now`) and returns
    /// how long the caller must wait before the spend is allowed. The charge
    /// always goes through — a file larger than the budget simply borrows
    /// against future time, so one big file can never deadlock the queue.
    mutating func charge(_ bytes: Int64, now: TimeInterval) -> TimeInterval {
        let elapsed = max(0, now - lastTick)
        lastTick = now
        allowance = min(allowance + elapsed * bytesPerSecond, bytesPerSecond)
        allowance -= Double(max(0, bytes))
        return allowance < 0 ? -allowance / bytesPerSecond : 0
    }
}
