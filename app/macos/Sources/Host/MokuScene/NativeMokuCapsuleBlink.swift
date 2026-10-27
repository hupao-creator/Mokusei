import MokuseiPluginUI
import SwiftUI

struct NativeMokuBlinkingEyes: View {
    var expression: MokuExpression
    var focus: Double
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var active: Bool { scenePhase == .active && !reduceMotion }

    var body: some View {
        TimelineView(.animation(paused: !active)) { context in
            let blink = active && context.cadence == .live
                ? NativeMokuCapsuleBlinkTiming.factor(at: context.date) : 1
            NativeMokuCapsuleEyes(expression: expression, focus: focus, blink: blink).fill(.primary)
        }.accessibilityHidden(true)
    }
}

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

struct NativeMokuCapsuleBlinkClock {
    private(set) var nextBlink: Double
    private(set) var blinkAt = -Double.infinity
    private var pausedAt: Double?

    init(now: Double) { nextBlink = now + 3400 }
    mutating func setActive(_ active: Bool, now: Double) {
        if active, let pausedAt {
            let pause = max(0, now - pausedAt)
            nextBlink += pause
            if blinkAt.isFinite { blinkAt += pause }
            self.pausedAt = nil
        } else if !active, pausedAt == nil { pausedAt = now }
    }
    mutating func advance(now: Double) {
        guard pausedAt == nil else { return }
        if now >= nextBlink { blinkAt = now; nextBlink = now + 4200 }
    }
    func factor(now: Double) -> Double {
        let progress = ((pausedAt ?? now) - blinkAt) / 320
        return progress >= 0 && progress <= 1 ? 1 - sin(progress * .pi) * 0.91 : 1
    }
    func nextWake(now: Double) -> Double { now - blinkAt < 320 ? now : nextBlink }
}
