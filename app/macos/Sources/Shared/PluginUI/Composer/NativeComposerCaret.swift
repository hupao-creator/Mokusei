import AppKit
import QuartzCore

/// Emphasize the native insertion mark without owning text, selection or blinking.
@MainActor final class NativeComposerCaret {
    let layer = CALayer()
    private var hasFrame = false
    var reduceMotion = false {
        didSet {
            if reduceMotion != oldValue { layer.removeAnimation(forKey: "typing") }
        }
    }

    init() {
        layer.name = "composer-insertion-point"
        layer.anchorPoint = .zero
        layer.cornerRadius = 0.75
    }

    func show(at nativeRect: CGRect, color: NSColor, in editor: NSTextView) {
        editor.wantsLayer = true
        guard let parent = editor.layer else { return }
        let rect = CGRect(x: nativeRect.midX - 1.5, y: nativeRect.minY, width: 3, height: nativeRect.height)
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
        layer.backgroundColor = color.cgColor
        layer.contentsScale = editor.window?.backingScaleFactor ?? 2
        layer.isHidden = false
        hasFrame = true
        CATransaction.commit()
        if animate {
            let motion = CABasicAnimation(keyPath: "position")
            motion.fromValue = previous; motion.toValue = rect.origin
            motion.duration = 0.12
            motion.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            layer.add(motion, forKey: "typing")
        }
    }

    func hide() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.isHidden = true
        CATransaction.commit()
    }

    func remove() {
        layer.removeAllAnimations()
        layer.removeFromSuperlayer()
        hasFrame = false
    }
}
