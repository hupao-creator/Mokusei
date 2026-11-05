import AppKit
import QuartzCore
import SwiftUI

/// Preparation retains layout without a start time. Both native surfaces use
/// the same monotonic start and duration as the owning route's completion.
public struct NativeReportPanelReturn {
    public let source: CGRect
    public let startedAt: TimeInterval?
    public let duration: TimeInterval
    public init(source: CGRect, startedAt: TimeInterval?, duration: TimeInterval) {
        self.source = source; self.startedAt = startedAt; self.duration = duration
    }
}

public extension EnvironmentValues {
    @Entry var nativeReportPanelReturn: NativeReportPanelReturn? = nil
}

public extension View {
    func nativeReportMainReturn(size: CGSize) -> some View {
        ReportReturnHost(content: self, main: true).frame(width: size.width, height: size.height)
    }
    func nativeReportSidecardReturn(size: CGSize) -> some View {
        ReportReturnHost(content: self, main: false).frame(width: size.width, height: size.height)
    }
}

private struct ReportReturnHost<Content: View>: NSViewRepresentable {
    let content: Content
    let main: Bool
    @Environment(\.nativeReportPanelReturn) private var returning
    func makeNSView(context: Context) -> ReportReturnView { ReportReturnView() }
    func updateNSView(_ view: ReportReturnView, context: Context) {
        view.update(content: AnyView(content.environment(\.self, context.environment)),
            returning: returning, main: main,
            paperColor: NativePalette.thread.canvas.swiftUI.resolve(in: context.environment).cgColor)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ReportReturnView, context: Context) -> CGSize? {
        // The surrounding production frame owns both dimensions. Do not let an
        // unspecified sizing probe infer a window minimum from the nested reader.
        return CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
    static func dismantleNSView(_ view: ReportReturnView, coordinator: ()) { view.retire() }
}

/// Retain the reader at fixed native bounds for the shared return animation.
/// SwiftUI's GeometryEffect can resize an NSViewRepresentable's viewport;
/// transforming its hosting layer leaves WebKit bounds and line breaks untouched.
@MainActor private final class ReportReturnView: NSView {
    private let carrier = ReportReturnCarrier()
    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private let paper = CALayer()
    private let aperture = CAShapeLayer()
    private var returning: NativeReportPanelReturn?
    private var startedAt: TimeInterval?
    private var main = false
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
    override var fittingSize: NSSize { .zero }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; clipsToBounds = false
        carrier.wantsLayer = true; carrier.clipsToBounds = false
        carrier.layer?.anchorPoint = .zero
        carrier.layer?.addSublayer(paper)
        paper.isHidden = true
        host.wantsLayer = true
        host.sizingOptions = []; host.safeAreaRegions = []
        carrier.addSubview(host); addSubview(carrier)
    }
    required init?(coder: NSCoder) { nil }

    func update(content: AnyView, returning: NativeReportPanelReturn?, main: Bool, paperColor: CGColor) {
        self.returning = returning; self.main = main
        paper.backgroundColor = paperColor
        if returning == nil {
            startedAt = nil
            CATransaction.begin(); CATransaction.setDisableActions(true)
            carrier.layer?.removeAllAnimations()
            host.layer?.removeAllAnimations(); aperture.removeAllAnimations()
            carrier.layer?.mask = nil; paper.isHidden = true
            host.layer?.transform = CATransform3DIdentity; host.layer?.opacity = 1
            carrier.layer?.transform = CATransform3DIdentity
            carrier.layer?.position = .zero; carrier.layer?.opacity = 1
            CATransaction.commit()
            host.rootView = content
            layoutReader()
        }
        // Keep the same root and viewport from preparation through completion.
        // Async reader data may still render, but return never proposes a width
        // or remounts the WebKit tree. Parent selection/input gates are separate.
        startIfReady()
    }

    override func layout() {
        super.layout()
        if returning == nil { layoutReader() }
        startIfReady()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); startIfReady() }

    private func layoutReader() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        carrier.frame = bounds
        host.frame = carrier.bounds
        paper.frame = carrier.bounds
        CATransaction.commit()
    }

    private func startIfReady() {
        guard let returning, let start = returning.startedAt, startedAt != start,
              window != nil, carrier.bounds.width > 0, carrier.bounds.height > 0,
              let layer = carrier.layer else { return }
        startedAt = start
        if main, let content = host.layer {
            NativeReadingPanelReturn.animate(surface: layer, content: content, aperture: aperture, paper: paper,
                fromPosition: .zero,
                fromPath: CGPath(roundedRect: carrier.bounds, cornerWidth: 22, cornerHeight: 22, transform: nil),
                source: returning.source, readerWidth: carrier.bounds.width,
                duration: returning.duration, startedAt: start)
        } else {
            // The auxiliary surface retains its original position and viewport.
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.opacity; fade.toValue = 0
            fade.beginTime = layer.convertTime(start, from: nil); fade.duration = returning.duration
            fade.timingFunction = NativeReadingPanelReturn.timing
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.opacity = 0
            layer.add(fade, forKey: "report.sidecard.return")
            CATransaction.commit()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        returning == nil ? super.hitTest(point) : nil
    }
    override func accessibilityChildren() -> [Any]? {
        returning == nil ? super.accessibilityChildren() : []
    }
    func retire() {
        carrier.layer?.removeAllAnimations()
        host.layer?.removeAllAnimations(); aperture.removeAllAnimations()
        host.rootView = AnyView(EmptyView())
    }
}

private final class ReportReturnCarrier: NSView {
    override var isFlipped: Bool { true }
}
