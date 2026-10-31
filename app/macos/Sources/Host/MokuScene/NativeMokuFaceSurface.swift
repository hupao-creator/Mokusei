import MokuseiPluginUI
import SwiftUI

/// The resident character's painted canvas and the seat it occupies. Moku's
/// message row and Settings' header share this seat, so the face keeps one size
/// wherever it sits.
enum NativeMokuFaceLayout {
    /// Canvas the painter scales its 640-unit geometry into.
    static let canvas = CGSize(width: 58, height: 49)
    /// Layout seat that centres the canvas on Moku's row.
    static let seat = CGSize(width: 34, height: 25)
}

/// One face for the whole lifetime of the resident character. Ink is the only
/// property that depends on where the face sits: on the capsule it keeps Moku's
/// white, and in a light Settings panel it takes the panel's ink.
///
/// The blend is interpolated here rather than in the painter so it rides the
/// same SwiftUI transaction as the seat's travel; a canvas-driven colour would
/// flip in a single frame halfway through the shell morph.
struct NativeMokuFaceSurface: View, @MainActor Animatable {
    let controller: NativeMokuCharacterMotion
    let input: NativeMokuCharacterInput
    /// 0 keeps the capsule's own ink, 1 uses `hostInk`.
    var inkAmount: Double
    var hostInk: NativePlatformColor

    var animatableData: Double {
        get { inkAmount }
        set { inkAmount = newValue }
    }

    var body: some View {
        NativeMokuCharacterSurface(controller: controller, input: input, seat: .face,
                                   ink: inkAmount <= 0 ? nil : Self.blend(inkAmount, hostInk))
    }

    /// The painter's two authored inks are white for a dark surface and black
    /// for a light one; only the blend between them is new arithmetic.
    static func blend(_ amount: Double, _ ink: NativePlatformColor) -> NativePlatformColor {
        guard let target = ink.usingColorSpace(.sRGB) else { return ink }
        let progress = min(1, max(0, amount))
        func mix(_ value: CGFloat) -> CGFloat { 1 + (value - 1) * progress }
        return NativePlatformColor(srgbRed: mix(target.redComponent), green: mix(target.greenComponent),
                                   blue: mix(target.blueComponent), alpha: 1)
    }
}
