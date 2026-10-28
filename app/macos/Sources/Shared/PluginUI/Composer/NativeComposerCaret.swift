import AppKit
import QuartzCore

/// Owns only the insertion mark's presentation; AppKit retains text and selection.
@MainActor final class NativeComposerCaret {
    let layer = CALayer()
    private let core = CALayer()
    private let warmGlow = CALayer()
    private let coolGlow = CALayer()
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
        for glow in [warmGlow, coolGlow] {
            glow.shadowOffset = .zero
            glow.shadowRadius = 6
            glow.shadowOpacity = 1
            glow.opacity = 0.65
            layer.addSublayer(glow)
        }
        warmGlow.backgroundColor = NSColor(srgbRed: 1, green: 0.78, blue: 0.21, alpha: 0.18).cgColor
        warmGlow.shadowColor = NSColor(srgbRed: 1, green: 0.78, blue: 0.21, alpha: 1).cgColor
        coolGlow.backgroundColor = NSColor(srgbRed: 0.24, green: 0.66, blue: 1, alpha: 0.18).cgColor
        coolGlow.shadowColor = NSColor(srgbRed: 0.24, green: 0.66, blue: 1, alpha: 1).cgColor
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
        for (glow, center) in [(warmGlow, height * 0.24), (coolGlow, height * 0.76)] {
            glow.frame = CGRect(x: -0.7, y: center - height * 0.18, width: 4, height: height * 0.36)
            glow.cornerRadius = 2
            glow.shadowPath = CGPath(ellipseIn: glow.bounds, transform: nil)
        }
        for part in [layer, core, warmGlow, coolGlow] {
            part.contentsScale = editor.window?.backingScaleFactor ?? 2
        }
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
        for part in [core, warmGlow, coolGlow] {
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
        for part in [core, warmGlow, coolGlow] { part.removeAllAnimations() }
        layer.removeFromSuperlayer()
        hasFrame = false
    }
}
