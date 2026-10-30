import SwiftUI

/// Actual visible bounds in the camera plane. Keeping this separate from the
/// content's layout size lets filter changes scale text without reflowing it.
struct OverviewCardPose: Equatable {
    var frame: CGRect
    var opacity: Double = 1

    func transformed(scale: Double, dy: Double = 0, opacity: Double) -> Self {
        .init(frame: CGRect(x: frame.midX - frame.width * scale / 2,
                            y: frame.midY - frame.height * scale / 2 + dy,
                            width: frame.width * scale, height: frame.height * scale), opacity: opacity)
    }

    func reproject(from: NativeOverviewTransform, to: NativeOverviewTransform) -> Self {
        let ratio = from.scale / to.scale
        return .init(frame: CGRect(x: (from.x + frame.minX * from.scale - to.x) / to.scale,
                                   y: (from.y + frame.minY * from.scale - to.y) / to.scale,
                                   width: frame.width * ratio, height: frame.height * ratio), opacity: opacity)
    }
}

struct OverviewCardMotion: Equatable {
    // Timeline dates are shared by SwiftUI's display tick. Convert them to the
    // monotonic time used for interruption sampling, so both planes sample the
    // exact same frame instead of reading uptime separately while rendering.
    static let clockEpoch = Date.timeIntervalSinceReferenceDate - ProcessInfo.processInfo.systemUptime
    enum Curve: Equatable {
        case filter, layout, entry
        var controls: (Double, Double, Double, Double) {
            switch self {
            case .filter: (0.22, 1, 0.36, 1)
            case .layout: (0.16, 1, 0.3, 1)
            case .entry: (0.2, 0.8, 0.2, 1)
            }
        }
        func value(at time: Double) -> Double {
            let x = min(1, max(0, time))
            let (x1, y1, x2, y2) = controls
            func cubic(_ t: Double, _ a: Double, _ b: Double) -> Double {
                3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t
            }
            var low = 0.0, high = 1.0
            for _ in 0..<24 {
                let t = (low + high) / 2
                if cubic(t, x1, x2) < x { low = t } else { high = t }
            }
            return x == 0 || x == 1 ? x : cubic((low + high) / 2, y1, y2)
        }
    }
    var from: OverviewCardPose
    var to: OverviewCardPose
    var start: TimeInterval
    var delay: TimeInterval = 0
    var duration: TimeInterval
    var curve: Curve
    /// Nil means resize the content itself (ordinary shrink/move/grow).
    var layoutSize: CGSize?

    func sample(at now: TimeInterval) -> OverviewCardPose {
        let t = curve.value(at: (now - start - delay) / duration)
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        #if OVERVIEW_PERF_DIAGNOSTICS
        OverviewPerformanceDiagnostics.motionSample(from: from.frame, to: to.frame)
        #endif
        return .init(frame: CGRect(x: mix(from.frame.minX, to.frame.minX), y: mix(from.frame.minY, to.frame.minY),
                                   width: mix(from.frame.width, to.frame.width), height: mix(from.frame.height, to.frame.height)),
                     opacity: mix(from.opacity, to.opacity))
    }
}

/// Only the spatial wrapper ticks. Its semantic content remains a stable input;
/// glass and content sample the same monotonic clock and motion description.
struct OverviewCardFrame<Content: View>: View {
    let pose: OverviewCardPose
    let motion: OverviewCardMotion?
    let visible: Bool
    var diagnosticLayer: String = ""
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if OVERVIEW_PERF_DIAGNOSTICS
        let _: Void = OverviewPerformanceDiagnostics.frameBody(layer: diagnosticLayer)
        #endif
        return TimelineView(.animation(paused: motion == nil || !visible)) { context in
            let current = motion?.sample(at: context.date.timeIntervalSinceReferenceDate - OverviewCardMotion.clockEpoch) ?? pose
            #if OVERVIEW_PERF_DIAGNOSTICS
            let _: Void = OverviewPerformanceDiagnostics.cardFrameTick(layer: diagnosticLayer)
            #endif
            let size = motion?.layoutSize ?? current.frame.size
            content()
                .frame(width: max(1, size.width), height: max(1, size.height))
                .scaleEffect(x: current.frame.width / max(1, size.width),
                             y: current.frame.height / max(1, size.height), anchor: .topLeading)
                .opacity(current.opacity)
                .accessibilityHidden(current.opacity < 0.01)
                .offset(x: current.frame.minX, y: current.frame.minY)
        }
    }
}

extension NativeOverviewPlacement {
    var cardFrame: CGRect {
        CGRect(x: Double(column) * 376, y: Double(row) * 216,
               width: Double(columns) * 376 - 16, height: Double(rows) * 216 - 16)
    }
}
