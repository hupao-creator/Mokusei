import Foundation
import Testing
@testable import MokuseiUI

struct NativeMokuBlinkTests {
    @Test func residentCadenceClosesReopensAndRepeats() {
        var clock = NativeMokuCapsuleBlinkClock(now: 0)
        #expect(clock.nextWake(now: 0) == 3400)
        clock.advance(now: 3400)
        #expect(clock.factor(now: 3400) == 1)
        #expect(abs(clock.factor(now: 3560) - 0.09) < 0.0001)
        #expect(clock.nextWake(now: 3560) == 3560)
        #expect(abs(clock.factor(now: 3720) - 1) < 0.0001)
        #expect(clock.nextWake(now: 3720) == 7600)
        clock.advance(now: 7600)
        #expect(abs(clock.factor(now: 7760) - 0.09) < 0.0001)
    }

    @Test func hiddenTimePreservesPendingAndInFlightBlinks() {
        var clock = NativeMokuCapsuleBlinkClock(now: 0)
        clock.setActive(false, now: 3000)
        clock.advance(now: 10000)
        clock.setActive(false, now: 11000)
        clock.setActive(true, now: 13000)
        #expect(clock.nextWake(now: 13000) == 13400)
        clock.advance(now: 13400)
        clock.setActive(false, now: 13560)
        let closed = clock.factor(now: 13560)
        clock.advance(now: 20000)
        #expect(clock.factor(now: 20000) == closed)
        clock.setActive(true, now: 23560)
        #expect(clock.factor(now: 23560) == closed)
        #expect(abs(clock.factor(now: 23720) - 1) < 0.0001)
        #expect(clock.nextWake(now: 23720) == 27600)
    }

    @Test func continuousTimingClosesReopensAndRepeats() {
        for cycle in 0..<3 {
            let start = date(Double(cycle) * 4.2)
            #expect(NativeMokuCapsuleBlinkTiming.factor(at: start) == 1)
            #expect(abs(NativeMokuCapsuleBlinkTiming.factor(at: start.addingTimeInterval(0.16)) - 0.09) < 0.0001)
            #expect(NativeMokuCapsuleBlinkTiming.factor(at: start.addingTimeInterval(0.32)) == 1)
            #expect(NativeMokuCapsuleBlinkTiming.factor(at: start.addingTimeInterval(2)) == 1)
            // Adjacent display timestamps must not collapse onto a 30fps sample.
            let first = NativeMokuCapsuleBlinkTiming.factor(at: start.addingTimeInterval(0.10))
            let next = NativeMokuCapsuleBlinkTiming.factor(at: start.addingTimeInterval(0.10 + 1.0 / 120))
            #expect(next < first)
        }
    }

    @Test func finalFrameIsExactlyOpenAtCurrentEpochPrecision() {
        let cycle = floor(813_000_000.0 / 4.2)
        let start = date(cycle * 4.2)
        #expect(NativeMokuCapsuleBlinkTiming.factor(at: start.addingTimeInterval(0.32)) == 1)
        #expect(NativeMokuCapsuleBlinkTiming.factor(at: start.addingTimeInterval(0.321)) == 1)
    }

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }
}
