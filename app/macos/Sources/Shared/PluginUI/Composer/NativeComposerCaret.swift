import AppKit
import QuartzCore
import SwiftUI

/// Shares Chief's insertion effect while leaving input and selection with AppKit.
@MainActor open class NativeCaretTextView: NSTextView {
    package var emphasizedInsertionPointColor: NSColor = .white
    package var emphasizedInsertionPoint = false {
        didSet {
            guard emphasizedInsertionPoint != oldValue else { return }
            if emphasizedInsertionPoint { wantsLayer = true }
            caret.remove()
            needsDisplay = true
        }
    }
    private let caret = NativeComposerCaret()

    open override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        caret.remove()
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    public override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard emphasizedInsertionPoint, !hasMarkedText() else {
            caret.remove()
            super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
            return
        }
        guard shouldDrawInsertionPoint, window?.isKeyWindow == true,
              window?.occlusionState.contains(.visible) == true,
              selectedRange().length == 0, !isHiddenOrHasHiddenAncestor, rect.intersects(visibleRect) else {
            caret.remove()
            return
        }
        // Off callbacks also erase the old insertion rectangle during movement.
        // Keep the breathing layer alive, but only position it on an on callback.
        if flag { caret.show(at: rect, in: self, color: emphasizedInsertionPointColor) }
    }
    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting flag: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: flag)
        if ranges.count != 1 || selectedRange().length != 0 { caret.remove() }
    }
    public override func viewDidHide() {
        super.viewDidHide()
        caret.remove()
    }
    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        caret.remove()
        if let window {
            for name in [NSWindow.didResignKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(caretWindowChanged), name: name, object: window)
            }
        }
    }
    @objc private func caretWindowChanged() {
        if window?.isKeyWindow != true || window?.occlusionState.contains(.visible) != true { caret.remove() }
    }
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // CALayer colors are resolved values; refresh even without an edit.
        caret.remove()
        needsDisplay = true
        if emphasizedInsertionPoint { updateInsertionPointStateAndRestartTimer(true) }
    }
    open override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { caret.remove() }
        return accepted
    }
}

/// Owns only the insertion mark's presentation; AppKit retains text and selection.
@MainActor private final class NativeComposerCaret {
    /// Optical tuning after visual review. The approved 25/24 study is lengthened
    /// by one point and moved down by the same amount, so the top edge drops half
    /// a point while the lower end gains 1.5 points. Glyph layout is untouched.
    private static let coreHeightGrowth: CGFloat = 1
    private static let coreVerticalOffset: CGFloat = 1
    let layer = CALayer()
    private let core = CALayer()
    private let glow = CALayer()
    private var glowHeight: CGFloat = 0
    private var glowScale: CGFloat = 0
    private var hasFrame = false

    init() {
        layer.name = "composer-insertion-point"
        layer.anchorPoint = .zero
        glow.name = "composer-insertion-glow"
        layer.addSublayer(glow)
        core.name = "composer-insertion-core"
        core.cornerRadius = 1.3
        layer.addSublayer(core)
    }

    func show(at nativeRect: CGRect, in editor: NSTextView, color: NSColor) {
        editor.wantsLayer = true
        guard let parent = editor.layer else { return }
        let nativeWidth: CGFloat = 2.6
        let studyHeight = min(nativeRect.height, (editor.font?.pointSize ?? nativeRect.height) * 25 / 24)
        let nativeHeight = min(nativeRect.height, studyHeight + Self.coreHeightGrowth)
        // NSTextView is flipped, so increasing y moves down; keep the optical
        // correction downward for any text-view coordinate system.
        let verticalOffset = editor.isFlipped ? Self.coreVerticalOffset : -Self.coreVerticalOffset
        // AppKit supplies view coordinates, which need not match its backing
        // layer's coordinates (notably for flipped or scaled text views).
        let rect = editor.convertToLayer(CGRect(x: nativeRect.midX - nativeWidth / 2,
            y: nativeRect.midY - nativeHeight / 2 + verticalOffset,
            width: nativeWidth, height: nativeHeight))
        let width = rect.width, height = rect.height
        let previous = layer.presentation()?.position ?? layer.position
        let moved = hasFrame && rect.origin != layer.position
        let animate = moved && abs(rect.midY - layer.frame.midY) < min(rect.height, layer.bounds.height) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if layer.superlayer !== parent { parent.addSublayer(layer) }
        if !hasFrame || layer.frame != rect {
            layer.removeAnimation(forKey: "typing")
            layer.frame = rect
        }
        core.frame = layer.bounds
        core.cornerRadius = width / 2
        editor.effectiveAppearance.performAsCurrentDrawingAppearance {
            core.backgroundColor = color.cgColor
        }
        let scale = editor.window?.backingScaleFactor ?? 2
        if glowHeight != height || glowScale != scale {
            // Rasterize the reference's actual blurred shapes once per geometry,
            // not on native blink callbacks or each animation frame.
            let renderer = ImageRenderer(content: ComposerCaretGlow(height: height))
            renderer.scale = scale
            if let image = renderer.cgImage {
                glow.contents = image
                glowHeight = height
                glowScale = scale
            }
        }
        glow.frame = CGRect(x: width / 2 - 40, y: -40, width: 80, height: height + 80)
        for part in [layer, core, glow] { part.contentsScale = scale }
        hasFrame = true
        CATransaction.commit()
        updateBreathing()
        if animate {
            let motion = CABasicAnimation(keyPath: "position")
            motion.fromValue = previous; motion.toValue = rect.origin
            motion.duration = 0.12
            motion.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            layer.add(motion, forKey: "typing")
        }
    }

    private func updateBreathing() {
        for part in [core, glow] {
            if !hasFrame {
                part.removeAnimation(forKey: "breathing")
            } else if part.animation(forKey: "breathing") == nil {
                // Native blink callbacks and typing must not reset the cycle.
                let breath = CABasicAnimation(keyPath: "opacity")
                breath.fromValue = part.opacity
                breath.toValue = part === core ? 0.2 : 0
                breath.duration = 1.2
                breath.autoreverses = true
                breath.repeatCount = .infinity
                breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                part.add(breath, forKey: "breathing")
            }
        }
    }

    func remove() {
        layer.removeAllAnimations()
        for part in [core, glow] { part.removeAllAnimations() }
        layer.removeFromSuperlayer()
        hasFrame = false
    }
}

/// Matches the approved cursor study; the extra canvas preserves the blur tails.
private struct ComposerCaretGlow: View {
    let height: CGFloat

    var body: some View {
        let scale = height / 25
        ZStack {
            Ellipse().fill(Color(red: 1, green: 0.78, blue: 0.21))
                .frame(width: 16 * scale, height: height * 0.68)
                .blur(radius: 10 * scale).offset(y: -height * 0.24).opacity(0.65)
            Ellipse().fill(Color(red: 0.24, green: 0.66, blue: 1))
                .frame(width: 14 * scale, height: height * 0.60)
                .blur(radius: 9 * scale).offset(y: height * 0.25).opacity(0.65)
            Capsule().fill(LinearGradient(colors: [
                Color(red: 1, green: 0.93, blue: 0.61), .white,
                Color(red: 0.72, green: 0.9, blue: 1)
            ], startPoint: .top, endPoint: .bottom))
                .frame(width: 4.6, height: height).blur(radius: 3 * scale).opacity(0.8)
        }
        .frame(width: 80, height: height + 80)
    }
}
