import MokuseiPluginUI
import SwiftUI

/// The shipped pi.dev mark, rendered from the original 800×800 vector geometry.
public struct PiLogo: View {
    /// The approved running-card palette belongs to this harness.
    public static let threadCardCloudPalette = NativeCloudPalette(channels: [
        .init(color: NativePalette.color(0xff525e).swiftUI, seed: 19, energy: 0.25),
        .init(color: NativePalette.color(0xffb52e).swiftUI, seed: 53, energy: 0.23),
        .init(color: NativePalette.color(0x53dd83).swiftUI, seed: 87, energy: 0.25),
        .init(color: NativePalette.color(0x27cbf4).swiftUI, seed: 121, energy: 0.27),
        .init(color: NativePalette.color(0x5967ff).swiftUI, seed: 155, energy: 0.25),
        .init(color: NativePalette.color(0xdb57ef).swiftUI, seed: 189, energy: 0.25)
    ], phase: 2.8, lobeScale: CGSize(width: 0.86, height: 0.90))

    public let size: CGFloat
    @Environment(\.colorScheme) private var scheme
    public init(size: CGFloat = 12) { self.size = size }
    public var body: some View {
        PiMark().fill(scheme == .dark ? Color.white : Color.black, style: FillStyle(eoFill: true))
            .frame(width: size, height: size).accessibilityLabel("Pi Agent")
    }
}
private struct PiMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 165.29, y: 165.29))
        for point in [CGPoint(x: 517.36, y: 165.29), CGPoint(x: 517.36, y: 400), CGPoint(x: 400, y: 400),
                      CGPoint(x: 400, y: 517.36), CGPoint(x: 282.65, y: 517.36), CGPoint(x: 282.65, y: 634.72),
                      CGPoint(x: 165.29, y: 634.72)] { path.addLine(to: point) }
        path.closeSubpath()
        path.addRect(CGRect(x: 282.65, y: 282.65, width: 117.35, height: 117.35))
        path.addRect(CGRect(x: 517.36, y: 400, width: 117.36, height: 234.72))
        return path.applying(CGAffineTransform(scaleX: rect.width / 800, y: rect.height / 800))
    }
}
