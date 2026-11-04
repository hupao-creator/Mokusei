import SwiftUI

/// The persistent character host samples this authored path and owns its clocks
/// and handoffs.
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
