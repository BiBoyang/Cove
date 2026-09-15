import Foundation

/// Pure value-type state machine for the player's "Up Next" countdown.
///
/// The Coordinator owns the driving `Timer`; this model only tracks the
/// countdown phase. Each `tick()` decrements the remaining seconds and
/// returns the new value. Reaching zero transitions to `fired` (the firing
/// tick itself returns 0); `cancel()` transitions to `cancelled`. Both
/// terminal states are absorbing: further `tick()` calls return `nil` and
/// never fire again, and `cancel()` on a fired countdown is a no-op so a
/// stale cancel cannot resurrect an already-advanced queue.
///
/// Space toggles `counting` ↔ `paused` via `togglePause()`. A paused
/// countdown absorbs `tick()` and keeps its remaining seconds frozen; the
/// Coordinator tears its timer down on pause too, so the phase guard here
/// is a second line of defense against a stray beat. Cancelling still
/// works from `paused` (Esc during the freeze dismisses the countdown).
struct UpNextCountdown: Equatable {
    enum Phase: Equatable {
        case counting
        case paused
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

    var isPaused: Bool { phase == .paused }

    /// Advances the countdown by one second.
    ///
    /// - Returns the remaining seconds after the tick (0 on the firing
    ///   tick), or `nil` once the countdown has reached a terminal phase
    ///   or is paused.
    @discardableResult
    mutating func tick() -> Int? {
        guard phase == .counting else { return nil }
        remainingSeconds -= 1
        if remainingSeconds == 0 {
            phase = .fired
        }
        return remainingSeconds
    }

    /// Freezes (from `counting`) or resumes (from `paused`) the countdown.
    /// No-op from a terminal phase.
    mutating func togglePause() {
        switch phase {
        case .counting:
            phase = .paused
        case .paused:
            phase = .counting
        case .fired, .cancelled:
            break
        }
    }

    /// Cancels the countdown (user dismiss, manual step, window close,
    /// Esc while paused). No-op from a terminal phase.
    mutating func cancel() {
        guard phase == .counting || phase == .paused else { return }
        phase = .cancelled
    }
}
