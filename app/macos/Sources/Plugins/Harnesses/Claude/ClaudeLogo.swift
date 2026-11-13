import MokuseiPluginUI
import SwiftUI
public struct ClaudeLogo: View {
    /// The approved running-card palette belongs to this harness.
    public static let threadCardCloudPalette = NativeCloudPalette(channels: [
        .init(color: NativePalette.color(0xf6ad71).swiftUI, seed: 136, energy: 0.36),
        .init(color: NativePalette.color(0xd97757).swiftUI, seed: 73, energy: 0.43),
        .init(color: NativePalette.color(0xefb7a2).swiftUI, seed: 211, energy: 0.28)
    ], phase: 4.6)

    public let size: CGFloat
    public init(size: CGFloat = 24) { self.size = size }
    public var body: some View {
        ClaudeLogoShape().fill(Color(red: 217/255, green: 119/255, blue: 87/255), style: FillStyle(eoFill: true)).frame(width: size,height: size).accessibilityHidden(true)
    }
    @MainActor public static let source = nativeLogoPNG { ClaudeLogo(size: 64) }
}
private struct ClaudeLogoShape: Shape {
    func path(in rect: CGRect) -> Path {
        let points: [(Double,Double)] = [(20.998,10.949),(24,10.949),(24,14.051),(21,14.051),(21,17.079),(19.513,17.079),(19.513,20),(18,20),(18,17.079),(16.513,17.079),(16.513,20),(15,20),(15,17.079),(9,17.079),(9,20),(7.488,20),(7.488,17.079),(6,17.079),(6,20),(4.487,20),(4.487,17.079),(3,17.079),(3,14.05),(0,14.05),(0,10.95),(3,10.95),(3,5),(20.998,5)]
        var path = Path(); path.move(to: CGPoint(x:points[0].0,y:points[0].1))
        for p in points.dropFirst() { path.addLine(to: CGPoint(x:p.0,y:p.1)) }; path.closeSubpath()
        path.addRect(CGRect(x:6,y:8.102,width:1.488,height:2.847)); path.addRect(CGRect(x:16.51,y:8.102,width:1.49,height:2.847))
        return path.applying(CGAffineTransform(scaleX:rect.width/24,y:rect.height/24))
    }
}
