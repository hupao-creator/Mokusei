import AppKit
import QuartzCore

/// One application-wide preference. The operating system owns the physical display rate.
public enum NativeFrameRate {
    public static let framesPerSecond = 120.0
    public static let interval = 1 / framesPerSecond
    public static var preferredRange: CAFrameRateRange {
        let rate = Float(framesPerSecond)
        return CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
    }

    @MainActor public static func preferredRange(for screen: NativePlatformScreen?) -> CAFrameRateRange {
        let maximum = screen.map { Double($0.maximumFramesPerSecond) } ?? framesPerSecond
        let rate = Float(max(1, min(framesPerSecond, maximum)))
        return CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
    }
}
