import Foundation

/// Pure value-type state machine for the player's "Up Next" countdown.
///
/// The Coordinator owns the driving `Timer`; this model only tracks the
/// countdown phase. Each `tick()` decrements the remaining seconds and
/// returns the new value. Reaching zero transitions to `fired` (the firing
/// tick itself returns 0); `cancel()` transitions to `cancelled`. Both
/// terminal states are absorbing: further `tick()` calls return `nil` and
/// never fire again, and `cancel()` on a fired countdown is a no-op so a
/// stale cancel cannot resurrect an already-advanced queue. There is no
/// resume semantics by design.
struct UpNextCountdown: Equatable {
    enum Phase: Equatable {
        case counting
        case fired
        case cancelled
    }

    private(set) var phase: Phase = .counting
    private(set) var remainingSeconds: Int

    /// - Precondition: `totalSeconds` must be positive; the coordinator
    ///   always passes a fixed 5-second budget.
    init(totalSeconds: Int) {
        precondition(totalSeconds > 0, "UpNextCountdown requires a positive duration")
        remainingSeconds = totalSeconds
    }

    var didFire: Bool { phase == .fired }

    /// Advances the countdown by one second.
    ///
    /// - Returns the remaining seconds after the tick (0 on the firing
    ///   tick), or `nil` once the countdown has reached a terminal phase.
    @discardableResult
    mutating func tick() -> Int? {
        guard phase == .counting else { return nil }
        remainingSeconds -= 1
        if remainingSeconds == 0 {
            phase = .fired
        }
        return remainingSeconds
    }

    /// Cancels the countdown (user dismiss, manual step, window close).
    /// No-op from a terminal phase.
    mutating func cancel() {
        guard phase == .counting else { return }
        phase = .cancelled
    }
}
