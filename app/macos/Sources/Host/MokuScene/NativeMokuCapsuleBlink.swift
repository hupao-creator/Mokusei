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

    // Both the eye shape and its sleeping display link use this same current or next blink.
    static func window(at date: Date, first: Date? = nil) -> Range<Date> {
        let origin = first ?? Date(timeIntervalSinceReferenceDate: 0)
        let cycle = floor(date.timeIntervalSince(origin) / interval)
        var start = origin.addingTimeInterval((first == nil ? cycle : max(0, cycle)) * interval)
        if date >= start.addingTimeInterval(duration) { start.addTimeInterval(interval) }
        return start..<start.addingTimeInterval(duration)
    }

    static func factor(at date: Date, first: Date? = nil) -> Double {
        let blink = window(at: date, first: first)
        guard blink.contains(date) else { return 1 }
        return 1 - sin(date.timeIntervalSince(blink.lowerBound) / duration * .pi) * 0.91
    }
}
