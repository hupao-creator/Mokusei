import AppKit
import QuartzCore
import SwiftUI

/// Owns only the insertion mark's presentation; AppKit retains text and selection.
@MainActor final class NativeComposerCaret {
    let layer = CALayer()
    private let core = CALayer()
    private let glow = CALayer()
    private var glowHeight: CGFloat = 0
    private var glowScale: CGFloat = 0
    private var hasFrame = false
    private var darkAppearance = true
    var reduceMotion = false {
        didSet {
            guard reduceMotion != oldValue else { return }
            layer.removeAnimation(forKey: "typing")
            updateBreathing()
        }
    }

    init() {
        layer.name = "composer-insertion-point"
        layer.anchorPoint = .zero
        glow.name = "composer-insertion-glow"
        layer.addSublayer(glow)
        core.name = "composer-insertion-core"
        core.cornerRadius = 1.3
        layer.addSublayer(core)
    }

    func show(at nativeRect: CGRect, color: NSColor, in editor: NSTextView) {
        editor.wantsLayer = true
        guard let parent = editor.layer else { return }
        let height = min(nativeRect.height, (editor.font?.pointSize ?? nativeRect.height) * 25 / 24)
        let rect = CGRect(x: nativeRect.midX - 1.3, y: nativeRect.midY - height / 2, width: 2.6, height: height)
        let previous = layer.presentation()?.position ?? layer.position
        let moved = hasFrame && rect.origin != layer.position
        let animate = moved && !reduceMotion && abs(rect.midY - layer.frame.midY) < min(rect.height, layer.bounds.height) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if layer.superlayer !== parent { parent.addSublayer(layer) }
        if !hasFrame || layer.frame != rect {
            layer.removeAnimation(forKey: "typing")
            layer.frame = rect
        }
        core.frame = layer.bounds
        // Keep native dark ink in light appearance; white reproduces the approved
        // reference on the dark capsule without sacrificing light-mode contrast.
        let dark = editor.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        core.backgroundColor = (dark ? NSColor.white : color).cgColor
        if darkAppearance != dark {
            darkAppearance = dark
            core.removeAnimation(forKey: "breathing")
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
        glow.frame = CGRect(x: 1.3 - 40, y: -40, width: 80, height: height + 80)
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
            if reduceMotion || !hasFrame {
                part.removeAnimation(forKey: "breathing")
            } else if part.animation(forKey: "breathing") == nil {
                // Native blink callbacks and typing must not reset the cycle.
                let breath = CABasicAnimation(keyPath: "opacity")
                breath.fromValue = part.opacity
                // Pale glass needs a stronger ink floor throughout the cycle;
                // the halos still breathe fully in either appearance.
                breath.toValue = part === core ? (darkAppearance ? 0.2 : 0.8) : 0
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
        ZStack {
            Ellipse().fill(Color(red: 1, green: 0.78, blue: 0.21))
                .frame(width: 16, height: height * 0.68)
                .blur(radius: 10).offset(y: -height * 0.24).opacity(0.65)
            Ellipse().fill(Color(red: 0.24, green: 0.66, blue: 1))
                .frame(width: 14, height: height * 0.60)
                .blur(radius: 9).offset(y: height * 0.25).opacity(0.65)
            Capsule().fill(LinearGradient(colors: [
                Color(red: 1, green: 0.93, blue: 0.61), .white,
                Color(red: 0.72, green: 0.9, blue: 1)
            ], startPoint: .top, endPoint: .bottom))
                .frame(width: 4.6, height: height).blur(radius: 3).opacity(0.8)
        }
        .frame(width: 80, height: height + 80)
    }
}
