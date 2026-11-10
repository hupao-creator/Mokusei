import Foundation

enum NativeMokuCapsuleBlinkTiming {
    static let interval = 4.2
    static let duration = 0.32

    static func factor(at date: Date) -> Double {
        let cycle = floor(date.timeIntervalSinceReferenceDate / interval)
        let start = Date(timeIntervalSinceReferenceDate: cycle * interval)
        // Compare absolute dates so epoch rounding cannot leave a completed blink closed.
        guard date < start.addingTimeInterval(duration) else { return 1 }
        return 1 - sin(date.timeIntervalSince(start) / duration * .pi) * 0.91
    }
}
