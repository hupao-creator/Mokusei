import QuartzCore
import SwiftUI

/// The ordinary workspace Thread Detail opening, shared with tag/card travel.
public enum NativeReadingPageTiming {
    private static let x1 = 0.76
    private static let x2 = 0.24
    public static let duration: TimeInterval = 0.42
    public static var openingAnimation: Animation {
        .timingCurve(x1, 0, x2, 1, duration: duration)
    }
    /// The vertical history replacement curve (see NativeReadingPageStack).
    /// Page-level streaming reuses it so a flushed page enters like a history
    /// page, without driving the full-viewport page stack inline.
    public static var replacementAnimation: Animation {
        .timingCurve(0.42, 0, 0.58, 1, duration: duration)
    }
    public static var replacementTimingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.42, 0, 0.58, 1)
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

}
