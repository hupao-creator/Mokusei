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
            returning: returning, main: main)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ReportReturnView, context: Context) -> CGSize? {
        // The surrounding production frame owns both dimensions. Do not let an
        // unspecified sizing probe infer a window minimum from the nested reader.
        return CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
    static func dismantleNSView(_ view: ReportReturnView, coordinator: ()) { view.retire() }
}

/// Retain the actual reader and transform a separate native carrier. SwiftUI's
/// GeometryEffect can resize an NSViewRepresentable's viewport; a CALayer
/// transform here leaves WebKit bounds and its line breaks untouched.
@MainActor private final class ReportReturnView: NSView {
    private let carrier = ReportReturnCarrier()
    private let host = NSHostingView(rootView: AnyView(EmptyView()))
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
        host.sizingOptions = []; host.safeAreaRegions = []
        carrier.addSubview(host); addSubview(carrier)
    }
    required init?(coder: NSCoder) { nil }

    func update(content: AnyView, returning: NativeReportPanelReturn?, main: Bool) {
        self.returning = returning; self.main = main
        if returning == nil {
            startedAt = nil
            CATransaction.begin(); CATransaction.setDisableActions(true)
            carrier.layer?.removeAllAnimations()
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
        CATransaction.commit()
    }

    private func startIfReady() {
        guard let returning, let start = returning.startedAt, startedAt != start,
              window != nil, carrier.bounds.width > 0, carrier.bounds.height > 0,
              let layer = carrier.layer else { return }
        startedAt = start
        let begin = layer.convertTime(start, from: nil)
        let timing = NativeReadingPageTiming.replacementTimingFunction
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if main {
            let destination = returning.source.origin
            let transform = CATransform3DMakeScale(returning.source.width / carrier.bounds.width,
                returning.source.height / carrier.bounds.height, 1)
            let travel = CABasicAnimation(keyPath: "position")
            travel.fromValue = NSValue(point: .zero); travel.toValue = NSValue(point: destination)
            travel.beginTime = begin; travel.duration = returning.duration; travel.timingFunction = timing
            let scale = CABasicAnimation(keyPath: "transform")
            scale.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
            scale.toValue = NSValue(caTransform3D: transform)
            scale.beginTime = begin; scale.duration = returning.duration; scale.timingFunction = timing
            layer.position = destination; layer.transform = transform
            layer.add(travel, forKey: "report.return.position")
            layer.add(scale, forKey: "report.return.scale")
        }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = main ? [1, 1, 0] : [1, 0]
        fade.keyTimes = main ? [0, 0.86, 1] : [0, 1]
        fade.beginTime = begin; fade.duration = returning.duration
        fade.timingFunction = main ? CAMediaTimingFunction(name: .linear) : timing
        layer.opacity = 0
        layer.add(fade, forKey: "report.return.opacity")
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        returning == nil ? super.hitTest(point) : nil
    }
    override func accessibilityChildren() -> [Any]? {
        returning == nil ? super.accessibilityChildren() : []
    }
    func retire() {
        carrier.layer?.removeAllAnimations()
        host.rootView = AnyView(EmptyView())
    }
}

private final class ReportReturnCarrier: NSView {
    override var isFlipped: Bool { true }
}
