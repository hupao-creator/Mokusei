import AppKit
import QuartzCore
import SwiftUI

/// The Codex status ring, with its quarter-turn highlight owned by the compositor.
public struct NativeStatusSpinner: View {
    public var size: CGFloat
    public var lineWidth: CGFloat
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(size: CGFloat = 12, lineWidth: CGFloat = 1.5) {
        self.size = size
        self.lineWidth = lineWidth
    }

    public var body: some View {
        SpinnerSurface(lineWidth: lineWidth, animates: scenePhase != .background && !reduceMotion)
            .frame(width: size, height: size)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct SpinnerSurface: NSViewRepresentable {
    let lineWidth: CGFloat
    let animates: Bool

    func makeNSView(context: Context) -> SpinnerView { SpinnerView(frame: .zero) }
    func updateNSView(_ view: SpinnerView, context: Context) {
        view.configure(lineWidth: lineWidth, animates: animates,
            track: NativePalette.pair(0xc5c4bd, 0x686b60).swiftUI.resolve(in: context.environment).cgColor,
            ink: NativePalette.thread.accent.swiftUI.resolve(in: context.environment).cgColor)
    }
    static func dismantleNSView(_ view: SpinnerView, coordinator: ()) { view.stop() }
}

@MainActor
private final class SpinnerView: NSView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private var animates = false
    private var lineWidth: CGFloat = 1.5

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(arc)
        track.fillColor = nil
        arc.fillColor = nil
        arc.transform = CATransform3DMakeRotation(.pi * 0.75, 0, 0, 1)
    }
    required init?(coder: NSCoder) { nil }
    isolated deinit { NotificationCenter.default.removeObserver(self) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }
    override var acceptsFirstResponder: Bool { false }

    func configure(lineWidth: CGFloat, animates: Bool, track: CGColor, ink: CGColor) {
        self.lineWidth = lineWidth
        self.animates = animates
        CATransaction.begin(); CATransaction.setDisableActions(true)
        self.track.strokeColor = track
        arc.strokeColor = ink
        CATransaction.commit()
        synchronize()
    }
    override func layout() { super.layout(); synchronize() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); synchronize() }
    override func viewDidHide() { super.viewDidHide(); synchronize() }
    override func viewDidUnhide() { super.viewDidUnhide(); synchronize() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged),
                name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        synchronize()
    }
    @objc private func visibilityChanged(_ note: Notification) { synchronize() }

    func stop() {
        animates = false
        NotificationCenter.default.removeObserver(self)
        synchronize()
    }

    private func synchronize() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let rect = CGRect(origin: .zero, size: bounds.size)
        let ring = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        track.frame = bounds
        track.path = CGPath(ellipseIn: ring, transform: nil)
        track.lineWidth = lineWidth
        arc.bounds = rect
        arc.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: max(0, min(ring.width, ring.height) / 2),
                    startAngle: 0, endAngle: -.pi / 2, clockwise: true)
        arc.path = path
        arc.lineWidth = lineWidth
        track.contentsScale = window?.backingScaleFactor ?? 1
        arc.contentsScale = track.contentsScale
        let active = animates && !isHiddenOrHasHiddenAncestor && window?.occlusionState.contains(.visible) == true
            && bounds.width > 0 && bounds.height > 0
        if active && arc.animation(forKey: "spin") == nil {
            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = Double.pi * 0.75
            animation.toValue = Double.pi * 0.75 - 2 * Double.pi
            animation.duration = 0.8
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            let phase = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.8)
            animation.beginTime = arc.convertTime(CACurrentMediaTime(), from: nil) - phase
            arc.add(animation, forKey: "spin")
        } else if !active {
            // Freeze the actual presentation before retiring the animation. Reduce
            // Motion uses the same static decorative mark, without a frame clock.
            if let presentation = arc.presentation() { arc.transform = presentation.transform }
            arc.removeAnimation(forKey: "spin")
        }
    }
}
