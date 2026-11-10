import Foundation
import Testing
@testable import MokuseiUI

struct NativeMokuBlinkTests {
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
