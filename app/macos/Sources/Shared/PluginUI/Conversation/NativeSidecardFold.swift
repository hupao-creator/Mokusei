import SwiftUI

public enum NativeSidecardTiming {
    public static let duration: TimeInterval = 0.38
    public static let foldAnimation = Animation.timingCurve(0.22, 1, 0.36, 1, duration: duration)
}

/// Geometry is in the workspace's coordinates, including the launcher's real
/// layout bounds. Paint, travel and pointer aperture share one presentation step.
public struct NativeSidecardFold: ViewModifier {
    let progress: CGFloat
    let source: CGRect?
    let destination: CGRect
    let frameIdentifier: String
    var animatesContentSize = false
    // Return policy is independent of the common opening presentation.
    let fadesOnClose: Bool
    let reportReturn: Bool

    public init(progress: CGFloat, source: CGRect?, destination: CGRect,
                frameIdentifier: String, animatesContentSize: Bool = false, fadesOnClose: Bool = false, reportReturn: Bool = false) {
        self.progress = progress; self.source = source; self.destination = destination
        self.frameIdentifier = frameIdentifier; self.animatesContentSize = animatesContentSize
        self.fadesOnClose = fadesOnClose; self.reportReturn = reportReturn
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
            .modifier(ReportSidecardReturnHost(enabled: reportReturn, size: destination.size))
            .modifier(NativeSidecardFoldPresentation(rect: geometry.aperture, progress: progress,
                offset: geometry.offset, destination: destination,
                fadingReturn: fadesOnClose && progress == 0, frameIdentifier: frameIdentifier))
    }
}

/// Keep the per-frame work below the document's layout boundary. Paint, pointer
/// geometry and diagnostics must still receive the very same interpolated rect;
/// animating only the mask can expose controls outside the visible aperture.
private struct NativeSidecardFoldPresentation: ViewModifier, @preconcurrency Animatable {
    var rect: CGRect
    var progress: CGFloat
    var offset: CGPoint
    let destination: CGRect
    let fadingReturn: Bool
    let frameIdentifier: String
    @Environment(\.nativeReportPanelReturn) private var returning
    @State private var presentation = SidecardReturnPresentation()

    typealias RectData = AnimatablePair<CGPoint.AnimatableData, CGSize.AnimatableData>
    typealias FoldData = AnimatablePair<RectData, CGFloat>
    var animatableData: AnimatablePair<FoldData, CGPoint.AnimatableData> {
        get { .init(.init(.init(rect.origin.animatableData, rect.size.animatableData), progress), offset.animatableData) }
        set {
            rect.origin.animatableData = newValue.first.first.first
            rect.size.animatableData = newValue.first.first.second
            progress = newValue.first.second
            offset.animatableData = newValue.second
        }
    }

    func body(content: Content) -> some View {
        // The Report link card historically fades in place on return. Keep
        // that policy in presentation, without a second opening state/timeline
        // or a completion callback that can race a reopened selection.
        let presentedRect = fadingReturn ? CGRect(origin: .zero, size: destination.size) : rect
        let presentedOffset = fadingReturn ? destination.origin : offset
        let pose = presentation.pose(rect: presentedRect, offset: presentedOffset, progress: progress,
            retaining: returning != nil)
        let aperture = NativeSidecardFoldAperture(rect: pose.rect)
        content
            .mask(aperture)
            .contentShape(.interaction, aperture)
            // Keep the shell visible through most of the return; the old short
            // independent fade hid the motion before it could reach its button.
            .opacity(min(1, max(0, pose.progress) * (fadingReturn ? 1 : 5)))
            // Measure the exact presented aperture without exposing document
            // controls or relying on their synthesized accessibility union.
            .overlay(alignment: .topLeading) {
                NativeReadingPanelFrame(identifier: frameIdentifier)
                    .frame(width: pose.rect.width, height: pose.rect.height)
                    .offset(x: pose.rect.minX, y: pose.rect.minY)
                    .allowsHitTesting(false)
            }
            .offset(x: pose.offset.x, y: pose.offset.y)
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

/// Retain the last interpolated aperture when a Report returns during a fold.
/// This memo never publishes state or changes document layout; the independent
/// Report opacity owns departure while the fold's existing timeline can settle.
@MainActor private final class SidecardReturnPresentation {
    struct Pose { let rect: CGRect; let offset: CGPoint; let progress: CGFloat }
    private var presented: Pose?
    func pose(rect: CGRect, offset: CGPoint, progress: CGFloat, retaining: Bool) -> Pose {
        let next = Pose(rect: rect, offset: offset, progress: progress)
        if !retaining || presented == nil { presented = next }
        return presented ?? next
    }
}

private struct ReportSidecardReturnHost: ViewModifier {
    let enabled: Bool
    let size: CGSize
    func body(content: Content) -> some View {
        if enabled { content.nativeReportSidecardReturn(size: size) }
        else { content }
    }
}
