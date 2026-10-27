import MokuseiPluginUI
import AppKit
import QuartzCore
import SwiftUI

/// The render server advances the stroke without a SwiftUI update every frame.
struct BrowserProgressRing: NSViewRepresentable {
    let color: Color
    let active: Bool

    func makeNSView(context: Context) -> BrowserProgressView { BrowserProgressView() }
    func updateNSView(_ view: BrowserProgressView, context: Context) {
        view.update(color: NSColor(color), active: active)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BrowserProgressView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
    static func dismantleNSView(_ view: BrowserProgressView, coordinator: ()) { view.stopAnimating() }
}


final class BrowserProgressView: NativePlatformView {
    private let stroke = CAShapeLayer()
    private var color = NativePlatformColor.tintColorForBrowser
    private var active = false
    private var animatedPerimeter: CGFloat = 0
    private let animationKey = "browser-loading"

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        stroke.fillColor = nil
        stroke.lineWidth = 1.5
        stroke.lineCap = .round
        layer?.addSublayer(stroke)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(color: NativePlatformColor, active: Bool) {
        self.color = color; self.active = active
        updateStroke()
    }
    override func layout() { super.layout(); updateStroke() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateStroke() }
    override func viewDidHide() { super.viewDidHide(); stopAnimating() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateStroke() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateStroke() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateStroke() }


    func stopAnimating() {
        stroke.removeAnimation(forKey: animationKey)
        animatedPerimeter = 0
    }

    private func updateStroke() {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        guard rect.width > 0, rect.height > 0 else { stopAnimating(); return }
        let perimeter = 2 * max(0, rect.width - rect.height) + .pi * rect.height
        let phase = animatedPerimeter > 0
            ? (stroke.presentation()?.lineDashPhase ?? 0) / animatedPerimeter * perimeter : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stroke.frame = bounds
        stroke.contentsScale = window?.backingScaleFactor ?? 2
        stroke.path = CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
        effectiveAppearance.performAsCurrentDrawingAppearance { stroke.strokeColor = color.cgColor }
        stroke.lineDashPattern = [NSNumber(value: perimeter * 0.18), NSNumber(value: perimeter * 0.82)]
        if active, window != nil, !isHiddenOrHasHiddenAncestor {
            if animatedPerimeter != perimeter || stroke.animation(forKey: animationKey) == nil {
                let animation = CABasicAnimation(keyPath: "lineDashPhase")
                animation.preferredFrameRateRange = NativeFrameRate.preferredRange
                animation.fromValue = phase
                animation.toValue = phase - perimeter
                animation.duration = 1.5
                animation.repeatCount = .infinity
                animation.timingFunction = CAMediaTimingFunction(name: .linear)
                stroke.add(animation, forKey: animationKey)
                animatedPerimeter = perimeter
            }
        } else { stopAnimating() }
        CATransaction.commit()
    }
}

private extension NativePlatformColor {
    static var tintColorForBrowser: NativePlatformColor {
        .controlAccentColor
    }
}
