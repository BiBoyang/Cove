import Testing
@testable import Cove

@Suite("Up Next countdown")
struct UpNextCountdownTests {
    @Test("initial state counts from the full budget")
    func initialState() {
        let countdown = UpNextCountdown(totalSeconds: 5)
        #expect(countdown.remainingSeconds == 5)
        #expect(countdown.phase == .counting)
        #expect(countdown.didFire == false)
    }

    @Test("tick sequence runs 4→3→2→1→0 and fires at zero")
    func tickSequenceFires() {
        var countdown = UpNextCountdown(totalSeconds: 5)
        var ticks: [Int] = []
        // `#expect` evaluates its expression in a closure, so mutating
        // calls happen outside the macro.
        while let remaining = countdown.tick() {
            ticks.append(remaining)
        }
        #expect(ticks == [4, 3, 2, 1, 0])
        #expect(countdown.phase == .fired)
        #expect(countdown.didFire)
        #expect(countdown.remainingSeconds == 0)
    }

    @Test("tick is idempotent after firing")
    func tickAfterFire() {
        var countdown = UpNextCountdown(totalSeconds: 5)
        while countdown.tick() != nil {}

        let firstStale = countdown.tick()
        let secondStale = countdown.tick()
        #expect(firstStale == nil)
        #expect(secondStale == nil)
        #expect(countdown.phase == .fired)
        #expect(countdown.remainingSeconds == 0)
    }

    @Test("cancel stops the countdown and ticks stay silent")
    func cancelThenTick() {
        var countdown = UpNextCountdown(totalSeconds: 5)
        countdown.tick()
        countdown.cancel()
        #expect(countdown.phase == .cancelled)

        let staleTick = countdown.tick()
        #expect(staleTick == nil)
        #expect(countdown.phase == .cancelled)
        #expect(countdown.remainingSeconds == 4)
    }

    @Test("cancel is idempotent and cannot resurrect a fired countdown")
    func cancelTerminalStates() {
        var countdown = UpNextCountdown(totalSeconds: 5)
        countdown.cancel()
        countdown.cancel()
        #expect(countdown.phase == .cancelled)

        var fired = UpNextCountdown(totalSeconds: 1)
        fired.tick()
        #expect(fired.phase == .fired)
        fired.cancel()
        #expect(fired.phase == .fired)
        #expect(fired.tick() == nil)
    }

    @Test("a one-second countdown fires on its first tick")
    func singleSecond() {
        var countdown = UpNextCountdown(totalSeconds: 1)
        let only = countdown.tick()
        #expect(only == 0)
        #expect(countdown.phase == .fired)
    }
}
