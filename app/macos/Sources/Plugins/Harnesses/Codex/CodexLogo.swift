import MokuseiPluginUI
import SwiftUI

/// The Codex SVG rendered as native vector geometry. Arc segments are converted
/// to cubic Beziers at export time; the original view box and gradient are kept.
public struct CodexLogo: View {
    /// The approved running-card palette belongs to this harness.
    public static let threadCardCloudPalette = NativeCloudPalette.blueIndigo

    public let size: CGFloat
    public init(size: CGFloat = 24) { self.size = size }
    public var body: some View {
        CodexLogoShape()
            .fill(LinearGradient(stops: [
                .init(color: Color(red: 177 / 255, green: 167 / 255, blue: 1), location: 0),
                .init(color: Color(red: 122 / 255, green: 157 / 255, blue: 1), location: 0.5),
                .init(color: Color(red: 57 / 255, green: 65 / 255, blue: 1), location: 1)
            ], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    /// Shared native cards accept image data URLs. Render a sharp native PNG
    /// once so those surfaces never depend on AppKit interpreting SVG markup.
    @MainActor public static let source = nativeLogoPNG { CodexLogo(size: 64) }

    public static let svgSource = ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="3 3 18 18"><title>Codex</title><path d="M9.064 3.344a4.578 4.578 0 012.285-.312c1 .115 1.891.54 2.673 1.275.01.01.024.017.037.021a.09.09 0 00.043 0 4.55 4.55 0 013.046.275l.047.022.116.057a4.581 4.581 0 012.188 2.399c.209.51.313 1.041.315 1.595a4.24 4.24 0 01-.134 1.223.123.123 0 00.03.115c.594.607.988 1.33 1.183 2.17.289 1.425-.007 2.71-.887 3.854l-.136.166a4.548 4.548 0 01-2.201 1.388.123.123 0 00-.081.076c-.191.551-.383 1.023-.74 1.494-.9 1.187-2.222 1.846-3.711 1.838-1.187-.006-2.239-.44-3.157-1.302a.107.107 0 00-.105-.024c-.388.125-.78.143-1.204.138a4.441 4.441 0 01-1.945-.466 4.544 4.544 0 01-1.61-1.335c-.152-.202-.303-.392-.414-.617a5.81 5.81 0 01-.37-.961 4.582 4.582 0 01-.014-2.298.124.124 0 00.006-.056.085.085 0 00-.027-.048 4.467 4.467 0 01-1.034-1.651 3.896 3.896 0 01-.251-1.192 5.189 5.189 0 01.141-1.6c.337-1.112.982-1.985 1.933-2.618.212-.141.413-.251.601-.33.215-.089.43-.164.646-.227a.098.098 0 00.065-.066 4.51 4.51 0 01.829-1.615 4.535 4.535 0 011.837-1.388zm3.482 10.565a.637.637 0 000 1.272h3.636a.637.637 0 100-1.272h-3.636zM8.462 9.23a.637.637 0 00-1.106.631l1.272 2.224-1.266 2.136a.636.636 0 101.095.649l1.454-2.455a.636.636 0 00.005-.64L8.462 9.23z" fill="url(#codex-gradient)"/><defs><linearGradient gradientUnits="userSpaceOnUse" id="codex-gradient" x1="12" x2="12" y1="3" y2="21"><stop stop-color="#B1A7FF"/><stop offset=".5" stop-color="#7A9DFF"/><stop offset="1" stop-color="#3941FF"/></linearGradient></defs></svg>"##
}

private struct CodexLogoShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: .init(x: 9.064, y: 3.344))
        path.addCurve(to: .init(x: 11.349, y: 3.032), control1: .init(x: 9.786562358, y: 3.046712953), control2: .init(x: 10.573188442, y: 2.939304927))
        path.addCurve(to: .init(x: 14.022, y: 4.307), control1: .init(x: 12.349, y: 3.147), control2: .init(x: 13.24, y: 3.572))
        path.addCurve(to: .init(x: 14.059, y: 4.328), control1: .init(x: 14.032, y: 4.317), control2: .init(x: 14.046, y: 4.324))
        path.addCurve(to: .init(x: 14.102, y: 4.328), control1: .init(x: 14.073122788, y: 4.331474371), control2: .init(x: 14.087877212, y: 4.331474371))
        path.addCurve(to: .init(x: 17.148, y: 4.603), control1: .init(x: 15.118649117, y: 4.065458648), control2: .init(x: 16.194812519, y: 4.162617195))
        path.addLine(to: .init(x: 17.195, y: 4.625))
        path.addLine(to: .init(x: 17.311, y: 4.682))
        path.addCurve(to: .init(x: 19.499, y: 7.081), control1: .init(x: 18.30877119, y: 5.187708082), control2: .init(x: 19.087027772, y: 6.041015915))
        path.addCurve(to: .init(x: 19.814, y: 8.676), control1: .init(x: 19.708, y: 7.591), control2: .init(x: 19.812, y: 8.122))
        path.addCurve(to: .init(x: 19.68, y: 9.899), control1: .init(x: 19.8290317, y: 9.088013402), control2: .init(x: 19.783889912, y: 9.500016439))
        path.addCurve(to: .init(x: 19.71, y: 10.014), control1: .init(x: 19.669587854, y: 9.939941617), control2: .init(x: 19.680914913, y: 9.983362009))
        path.addCurve(to: .init(x: 20.893, y: 12.184), control1: .init(x: 20.304, y: 10.621), control2: .init(x: 20.698, y: 11.344))
        path.addCurve(to: .init(x: 20.006, y: 16.038), control1: .init(x: 21.182, y: 13.609), control2: .init(x: 20.886, y: 14.894))
        path.addLine(to: .init(x: 19.87, y: 16.204))
        path.addCurve(to: .init(x: 17.669, y: 17.592), control1: .init(x: 19.287171413, y: 16.871152699), control2: .init(x: 18.522189245, y: 17.353567624))
        path.addCurve(to: .init(x: 17.588, y: 17.668), control1: .init(x: 17.631447683, y: 17.603006079), control2: .init(x: 17.60137322, y: 17.631224094))
        path.addCurve(to: .init(x: 16.848, y: 19.162), control1: .init(x: 17.397, y: 18.219), control2: .init(x: 17.205, y: 18.691))
        path.addCurve(to: .init(x: 13.137, y: 21), control1: .init(x: 15.948, y: 20.349), control2: .init(x: 14.626, y: 21.008))
        path.addCurve(to: .init(x: 9.98, y: 19.698), control1: .init(x: 11.95, y: 20.994), control2: .init(x: 10.898, y: 20.56))
        path.addCurve(to: .init(x: 9.875, y: 19.674), control1: .init(x: 9.951871486, y: 19.671683227), control2: .init(x: 9.911768501, y: 19.662516831))
        path.addCurve(to: .init(x: 8.671, y: 19.812), control1: .init(x: 9.487, y: 19.799), control2: .init(x: 9.095, y: 19.817))
        path.addCurve(to: .init(x: 6.726, y: 19.346), control1: .init(x: 7.995667547, y: 19.806577867), control2: .init(x: 7.330466642, y: 19.647203254))
        path.addCurve(to: .init(x: 5.116, y: 18.011), control1: .init(x: 6.092829584, y: 19.032240757), control2: .init(x: 5.541561829, y: 18.575133643))
        path.addCurve(to: .init(x: 4.702, y: 17.394), control1: .init(x: 4.964, y: 17.809), control2: .init(x: 4.813, y: 17.619))
        path.addCurve(to: .init(x: 4.332, y: 16.433), control1: .init(x: 4.550465793, y: 17.085249464), control2: .init(x: 4.426646246, y: 16.763653289))
        path.addCurve(to: .init(x: 4.318, y: 14.135), control1: .init(x: 4.132201697, y: 15.680625914), control2: .init(x: 4.127383496, y: 14.889752592))
        path.addCurve(to: .init(x: 4.324, y: 14.079), control1: .init(x: 4.324268818, y: 14.117040635), control2: .init(x: 4.326321767, y: 14.097879785))
        path.addCurve(to: .init(x: 4.297, y: 14.031), control1: .init(x: 4.320576349, y: 14.060446973), control2: .init(x: 4.311077546, y: 14.043560211))
        path.addCurve(to: .init(x: 3.263, y: 12.38), control1: .init(x: 3.835068703, y: 13.563438539), control2: .init(x: 3.482007478, y: 12.999701515))
        path.addCurve(to: .init(x: 3.012, y: 11.188), control1: .init(x: 3.117350673, y: 11.998285171), control2: .init(x: 3.032648923, y: 11.596036223))
        path.addCurve(to: .init(x: 3.153, y: 9.588), control1: .init(x: 2.97567092, y: 10.650581056), control2: .init(x: 3.023240676, y: 10.110782404))
        path.addCurve(to: .init(x: 5.086, y: 6.97), control1: .init(x: 3.49, y: 8.476), control2: .init(x: 4.135, y: 7.603))
        path.addCurve(to: .init(x: 5.687, y: 6.64), control1: .init(x: 5.298, y: 6.829), control2: .init(x: 5.499, y: 6.719))
        path.addCurve(to: .init(x: 6.333, y: 6.413), control1: .init(x: 5.902, y: 6.551), control2: .init(x: 6.117, y: 6.476))
        path.addCurve(to: .init(x: 6.398, y: 6.347), control1: .init(x: 6.364353094, y: 6.40327492), control2: .init(x: 6.388754699, y: 6.378497906))
        path.addCurve(to: .init(x: 7.227, y: 4.732), control1: .init(x: 6.562013526, y: 5.75804219), control2: .init(x: 6.84405953, y: 5.20857983))
        path.addCurve(to: .init(x: 9.064, y: 3.344), control1: .init(x: 7.709734183, y: 4.119008421), control2: .init(x: 8.342459245, y: 3.640934177))
        path.closeSubpath()
        path.move(to: .init(x: 12.546, y: 13.909))
        path.addCurve(to: .init(x: 11.944679126, y: 14.545), control1: .init(x: 12.208586467, y: 13.927928647), control2: .init(x: 11.944679126, y: 14.207055942))
        path.addCurve(to: .init(x: 12.546, y: 15.181), control1: .init(x: 11.944679126, y: 14.882944058), control2: .init(x: 12.208586467, y: 15.162071353))
        path.addLine(to: .init(x: 16.182, y: 15.181))
        path.addCurve(to: .init(x: 16.763291772, y: 14.873748902), control1: .init(x: 16.417731513, y: 15.194224362), control2: .init(x: 16.641441967, y: 15.07597861))
        path.addCurve(to: .init(x: 16.763291772, y: 14.216251098), control1: .init(x: 16.885141577, y: 14.671519193), control2: .init(x: 16.885141577, y: 14.418480807))
        path.addCurve(to: .init(x: 16.182, y: 13.909), control1: .init(x: 16.641441967, y: 14.01402139), control2: .init(x: 16.417731513, y: 13.895775638))
        path.addLine(to: .init(x: 12.546, y: 13.909))
        path.closeSubpath()
        path.move(to: .init(x: 8.462, y: 9.23))
        path.addCurve(to: .init(x: 7.603489352, y: 9.010009071), control1: .init(x: 8.282099315, y: 8.936990763), control2: .init(x: 7.902133135, y: 8.839625502))
        path.addCurve(to: .init(x: 7.356, y: 9.861), control1: .init(x: 7.30484557, y: 9.180392639), control2: .init(x: 7.195309847, y: 9.557030686))
        path.addLine(to: .init(x: 8.628, y: 12.085))
        path.addLine(to: .init(x: 7.362, y: 14.221))
        path.addCurve(to: .init(x: 7.585, y: 15.093), control1: .init(x: 7.182783599, y: 14.523375901), control2: .init(x: 7.282624099, y: 14.913783599))
        path.addCurve(to: .init(x: 8.457, y: 14.87), control1: .init(x: 7.887375901, y: 15.272216401), control2: .init(x: 8.277783599, y: 15.172375901))
        path.addLine(to: .init(x: 9.911, y: 12.415))
        path.addCurve(to: .init(x: 9.916, y: 11.775), control1: .init(x: 10.027705844, y: 12.218107721), control2: .init(x: 10.029615344, y: 11.973691663))
        path.addLine(to: .init(x: 8.462, y: 9.23))
        path.closeSubpath()
        return path.applying(CGAffineTransform(a: rect.width / 18, b: 0, c: 0, d: rect.height / 18,
                                              tx: rect.minX - rect.width / 6, ty: rect.minY - rect.height / 6))
    }
}
