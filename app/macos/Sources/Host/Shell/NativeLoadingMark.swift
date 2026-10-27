import MokuseiPluginUI
import SwiftUI

/// A local SwiftUI clock preserves the pre-migration compositor's timing without
/// starting Moku's resident engine or updating the surrounding runtime surface.
struct NativeLoadingMark: View {
    @State private var origin = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            RuntimeLoadingDrawing(elapsed: max(0, timeline.date.timeIntervalSince(origin)))
        }
        .frame(width: 96, height: 96)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Kept separate so the production drawing can also be replayed at exact times.
struct RuntimeLoadingDrawing: View {
    var elapsed: TimeInterval

    var body: some View {
        Canvas { context, size in
            let ink = GraphicsContext.Shading.color(NativePalette.overview.ink.swiftUI)
            let canvas = GraphicsContext.Shading.color(NativePalette.overview.canvas.swiftUI)
            let stroke = StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
            context.scaleBy(x: size.width / 400, y: size.height / 400)
            context.translateBy(x: -120, y: -100)
            var guide = context
            guide.opacity = 0.12
            for path in Self.paths { guide.stroke(path, with: ink, style: stroke) }

            context.opacity = RuntimeLoadingTiming.value(elapsed, values: [0, 1, 1, 0, 0],
                times: [0, 0.08, 0.76, 0.96, 1], cycleFade: true)
            context.drawLayer { drawing in
                for (index, path) in Self.paths.enumerated() {
                    let eye = index > 0
                    let delay = index == 2 ? 0.12 : 0.0
                    let end = RuntimeLoadingTiming.value(elapsed, delay: delay,
                        values: eye ? [0, 0, 1, 1, 1] : [0, 1, 1, 1],
                        times: eye ? [0, 0.18, 0.42, 0.6, 1] : [0, 0.4, 0.6, 1])
                    let fill = RuntimeLoadingTiming.value(elapsed, delay: delay,
                        values: eye ? [0, 0, 0, 1, 1] : [0, 0, 1, 1],
                        times: eye ? [0, 0.18, 0.42, 0.6, 1] : [0, 0.4, 0.6, 1])
                    var filling = drawing
                    filling.opacity = fill
                    filling.fill(path, with: eye ? canvas : ink)
                    // Core Animation interpolated the eye stroke from ink to
                    // canvas while filling. Resolve colors in the current theme.
                    let color: GraphicsContext.Shading
                    if eye {
                        color = .color(NativePalette.overview.ink.swiftUI.mix(with: NativePalette.overview.canvas.swiftUI, by: fill, in: .device))
                    } else { color = ink }
                    if end > 0 { drawing.stroke(path.trimmedPath(from: 0, to: end), with: color, style: stroke) }
                }
            }
        }
    }

    private static let paths: [Path] = {
        var result = [Path(MokuGeometry.path(MokuGeometry.buildShape(.circle)))]
        if let expression = MokuGeometry.expressions[.idle] {
            result += [Path(eyePath(expression.left)), Path(eyePath(expression.right))]
        }
        return result
    }()

    private static func eyePath(_ eye: MokuEye) -> CGPath {
        let box = CGRect(x: -eye.w / 2, y: -eye.h / 2, width: eye.w, height: eye.h)
        let rx = min(eye.radius, box.width / 2)
        let ry = min(eye.radius, box.height / 2)
        let k = 4 * (sqrt(2.0) - 1) / 3
        let path = CGMutablePath()
        // SVG rect dashing starts at the left end of its upper straight edge.
        path.move(to: CGPoint(x: box.minX + rx, y: box.minY))
        path.addLine(to: CGPoint(x: box.maxX - rx, y: box.minY))
        path.addCurve(to: CGPoint(x: box.maxX, y: box.minY + ry),
            control1: CGPoint(x: box.maxX - rx + k * rx, y: box.minY), control2: CGPoint(x: box.maxX, y: box.minY + ry - k * ry))
        path.addLine(to: CGPoint(x: box.maxX, y: box.maxY - ry))
        path.addCurve(to: CGPoint(x: box.maxX - rx, y: box.maxY),
            control1: CGPoint(x: box.maxX, y: box.maxY - ry + k * ry), control2: CGPoint(x: box.maxX - rx + k * rx, y: box.maxY))
        path.addLine(to: CGPoint(x: box.minX + rx, y: box.maxY))
        path.addCurve(to: CGPoint(x: box.minX, y: box.maxY - ry),
            control1: CGPoint(x: box.minX + rx - k * rx, y: box.maxY), control2: CGPoint(x: box.minX, y: box.maxY - ry + k * ry))
        path.addLine(to: CGPoint(x: box.minX, y: box.minY + ry))
        path.addCurve(to: CGPoint(x: box.minX + rx, y: box.minY),
            control1: CGPoint(x: box.minX, y: box.minY + ry - k * ry), control2: CGPoint(x: box.minX + rx - k * rx, y: box.minY))
        path.closeSubpath()
        var transform = CGAffineTransform(translationX: 320 + eye.x, y: 300 + eye.y).rotated(by: eye.rotation * .pi / 180)
        return path.copy(using: &transform)!
    }
}

/// Historical 3-second keyframes, including each segment's cubic timing curve.
enum RuntimeLoadingTiming {
    static func value(_ elapsed: TimeInterval, delay: Double = 0,
                      values: [Double], times: [Double], cycleFade: Bool = false) -> Double {
        guard elapsed >= delay else { return values[0] }
        let phase = (elapsed - delay).truncatingRemainder(dividingBy: 3) / 3
        let curve = cycleFade
            ? UnitCurve.bezier(startControlPoint: .init(x: 0.42, y: 0), endControlPoint: .init(x: 0.58, y: 1))
            : UnitCurve.bezier(startControlPoint: .init(x: 0.4, y: 0), endControlPoint: .init(x: 0.2, y: 1))
        for index in 1..<times.count where phase <= times[index] {
            let progress = (phase - times[index - 1]) / (times[index] - times[index - 1])
            return values[index - 1] + (values[index] - values[index - 1]) * curve.value(at: progress)
        }
        return values.last!
    }
}
