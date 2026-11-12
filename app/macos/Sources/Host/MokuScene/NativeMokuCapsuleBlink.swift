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
