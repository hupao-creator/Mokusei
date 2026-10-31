import QuartzCore
import SwiftUI

/// The ordinary workspace Thread Detail opening, shared with tag/card travel.
public enum NativeReadingPageTiming {
    private static let x1 = 0.76
    private static let x2 = 0.24
    public static let duration: TimeInterval = 0.42
    /// The vertical history replacement curve (see NativeReadingPageStack).
    /// Page-level streaming reuses it so a flushed page enters like a history
    /// page, without driving the full-viewport page stack inline.
    public static var replacementAnimation: Animation {
        .timingCurve(0.42, 0, 0.58, 1, duration: duration)
    }
    public static var emphasizedOpening: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(x1), 0, Float(x2), 1)
    }

    /// Sample a cubic Bezier easing at `time`, the curve's x coordinate (not
    /// its parameter), returning the eased progress. Callers drive the value
    /// frame by frame so it can be settled without a running implicit
    /// animation, unlike Core Animation's additive presentation.
    public static func sample(x1: Double, x2: Double, at time: Double) -> Double {
        let time = min(1, max(0, time))
        guard time > 0 else { return 0 }
        guard time < 1 else { return 1 }
        func x(_ value: Double) -> Double {
            let s = 1 - value
            return 3 * s * s * value * x1 + 3 * s * value * value * x2 + value * value * value
        }
        var lower = 0.0, upper = 1.0
        for _ in 0..<28 {
            let middle = (lower + upper) / 2
            if x(middle) < time { lower = middle } else { upper = middle }
        }
        let t = (lower + upper) / 2
        return 3 * (1 - t) * t * t + t * t * t
    }

    /// Sample the same timing function in a display-link driven animation.
    /// Time is the Bezier's x coordinate, not its curve parameter.
    public static func openingSample(at elapsed: TimeInterval) -> (progress: Double, velocity: Double) {
        let time = min(1, max(0, elapsed / duration))
        guard time > 0 else { return (0, 0) }
        guard time < 1 else { return (1, 0) }
        func x(_ t: Double) -> Double {
            let s = 1 - t
            return 3 * s * s * t * x1 + 3 * s * t * t * x2 + t * t * t
        }
        var lower = 0.0, upper = 1.0
        for _ in 0..<28 {
            let middle = (lower + upper) / 2
            if x(middle) < time { lower = middle } else { upper = middle }
        }
        let t = (lower + upper) / 2, s = 1 - t
        let dx = 3 * s * s * x1 + 6 * s * t * (x2 - x1) + 3 * t * t * (1 - x2)
        return (3 * s * t * t + t * t * t, 6 * s * t / dx / duration)
    }
}
