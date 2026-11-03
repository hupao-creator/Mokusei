import SwiftUI

/// Geometry is in the workspace's coordinates, including the launcher's real
/// layout bounds. Paint, travel and pointer aperture share one presentation step.
struct NativeSidecardFold: ViewModifier, @preconcurrency Animatable {
    var progress: CGFloat
    var source: CGRect?
    var destination: CGRect
    let frameIdentifier: String

    private typealias Pair = AnimatablePair<CGFloat, CGFloat>
    typealias RectData = AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>>
    var animatableData: AnimatablePair<CGFloat, AnimatablePair<RectData, RectData>> {
        get { .init(progress, .init(data(origin), data(destination))) }
        set {
            progress = newValue.first
            source = rect(newValue.second.first)
            destination = rect(newValue.second.second)
        }
    }

    private var origin: CGRect {
        source ?? CGRect(x: destination.maxX - 42, y: destination.midY - 21, width: 42, height: 42)
    }

    func body(content: Content) -> some View {
        let geometry = NativeSidecardFoldGeometry(source: origin, destination: destination, progress: progress)
        let aperture = NativeSidecardFoldAperture(rect: geometry.aperture)
        content
            .frame(width: destination.width, height: destination.height, alignment: .topLeading)
            .mask(aperture)
            .contentShape(.interaction, aperture)
            // Keep the shell visible through most of the return; the old short
            // independent fade hid the motion before it could reach its button.
            .opacity(min(1, max(0, progress) * 5))
            // Measure the exact presented aperture without exposing document
            // controls or relying on their synthesized accessibility union.
            .overlay(alignment: .topLeading) {
                NativeReadingPanelFrame(identifier: frameIdentifier)
                    .frame(width: geometry.aperture.width, height: geometry.aperture.height)
                    .offset(x: geometry.aperture.minX, y: geometry.aperture.minY)
                    .allowsHitTesting(false)
            }
            .offset(x: geometry.offset.x, y: geometry.offset.y)
    }

    private func data(_ rect: CGRect) -> RectData {
        .init(Pair(rect.minX, rect.minY), Pair(rect.width, rect.height))
    }
    private func rect(_ data: RectData) -> CGRect {
        CGRect(x: data.first.first, y: data.first.second, width: data.second.first, height: data.second.second)
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
