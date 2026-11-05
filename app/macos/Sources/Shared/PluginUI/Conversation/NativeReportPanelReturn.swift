import SwiftUI

/// Only an accepted Report Close supplies this value. Covering, opening and
/// execution continuation must keep their own admission and layout policies.
public struct NativeReportPanelReturn {
    public let source: CGRect
    public let progress: CGFloat
    public init(source: CGRect, progress: CGFloat) {
        self.source = source; self.progress = progress
    }
}

public extension EnvironmentValues {
    @Entry var nativeReportPanelReturn: NativeReportPanelReturn? = nil
}

public extension View {
    /// Apply after the main document's shell has its split size. GeometryEffect
    /// changes presentation only: WebKit receives no intermediate width proposals.
    func nativeReportMainReturn() -> some View { modifier(ReportMainReturn()) }
    func nativeReportSidecardReturn() -> some View { modifier(ReportSidecardReturn()) }
}

private struct ReportMainReturn: ViewModifier {
    @Environment(\.nativeReportPanelReturn) private var returning
    func body(content: Content) -> some View {
        content
            .modifier(ReportReturnGeometry(progress: returning?.progress ?? 1,
                source: returning?.source ?? .zero))
            .modifier(ReportReturnOpacity(progress: returning?.progress ?? 1, main: true))
            .allowsHitTesting(returning == nil)
            .accessibilityHidden(returning != nil)
    }
}

private struct ReportSidecardReturn: ViewModifier {
    @Environment(\.nativeReportPanelReturn) private var returning
    func body(content: Content) -> some View {
        content.modifier(ReportReturnOpacity(progress: returning?.progress ?? 1, main: false))
            .allowsHitTesting(returning == nil)
            .accessibilityHidden(returning != nil)
    }
}

private struct ReportReturnGeometry: GeometryEffect {
    var progress: CGFloat
    let source: CGRect
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        let p = min(1, max(0, progress))
        let sx = p + (1 - p) * source.width / max(1, size.width)
        let sy = p + (1 - p) * source.height / max(1, size.height)
        return ProjectionTransform(CGAffineTransform(a: sx, b: 0, c: 0, d: sy,
            tx: source.minX * (1 - p), ty: source.minY * (1 - p)))
    }
}

private struct ReportReturnOpacity: ViewModifier, @MainActor Animatable {
    var progress: CGFloat
    let main: Bool
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        // Preserve the main shell until the final handoff; auxiliary surfaces
        // fade throughout the very same return, without moving or folding.
        content.opacity(Double(min(1, max(0, progress) / (main ? 0.14 : 1))))
    }
}
