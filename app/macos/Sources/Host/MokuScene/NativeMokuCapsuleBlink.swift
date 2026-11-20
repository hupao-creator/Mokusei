import MokuseiPluginUI
import SwiftUI

struct NativeMokuBlinkingEyes: View {
    var expression: MokuExpression
    var focus: Double
    @Environment(\.scenePhase) private var scenePhase
    private var active: Bool { scenePhase == .active }

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

    // An explicit blink starts a fresh idle interval on the same display clock.
    static func cycleStart(at date: Date, origin: Date?) -> Date {
        let origin = origin ?? Date(timeIntervalSinceReferenceDate: 0)
        let cycle = floor(date.timeIntervalSince(origin) / interval)
        return origin.addingTimeInterval(cycle * interval)
    }

    static func factor(at date: Date, origin: Date? = nil) -> Double {
        let start = cycleStart(at: date, origin: origin)
        // Compare absolute dates so epoch rounding cannot leave a completed blink closed.
        guard date < start.addingTimeInterval(duration) else { return 1 }
        return 1 - sin(date.timeIntervalSince(start) / duration * .pi) * 0.91
    }
}
