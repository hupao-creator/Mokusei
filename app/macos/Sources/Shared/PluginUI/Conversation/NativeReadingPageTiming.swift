import QuartzCore

/// The ordinary workspace Thread Detail opening, shared with tag/card travel.
public enum NativeReadingPageTiming {
    private static let x1 = 0.76
    private static let x2 = 0.24
    public static let duration: TimeInterval = 0.42
    public static var emphasizedOpening: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(x1), 0, Float(x2), 1)
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
