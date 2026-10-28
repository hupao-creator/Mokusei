import MokuseiPluginUI
import SwiftUI

/// Keep Bart's timing and eye seat, but fit the orbit to the glass contour.
struct NativeMokuRunningEyes: View {
    @Environment(\.scenePhase) private var scenePhase
    var reduceMotion: Bool
    var capsuleSize: CGSize
    var cornerRadius: CGFloat
    @State private var elapsed = 0.0
    @State private var resumedAt: Date?

    private let dotRadius: CGFloat = 2.5
    private let gap: CGFloat = 3
    private var orbitOffset: CGFloat { dotRadius + gap }

    private var active: Bool { scenePhase == .active && !reduceMotion }

    var body: some View {
        TimelineView(.animation(paused: !active)) { context in
            let milliseconds = elapsed + (resumedAt.map { max(0, context.date.timeIntervalSince($0)) * 1000 } ?? 0)
            let frame = NativeMokuRunningGeometry.sample(milliseconds: milliseconds, capsuleSize: capsuleSize,
                                                        cornerRadius: cornerRadius, still: reduceMotion)
            ZStack {
                NativeMokuBlinkingEyes(expression: .idle, focus: 0)
                    .scaleEffect(x: frame.eyes.scaleX, y: frame.eyes.scaleY)
                    .offset(x: frame.eyes.x * 0.12, y: frame.eyes.y * 0.12)
                Canvas { context, size in
                    for dot in frame.dots {
                        let center = CGPoint(x: size.width / 2 + (dot.x - 320) * 0.075,
                                             y: size.height / 2 + (dot.y - 300) * 0.075)
                        let radius = dotRadius
                        context.opacity = dot.opacity
                        context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                            width: radius * 2, height: radius * 2)),
                                     with: .color(dot.color.swiftUI))
                    }
                }.frame(width: capsuleSize.width + 24, height: capsuleSize.height + 24)
            }.frame(width: 34, height: 25)
        }
        .onChange(of: active, initial: true) { _, active in
            let now = Date()
            if let resumedAt { elapsed += max(0, now.timeIntervalSince(resumedAt)) * 1000 }
            resumedAt = active ? now : nil
        }
        .accessibilityHidden(true)
    }

}

/// Both the standalone orbit replay and the persistent character host sample
/// the same authored path. The host owns role clocks and handoffs.
enum NativeMokuRunningGeometry {
    static func sample(milliseconds: Double, capsuleSize: CGSize, cornerRadius: CGFloat, still: Bool) -> MokuRunningFrame {
        let path = orbitPath(in: capsuleSize, cornerRadius: cornerRadius)
        return MokuRunningStory.sample(time: milliseconds / MokuRunningStory.beatMS, still: still,
            restingY: 300 + (capsuleSize.height / 2 + 5.5) / 0.075, restingSpacing: 8 / 0.075) { angle in
            let phase = (angle - .pi / 2) / (2 * .pi)
            let progress = (phase.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
            let point = path.trimmedPath(from: 0, to: progress).currentPoint
                ?? CGPoint(x: capsuleSize.width / 2, y: capsuleSize.height + 5.5)
            return CGPoint(x: 320 + (point.x - capsuleSize.width / 2) / 0.075,
                           y: 300 + (point.y - capsuleSize.height / 2) / 0.075)
        }
    }

    private static func orbitPath(in size: CGSize, cornerRadius: CGFloat) -> Path {
        let orbitOffset: CGFloat = 5.5
        // Offset the visible glass contour by both dot radius and clear space.
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: -orbitOffset, dy: -orbitOffset)
        let radius = max(0, min(cornerRadius, min(size.width, size.height) / 2)) + orbitOffset
        return Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
            for (center, start) in [
                (CGPoint(x: rect.minX + radius, y: rect.maxY - radius), 90.0),
                (CGPoint(x: rect.minX + radius, y: rect.minY + radius), 180.0),
                (CGPoint(x: rect.maxX - radius, y: rect.minY + radius), 270.0),
                (CGPoint(x: rect.maxX - radius, y: rect.maxY - radius), 360.0)
            ] {
                path.addArc(center: center, radius: radius, startAngle: .degrees(start),
                            endAngle: .degrees(start + 90), clockwise: false)
            }
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
    }
}
