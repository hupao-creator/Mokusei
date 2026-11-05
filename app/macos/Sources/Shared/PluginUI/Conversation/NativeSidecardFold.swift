import SwiftUI

public enum NativeSidecardTiming {
    public static let foldAnimation = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.38)
}

/// Geometry is in the workspace's coordinates, including the launcher's real
/// layout bounds. Paint, travel and pointer aperture share one presentation step.
public struct NativeSidecardFold: ViewModifier {
    let progress: CGFloat
    let source: CGRect?
    let destination: CGRect
    let frameIdentifier: String
    var animatesContentSize = false

    public init(progress: CGFloat, source: CGRect?, destination: CGRect,
                frameIdentifier: String, animatesContentSize: Bool = false) {
        self.progress = progress; self.source = source; self.destination = destination
        self.frameIdentifier = frameIdentifier; self.animatesContentSize = animatesContentSize
    }

    private var origin: CGRect {
        source ?? CGRect(x: destination.maxX - 42, y: destination.midY - 21, width: 42, height: 42)
    }

    public func body(content: Content) -> some View {
        let geometry = NativeSidecardFoldGeometry(source: origin, destination: destination, progress: progress)
        content
            .frame(width: destination.width, height: destination.height, alignment: .topLeading)
            // A card choice can also change retained width. Its reader takes
            // that final size once; execution absorption also moves a fixed-size
            // document behind the independently widening main shell.
            .transaction(value: destination.size) { if !animatesContentSize { $0.animation = nil } }
            // The shell may resize independently of the fixed-size document
            // when switching cards with different preferred/retained widths.
            .frame(width: destination.width, height: destination.height, alignment: .topLeading)
            .background(NativePalette.thread.canvas.swiftUI, in: RoundedRectangle(cornerRadius: 21))
            .overlay(RoundedRectangle(cornerRadius: 21).stroke(NativePalette.thread.line.swiftUI.opacity(0.6)))
            .modifier(NativeSidecardFoldPresentation(rect: geometry.aperture, progress: progress,
                frameIdentifier: frameIdentifier))
            .offset(x: geometry.offset.x, y: geometry.offset.y)
    }
}

/// Keep the per-frame work below the document's layout boundary. Paint, pointer
/// geometry and diagnostics must still receive the very same interpolated rect;
/// animating only the mask can expose controls outside the visible aperture.
private struct NativeSidecardFoldPresentation: ViewModifier, @preconcurrency Animatable {
    var rect: CGRect
    var progress: CGFloat
    let frameIdentifier: String

    var animatableData: AnimatablePair<AnimatablePair<CGPoint.AnimatableData, CGSize.AnimatableData>, CGFloat> {
        get { .init(.init(rect.origin.animatableData, rect.size.animatableData), progress) }
        set {
            rect.origin.animatableData = newValue.first.first
            rect.size.animatableData = newValue.first.second
            progress = newValue.second
        }
    }

    func body(content: Content) -> some View {
        let aperture = NativeSidecardFoldAperture(rect: rect)
        content
            .mask(aperture)
            .contentShape(.interaction, aperture)
            // Keep the shell visible through most of the return; the old short
            // independent fade hid the motion before it could reach its button.
            .opacity(min(1, max(0, progress) * 5))
            // Measure the exact presented aperture without exposing document
            // controls or relying on their synthesized accessibility union.
            .overlay(alignment: .topLeading) {
                NativeReadingPanelFrame(identifier: frameIdentifier)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
            }
    }
}

struct NativeSidecardFoldGeometry {
    let aperture: CGRect
    let offset: CGPoint

    init(source: CGRect, destination: CGRect, progress: CGFloat) {
        let p = min(1, max(0, progress))
        let seedSize = CGSize(width: min(source.width, destination.width), height: min(source.height, destination.height))
        let seed = CGRect(x: destination.width - seedSize.width,
            y: min(max(0, source.midY - destination.minY - seedSize.height / 2), destination.height - seedSize.height),
            width: seedSize.width, height: seedSize.height)
        aperture = CGRect(x: seed.minX * (1 - p), y: seed.minY * (1 - p),
            width: seed.width + (destination.width - seed.width) * p,
            height: seed.height + (destination.height - seed.height) * p)
        offset = CGPoint(x: destination.minX + (source.minX - destination.minX - seed.minX) * (1 - p),
            y: destination.minY + (source.minY - destination.minY - seed.minY) * (1 - p))
    }
}

private struct NativeSidecardFoldAperture: Shape {
    let rect: CGRect

    func path(in bounds: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: min(21, min(rect.width, rect.height) / 2))
    }
}
