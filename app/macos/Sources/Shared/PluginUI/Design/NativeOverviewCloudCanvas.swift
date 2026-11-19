import AppKit
import Metal
import QuartzCore
import SwiftUI

/// A settled card can put its background into its canvas's decorative plane.
/// Moving and self-surfaced cards keep their own clipping and stacking context.
public struct NativeOverviewCloudPlacement: Equatable {
    let canvas: NativeOverviewCloudCanvas
    let frame: CGRect

    public init(canvas: NativeOverviewCloudCanvas, frame: CGRect) {
        self.canvas = canvas
        self.frame = frame
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.canvas === rhs.canvas && lhs.frame == rhs.frame
    }
}

public extension EnvironmentValues {
    @Entry var nativeOverviewCloudPlacement: NativeOverviewCloudPlacement? = nil
}

@MainActor
public final class NativeOverviewCloudCanvas {
    private struct Member {
        weak var surface: NativeOverviewCloudSurface?
        let frame: CGRect
        let input: NativeOverviewCloudInput
    }

    private var members: [ObjectIdentifier: Member] = [:]
    private var displayed: [ObjectIdentifier: Member] = [:]
    fileprivate weak var plane: OverviewCloudPlaneView?
    fileprivate var visible = true
    private var scheduled = false
    private var revision: UInt64 = 0

    public init() {}

    func offer(_ surface: NativeOverviewCloudSurface, frame: CGRect, input: NativeOverviewCloudInput) {
        members[ObjectIdentifier(surface)] = Member(surface: surface, frame: frame, input: input)
        invalidate()
    }

    func withdraw(_ surface: NativeOverviewCloudSurface) {
        if members.removeValue(forKey: ObjectIdentifier(surface)) != nil { invalidate() }
    }

    fileprivate func invalidate() {
        revision &+= 1
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.draw()
        }
    }

    private func draw() {
        let version = revision
        guard let plane else { return }
        guard visible, let window = plane.window, window.occlusionState.contains(.visible),
              !plane.isHiddenOrHasHiddenAncestor else {
            // A covering transition may still expose the last composited image.
            plane.pause()
            return
        }
        members = members.filter { $0.value.surface != nil }
        let live = members.filter { $0.value.surface?.window === window }
        guard live.count > 1 else { clear(); return }
        let bounds = live.values.reduce(CGRect.null) { $0.union($1.frame) }
        let occupied = live.values.reduce(0) { $0 + $1.frame.width * $1.frame.height }
        let scale = window.backingScaleFactor * 0.5
        let width = ceil(bounds.width * scale), height = ceil(bounds.height * scale)
        // Bound both empty pixels between distant cards and the two RGBA16F drawables.
        // A single card already needs just one presentation on its own layer.
        guard bounds.width * bounds.height <= occupied * 2,
              width * height <= 4_194_304, max(width, height) <= 4_096,
              let target = plane.target() else { clear(); return }
        let relative = live.mapValues { $0.frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY) }
        let tiles = live.values.map { member in
            NativeOverviewCloudTile(origin: CGPoint(x: member.frame.minX - bounds.minX, y: member.frame.minY - bounds.minY),
                                    input: member.input)
        }
        // A resized target must never expose the old texture at its new position.
        if target.configure(bounds: bounds, rectangles: relative, scale: window.backingScaleFactor) {
            for member in displayed.values { member.surface?.useCanvas(self, enabled: false) }
            displayed.removeAll()
        }
        target.render(tiles, screen: window.screen) { [weak self, weak target] succeeded in
            guard let self, self.revision == version, let target else { return }
            guard succeeded else { self.clear(); return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            target.isHidden = false
            for member in live.values { member.surface?.useCanvas(self, enabled: true) }
            self.displayed = live
            CATransaction.commit()
        }
    }

    fileprivate func clear() {
        revision &+= 1
        plane?.discardTarget()
        let previous = displayed
        displayed.removeAll()
        for member in previous.values { member.surface?.useCanvas(self, enabled: false) }
    }
}

/// Lives under the semantic card contents in the same transformed world plane.
public struct NativeOverviewCloudPlane: NSViewRepresentable {
    let canvas: NativeOverviewCloudCanvas
    let visible: Bool
    public init(canvas: NativeOverviewCloudCanvas, visible: Bool) {
        self.canvas = canvas
        self.visible = visible
    }
    public func makeNSView(context: Context) -> NSView { OverviewCloudPlaneView(canvas: canvas) }
    public func updateNSView(_ view: NSView, context: Context) {
        if canvas.visible != visible {
            canvas.visible = visible
            canvas.invalidate()
        }
    }
    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
    public static func dismantleNSView(_ view: NSView, coordinator: ()) {
        (view as? OverviewCloudPlaneView)?.detach()
    }
}

@MainActor
private final class OverviewCloudPlaneView: NSView {
    let canvas: NativeOverviewCloudCanvas
    private var drawing: OverviewCloudTarget?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(canvas: NativeOverviewCloudCanvas) {
        self.canvas = canvas
        super.init(frame: .zero)
        setAccessibilityElement(false)
        canvas.plane = self
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); canvas.invalidate() }
    override func viewDidHide() { super.viewDidHide(); canvas.invalidate() }
    override func viewDidUnhide() { super.viewDidUnhide(); canvas.invalidate() }

    func target() -> OverviewCloudTarget? {
        if let drawing { return drawing }
        guard let pipeline = NativeOverviewCloudPipeline.shared else { return nil }
        let target = OverviewCloudTarget(pipeline)
        addSubview(target)
        drawing = target
        return target
    }
    func pause() { drawing?.pause() }
    func discardTarget() {
        drawing?.renderer.stop()
        drawing?.removeFromSuperview()
        drawing = nil
    }
    func detach() {
        if canvas.plane === self { canvas.clear(); canvas.plane = nil }
    }
}

@MainActor
private final class OverviewCloudTarget: NSView {
    private let metal: CAMetalLayer
    let renderer: NativeOverviewCloudRenderer
    private var rectangles: [ObjectIdentifier: CGRect] = [:]
    private var generation: UInt64 = 0

    init(_ pipeline: NativeOverviewCloudPipeline) {
        metal = NativeOverviewCloudSurface.makeMetalLayer()
        metal.device = pipeline.device
        renderer = NativeOverviewCloudRenderer(layer: metal, pipeline: pipeline)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(metal)
        isHidden = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(bounds world: CGRect, rectangles: [ObjectIdentifier: CGRect], scale: CGFloat) -> Bool {
        guard frame != world || self.rectangles != rectangles || metal.contentsScale != scale else { return false }
        generation = renderer.retireFrames()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isHidden = true
        frame = world
        metal.frame = bounds
        metal.contentsScale = scale
        metal.drawableSize = CGSize(width: ceil(world.width * scale * 0.5), height: ceil(world.height * scale * 0.5))
        let path = CGMutablePath()
        let corners = RoundedRectangle(cornerRadius: NativeGeometry.overviewCardRadius)
        for rect in rectangles.values {
            // The world and drawable start at the top. This unflipped layer's mask starts at the bottom.
            let local = CGRect(x: rect.minX, y: world.height - rect.maxY, width: rect.width, height: rect.height)
            path.addPath(corners.path(in: local).cgPath)
        }
        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.contentsScale = scale
        mask.path = path
        metal.mask = mask
        self.rectangles = rectangles
        CATransaction.commit()
        return true
    }

    func pause() {
        generation = renderer.retireFrames()
        renderer.pause()
    }

    func render(_ tiles: [NativeOverviewCloudTile], screen: NSScreen?, completion: @escaping @MainActor (Bool) -> Void) {
        renderer.drive(tiles, size: bounds.size, generation: generation,
                       interval: 1 / Double(NativeFrameRate.preferredRange(for: screen).maximum)) { success in
            Task { @MainActor in completion(success) }
        }
    }
}
