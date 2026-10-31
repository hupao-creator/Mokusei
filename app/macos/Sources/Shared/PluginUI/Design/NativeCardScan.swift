import AppKit
import QuartzCore
import SwiftUI

/// The compositor moves the scan; SwiftUI only supplies its geometry and gates.
@MainActor
struct NativeCardScan: NSViewRepresentable {
    let animates: Bool

    func makeNSView(context: Context) -> NativeCardScanView {
        let view = NativeCardScanView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: NativeCardScanView, context: Context) {
        view.update(animates: animates,
                    ink: NativePalette.overview.ink.swiftUI.opacity(0.3).resolve(in: context.environment),
                    clear: Color.clear.resolve(in: context.environment),
                    displayScale: CGFloat(context.environment.displayScale))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeCardScanView,
                     context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    static func dismantleNSView(_ view: NativeCardScanView, coordinator: ()) {
        view.dismantle()
    }
}

@MainActor
final class NativeCardScanView: NSView {
    private static let cycle = 3.4
    private static let animationKey = "overview.scan.position"
    private let root = CALayer()
    private let gradient = CAGradientLayer()
    private var animates = false
    private var running = false
    private var dismantled = false
    private var frozenPhase = 0.0
    private var lastBounds = CGRect.null
    private var lastRate: Float = 0
    private var displayScale: CGFloat = 1
    private var ink: Color.Resolved?
    private var clear: Color.Resolved?
    private weak var observedWindow: NSWindow?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        frozenPhase = Self.wallPhase()
        root.backgroundColor = CGColor(gray: 0, alpha: 0)
        root.masksToBounds = true
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.locations = [0, 0.5, 1]
        root.addSublayer(gradient)
        // This view hosts a layer tree; AppKit still owns the root's view geometry.
        layer = root
        wantsLayer = true
    }

    required init?(coder: NSCoder) { return nil }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }

    func update(animates: Bool, ink: Color.Resolved, clear: Color.Resolved, displayScale: CGFloat) {
        guard !dismantled else { return }
        if self.ink != ink || self.clear != clear {
            self.ink = ink
            self.clear = clear
            withoutActions { gradient.colors = [clear.cgColor, ink.cgColor, clear.cgColor] }
        }
        self.animates = animates
        self.displayScale = displayScale
        synchronize()
    }

    override func layout() {
        super.layout()
        synchronize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        synchronize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        if let window, !dismantled {
            observedWindow = window
            let selector = #selector(resynchronizeAfterNotification(_:))
            NotificationCenter.default.addObserver(self, selector: selector,
                name: NSWindow.didChangeScreenNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: selector,
                name: .NSSystemClockDidChange, object: nil)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: selector,
                name: NSWorkspace.didWakeNotification, object: nil)
        }
        synchronize(forcePhase: true)
    }

    func dismantle() {
        guard !dismantled else { return }
        dismantled = true
        stopObserving()
        pause()
    }

    private func synchronize(forcePhase: Bool = false) {
        guard !dismantled else { return }
        let sizeChanged = bounds != lastBounds
        let rate = NativeFrameRate.preferredRange(for: window?.screen)
        let shouldRun = animates && window != nil && bounds.width > 0 && bounds.height > 0
        let restart = shouldRun && (!running || sizeChanged || rate.maximum != lastRate || forcePhase)
        if running && (!shouldRun || restart) { pause() }
        let scale = max(1, window?.backingScaleFactor ?? displayScale)
        let scaleChanged = root.contentsScale != scale || gradient.contentsScale != scale
        guard sizeChanged || scaleChanged || restart else { return }
        withoutActions {
            if root.contentsScale != scale { root.contentsScale = scale }
            if gradient.contentsScale != scale { gradient.contentsScale = scale }
            if sizeChanged {
                gradient.bounds = CGRect(x: 0, y: 0, width: bounds.width * 0.34, height: bounds.height)
                gradient.position = position(at: frozenPhase)
                lastBounds = bounds
            }
            if restart {
                frozenPhase = Self.wallPhase()
                gradient.position = position(at: frozenPhase)
                let animation = CABasicAnimation(keyPath: "position.x")
                animation.fromValue = bounds.minX - bounds.width * 0.17
                animation.toValue = bounds.minX + bounds.width * 1.17
                animation.duration = Self.cycle
                animation.repeatCount = .infinity
                animation.timingFunction = CAMediaTimingFunction(name: .linear)
                animation.preferredFrameRateRange = rate
                animation.beginTime = gradient.convertTime(CACurrentMediaTime(), from: nil)
                    - frozenPhase * Self.cycle
                gradient.add(animation, forKey: Self.animationKey)
                running = true
                lastRate = rate.maximum
            }
        }
    }

    private func pause() {
        guard running else { return }
        // Capture the presented location before removing the compositor animation.
        if lastBounds.width > 0, let presented = gradient.presentation() {
            frozenPhase = min(1, max(0, Double(
                ((presented.position.x - lastBounds.minX) / lastBounds.width + 0.17) / 1.34)))
        } else {
            frozenPhase = Self.wallPhase()
        }
        withoutActions {
            gradient.position = position(at: frozenPhase)
            gradient.removeAnimation(forKey: Self.animationKey)
        }
        running = false
    }

    private func position(at phase: Double) -> CGPoint {
        CGPoint(x: bounds.minX + bounds.width * (CGFloat(phase) * 1.34 - 0.17), y: bounds.midY)
    }

    private static func wallPhase() -> Double {
        let remainder = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
        return (remainder < 0 ? remainder + cycle : remainder) / cycle
    }

    private func withoutActions(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }

    // Notification delivery need not originate on the main thread.
    @objc nonisolated private func resynchronizeAfterNotification(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.synchronize(forcePhase: true) }
    }

    private func stopObserving() {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification,
                                                   object: observedWindow)
        NotificationCenter.default.removeObserver(self, name: .NSSystemClockDidChange, object: nil)
        NSWorkspace.shared.notificationCenter.removeObserver(self, name: NSWorkspace.didWakeNotification, object: nil)
        observedWindow = nil
    }
}
