import MokuseiPluginAPI
import SwiftUI

/// Settings' coordinator choreography, in the source's unscaled CSS units.
/// The coordinator anchor supplies the outer 1.7 scale; eye offsets use the
/// character's SVG viewBox units and must be applied by its eye-animation API.
enum NativeMokuSettingsMotion {
    static let durationMilliseconds = 1050.0
    static let coordinatorScale: CGFloat = 1.7

    struct Transform: Equatable, Sendable {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rotationDegrees: Double = 0
        var scaleX: CGFloat = 1
        var scaleY: CGFloat = 1
    }

    struct Handoff: Equatable, Sendable {
        var approachY: CGFloat
        var receipt: Transform
        var eyes: CGPoint
    }

    struct Mark: Equatable, Sendable {
        var opacity: Double
        var scale: CGFloat
    }

    struct Engine: Equatable, Sendable {
        var arriving: Mark
        var departing: Mark
    }

    struct Feedback: Equatable, Sendable {
        var body: Transform
        var eyes: CGPoint
        var target: Transform
        var targetOpacity: Double
        var engine: Mark
    }

    /// The WAAPI effect's easing applies to the complete timeline, then each
    /// keyframe interval interpolates linearly (MokuCoordinatorIdentity.tsx).
    static func handoff(elapsedMilliseconds: Double, direction: CGFloat) -> Handoff {
        let progress = cubicProgress(normalized(elapsedMilliseconds), x1: 0.42, x2: 0.58)
        let sign: CGFloat = direction == 0 ? 0 : direction > 0 ? 1 : -1
        let receipt = interpolated(receiptFrames, at: progress)
        let eyes = interpolatedEyes(eyeFrames, at: normalized(elapsedMilliseconds))
        return Handoff(approachY: interpolated(liftFrames, at: progress),
            receipt: Transform(x: receipt.x * sign, y: receipt.y,
                rotationDegrees: receipt.rotationDegrees * Double(sign),
                scaleX: receipt.scaleX, scaleY: receipt.scaleY),
            eyes: CGPoint(x: eyes.x * sign, y: eyes.y))
    }

    /// CSS animation-timing-function applies within each keyframe interval,
    /// unlike the WAAPI effect-level easing used for the receipt above.
    static func engine(elapsedMilliseconds: Double) -> Engine {
        let progress = normalized(elapsedMilliseconds)
        return Engine(arriving: interpolated(arrivalFrames, at: progress, cssEaseOut: true),
            departing: interpolated(departureFrames, at: progress, cssEaseOut: true))
    }

    /// The idle effect has a linear 76-second clock and per-keyframe easing.
    /// Its owner restarts the clock whenever idle becomes enabled again.
    static func idle(elapsedMilliseconds: Double) -> Transform {
        let elapsed = max(0, elapsedMilliseconds).truncatingRemainder(dividingBy: 76_000)
        return interpolated(idleFrames, at: elapsed, easeInOut: true)
    }

    static func feedbackDurationMilliseconds(enabled: Bool) -> Double { enabled ? 1800 : 1600 }

    static func handoffEyeMotion(direction: CGFloat,
                                 startedAtMilliseconds: Double = ProcessInfo.processInfo.systemUptime * 1000) -> MokuEyeMotion {
        let sign: CGFloat = direction == 0 ? 0 : direction > 0 ? 1 : -1
        return eyeMotion(eyeFrames, duration: durationMilliseconds, gazeX: sign, startedAt: startedAtMilliseconds)
    }

    static func feedbackEyeMotion(enabled: Bool, gazeX: CGFloat,
                                  startedAtMilliseconds: Double = ProcessInfo.processInfo.systemUptime * 1000) -> MokuEyeMotion {
        eyeMotion(enabled ? enabledEyeFrames : disabledEyeFrames,
            duration: feedbackDurationMilliseconds(enabled: enabled), gazeX: gazeX, startedAt: startedAtMilliseconds)
    }

    private static func eyeMotion(_ frames: [(Double, CGPoint)], duration: Double,
                                  gazeX: CGFloat, startedAt: Double) -> MokuEyeMotion {
        MokuEyeMotion(points: frames.map {
            .init(atMilliseconds: $0.0 * duration, offset: CGPoint(x: $0.1.x * gazeX, y: $0.1.y))
        }, durationMilliseconds: duration, startedAtMilliseconds: startedAt)
    }

    /// `gazeX` is clamp((target centerX - coordinator centerX) / 4, -32, 32).
    /// Body and engine transforms remain in coordinator CSS units; the target
    /// transform is in the unscaled dispatch icon's CSS units. Eye values are
    /// 640-unit viewBox offsets, sampled with the canvas' segment smoothstep.
    static func feedback(enabled: Bool, gazeX: CGFloat, elapsedMilliseconds: Double) -> Feedback {
        let time = min(1, max(0, elapsedMilliseconds / feedbackDurationMilliseconds(enabled: enabled)))
        let progress = cubicProgress(time, x1: 0.42, x2: 0.58)
        var body = interpolated(enabled ? enabledBodyFrames : disabledBodyFrames, at: progress)
        body.x *= gazeX / 9
        body.rotationDegrees *= Double(gazeX) / 6
        var eyes = interpolatedEyes(enabled ? enabledEyeFrames : disabledEyeFrames, at: time)
        eyes.x *= gazeX
        return Feedback(body: body, eyes: eyes,
            target: interpolated(enabled ? enabledTargetFrames : disabledTargetFrames, at: progress),
            targetOpacity: enabled ? 1 : Double(interpolated(disabledTargetOpacityFrames, at: progress)),
            engine: interpolated(enabled ? enabledConfirmationFrames : disabledConfirmationFrames, at: progress))
    }

    /// Matches dispatch-canvas.ts, including its 14-step Bézier inversion and
    /// lift in the already-scaled dispatch map's coordinate space. On another
    /// relocation, sample the active position first and use it as the new `from`.
    static func dispatchSource(from: CGPoint, to: CGPoint, elapsedMilliseconds: Double,
                               moving: Bool) -> CGPoint {
        guard moving else { return to }
        let elapsed = max(0, elapsedMilliseconds)
        let travel = dispatchProgress(min(1, elapsed / 720), x1: 0.4, x2: 0.2)
        let beat = dispatchProgress(min(1, elapsed / durationMilliseconds), x1: 0.42, x2: 0.58)
        let lift = interpolated(liftFrames, at: beat) * coordinatorScale
        return CGPoint(x: from.x + (to.x - from.x) * travel,
            y: from.y + (to.y - from.y) * travel + lift)
    }

    static func dispatchDashPhase(nowMilliseconds: Double) -> CGFloat {
        CGFloat(-nowMilliseconds.truncatingRemainder(dividingBy: 1100) / 1100 * 24)
    }

    private static let liftFrames: [(Double, CGFloat)] = [
        (0, 0), (0.2, -6), (0.44, -14), (0.68, 2), (0.84, -3), (1, 0)
    ]
    private static let receiptFrames: [(Double, Transform)] = [
        (0, Transform()),
        (0.18, Transform(x: 3, rotationDegrees: 8)),
        (0.44, Transform(x: 4, y: -3, rotationDegrees: 11, scaleX: 0.97, scaleY: 1.04)),
        (0.68, Transform(y: 2, scaleX: 1.09, scaleY: 0.9)),
        (0.84, Transform(y: -4, scaleX: 0.97, scaleY: 1.04)),
        (1, Transform())
    ]
    private static let eyeFrames: [(Double, CGPoint)] = [
        (0, .zero), (0.2, CGPoint(x: 32, y: 12)), (0.5, CGPoint(x: 24, y: 20)),
        (0.68, CGPoint(x: 0, y: 32)), (0.84, CGPoint(x: 0, y: -10)), (1, .zero)
    ]
    private static let arrivalFrames: [(Double, Mark)] = [
        (0, Mark(opacity: 0, scale: 0.6)), (0.69, Mark(opacity: 0, scale: 0.6)),
        (0.86, Mark(opacity: 1, scale: 1.15)), (1, Mark(opacity: 1, scale: 1))
    ]
    private static let departureFrames: [(Double, Mark)] = [
        (0, Mark(opacity: 1, scale: 1)), (0.65, Mark(opacity: 0.2, scale: 0.8)),
        (0.7, Mark(opacity: 0, scale: 0.6)), (1, Mark(opacity: 0, scale: 0.6))
    ]
    private static let idleFrames: [(Double, Transform)] = {
        let gestures: [(Double, [Transform])] = [
            (6000, [Transform(), Transform(x: 3, y: -1, rotationDegrees: 7),
                Transform(x: 3, y: -1, rotationDegrees: 7), Transform()]),
            (19000, [Transform(), Transform(y: 3, rotationDegrees: -4, scaleX: 1.04, scaleY: 0.95),
                Transform(y: -1, scaleX: 0.99, scaleY: 1.02), Transform()]),
            (32000, [Transform(), Transform(x: -3, y: -1, rotationDegrees: -13),
                Transform(x: -3, y: -1, rotationDegrees: -13), Transform()]),
            (45000, [Transform(), Transform(y: -3, rotationDegrees: 3, scaleX: 0.94, scaleY: 1.13),
                Transform(y: 1, scaleX: 1.04, scaleY: 0.97), Transform()]),
            (58000, [Transform(), Transform(y: 2, scaleX: 1.08, scaleY: 0.9),
                Transform(y: -8, rotationDegrees: -6, scaleX: 0.96, scaleY: 1.05),
                Transform(y: 2, scaleX: 1.06, scaleY: 0.94), Transform()])
        ]
        var frames = [(0.0, Transform())]
        for (start, poses) in gestures {
            for (index, pose) in poses.enumerated() {
                frames.append((start + Double(index) / Double(poses.count - 1) * 1700, pose))
            }
        }
        frames.append((76_000, Transform()))
        return frames
    }()
    // X and rotation encode multipliers of lean=gazeX/9 and turn=gazeX/6.
    private static let enabledBodyFrames: [(Double, Transform)] = [
        (0, Transform()), (0.18, Transform(x: 1, y: 2, rotationDegrees: 1)),
        (0.32, Transform(x: 1, y: 2, rotationDegrees: 1)),
        (0.46, Transform(x: 1.25, y: 5, rotationDegrees: 1, scaleX: 1.04, scaleY: 0.94)),
        (0.61, Transform(x: 1, y: -2, rotationDegrees: 0.5, scaleX: 0.98, scaleY: 1.03)),
        (0.78, Transform(x: 0.7, rotationDegrees: 0.5)), (1, Transform())
    ]
    private static let disabledBodyFrames: [(Double, Transform)] = [
        (0, Transform()), (0.18, Transform(x: 1, y: 2, rotationDegrees: 1)),
        (0.36, Transform(x: 1, y: 2, rotationDegrees: 1)),
        (0.6, Transform(x: -0.5, y: -3, rotationDegrees: -0.4, scaleX: 0.98, scaleY: 1.02)),
        (0.78, Transform(x: -0.25, y: -1)), (1, Transform())
    ]
    // X encodes a multiplier of gazeX; Y remains in the 640-unit eye space.
    private static let enabledEyeFrames: [(Double, CGPoint)] = [
        (0, .zero), (0.13, CGPoint(x: 1, y: 28)), (0.38, CGPoint(x: 1, y: 36)),
        (0.72, CGPoint(x: 0.75, y: 26)), (1, .zero)
    ]
    private static let disabledEyeFrames: [(Double, CGPoint)] = [
        (0, .zero), (0.13, CGPoint(x: 1, y: 28)), (0.38, CGPoint(x: 1, y: 28)),
        (0.72, CGPoint(x: 0, y: 8)), (1, .zero)
    ]
    private static let enabledTargetFrames: [(Double, Transform)] = [
        (0, Transform()), (0.44, Transform()),
        (0.61, Transform(y: -5, scaleX: 1.12, scaleY: 1.12)),
        (0.75, Transform(y: 1, scaleX: 1.04, scaleY: 0.97)), (1, Transform())
    ]
    private static let disabledTargetFrames: [(Double, Transform)] = [
        (0, Transform()), (0.32, Transform()),
        (0.6, Transform(scaleX: 0.9, scaleY: 0.9)), (1, Transform())
    ]
    private static let disabledTargetOpacityFrames: [(Double, CGFloat)] = [
        (0, 1), (0.32, 1), (0.6, 0.5), (1, 1)
    ]
    private static let enabledConfirmationFrames: [(Double, Mark)] = [
        (0, Mark(opacity: 1, scale: 1)), (0.65, Mark(opacity: 1, scale: 1)),
        (0.82, Mark(opacity: 1, scale: 1.1)), (1, Mark(opacity: 1, scale: 1))
    ]
    private static let disabledConfirmationFrames: [(Double, Mark)] = [
        (0, Mark(opacity: 1, scale: 1)), (0.65, Mark(opacity: 1, scale: 1)),
        (0.82, Mark(opacity: 0.65, scale: 0.95)), (1, Mark(opacity: 1, scale: 1))
    ]

    private static func normalized(_ elapsed: Double) -> Double {
        min(1, max(0, elapsed / durationMilliseconds))
    }

    private static func interval<Value>(_ frames: [(Double, Value)], at progress: Double)
        -> (Value, Value, Double) {
        let index = max(1, frames.firstIndex { $0.0 >= progress } ?? frames.count - 1)
        let a = frames[index - 1], b = frames[index]
        return (a.1, b.1, min(1, max(0, (progress - a.0) / (b.0 - a.0))))
    }

    private static func interpolated(_ frames: [(Double, CGFloat)], at progress: Double) -> CGFloat {
        let (a, b, amount) = interval(frames, at: progress)
        return a + (b - a) * amount
    }

    private static func interpolatedEyes(_ frames: [(Double, CGPoint)], at progress: Double) -> CGPoint {
        let (a, b, local) = interval(frames, at: progress)
        let amount = local * local * (3 - 2 * local)
        return CGPoint(x: a.x + (b.x - a.x) * amount, y: a.y + (b.y - a.y) * amount)
    }

    private static func interpolated(_ frames: [(Double, Transform)], at progress: Double,
                                     easeInOut: Bool = false) -> Transform {
        let (a, b, local) = interval(frames, at: progress)
        let amount = easeInOut ? cubicProgress(local, x1: 0.42, x2: 0.58) : local
        return Transform(x: a.x + (b.x - a.x) * amount, y: a.y + (b.y - a.y) * amount,
            rotationDegrees: a.rotationDegrees + (b.rotationDegrees - a.rotationDegrees) * amount,
            scaleX: a.scaleX + (b.scaleX - a.scaleX) * amount,
            scaleY: a.scaleY + (b.scaleY - a.scaleY) * amount)
    }

    private static func interpolated(_ frames: [(Double, Mark)], at progress: Double,
                                     cssEaseOut: Bool = false) -> Mark {
        let (a, b, local) = interval(frames, at: progress)
        let amount = cssEaseOut ? cubicProgress(local, x1: 0, x2: 0.58) : local
        return Mark(opacity: a.opacity + (b.opacity - a.opacity) * amount,
            scale: a.scale + (b.scale - a.scale) * amount)
    }

    private static func cubicProgress(_ time: Double, x1: Double, x2: Double) -> Double {
        if time <= 0 { return 0 }
        if time >= 1 { return 1 }
        return invertedCubic(time, x1: x1, x2: x2, iterations: 32)
    }

    private static func dispatchProgress(_ time: Double, x1: Double, x2: Double) -> Double {
        invertedCubic(time, x1: x1, x2: x2, iterations: 14)
    }

    /// The curves used here all have y control points 0 and 1.
    private static func invertedCubic(_ time: Double, x1: Double, x2: Double, iterations: Int) -> Double {
        var low = 0.0, high = 1.0
        for _ in 0..<iterations {
            let p = (low + high) / 2, inverse = 1 - p
            let x = 3 * inverse * inverse * p * x1 + 3 * inverse * p * p * x2 + p * p * p
            if x < time { low = p } else { high = p }
        }
        let p = (low + high) / 2
        return 3 * (1 - p) * p * p + p * p * p
    }
}

/// A clock-free 12-point engine layer. Its owner retains the old driver until
/// the handoff completes and passes the same elapsed time as the receipt pose.
@MainActor struct NativeMokuEngineHandoff: View {
    let current: AnyHarnessPlugin
    let previous: AnyHarnessPlugin?
    let elapsedMilliseconds: Double

    var body: some View {
        let changing = previous.map { $0.descriptor.id != current.descriptor.id } ?? false
        let frame = NativeMokuSettingsMotion.engine(elapsedMilliseconds: elapsedMilliseconds)
        ZStack {
            if let previous, changing {
                previous.logo(size: 12)
                    .scaleEffect(frame.departing.scale)
                    .opacity(frame.departing.opacity)
            }
            current.logo(size: 12)
                .scaleEffect(changing ? frame.arriving.scale : 1)
                .opacity(changing ? frame.arriving.opacity : 1)
        }
        .frame(width: 12, height: 12)
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
