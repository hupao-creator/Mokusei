import AppKit
import QuartzCore

/// Agent and Report return the retained reader through the same native phases.
/// The shell changes aperture while the reader scales uniformly at fixed bounds;
/// content fades before arrival and the final shell handoff owns completion.
@MainActor
enum NativeReadingPanelReturn {
    static let timing = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)

    static func animate(surface: CALayer, content: CALayer, aperture: CAShapeLayer, paper: CALayer,
                        fromPosition: CGPoint, fromPath: CGPath?, source: CGRect,
                        readerWidth: CGFloat, duration: TimeInterval,
                        startedAt: TimeInterval? = nil,
                        generation: Int? = nil, delegate: (any CAAnimationDelegate)? = nil) {
        let fromOpacity = content.presentation()?.opacity ?? content.opacity
        let fromTransform = content.presentation()?.transform ?? content.transform
        let fromSurfaceOpacity = surface.presentation()?.opacity ?? surface.opacity
        let scale = source.width / max(1, readerWidth)
        let transform = CATransform3DMakeScale(scale, scale, 1)
        let destinationPath = CGPath(roundedRect: CGRect(origin: .zero, size: source.size),
            cornerWidth: 22, cornerHeight: 22, transform: nil)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        surface.removeAllAnimations(); aperture.removeAllAnimations()
        paper.isHidden = false
        surface.mask = aperture
        surface.position = source.origin; surface.opacity = 0
        aperture.path = destinationPath
        content.anchorPoint = .zero; content.transform = transform; content.opacity = 0

        let travel = CABasicAnimation(keyPath: "position")
        travel.fromValue = NSValue(point: fromPosition); travel.toValue = NSValue(point: source.origin)
        let clip = CABasicAnimation(keyPath: "path")
        clip.fromValue = fromPath; clip.toValue = destinationPath
        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = NSValue(caTransform3D: fromTransform)
        shrink.toValue = NSValue(caTransform3D: transform)
        for animation in [travel, clip, shrink] {
            animation.duration = duration * 0.86
            animation.timingFunction = timing
        }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [fromOpacity, 0, 0]; fade.keyTimes = [0, 0.8, 1]
        fade.duration = duration; fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let handoff = CAKeyframeAnimation(keyPath: "opacity")
        handoff.values = [fromSurfaceOpacity, fromSurfaceOpacity, 0]
        handoff.keyTimes = [0, 0.86, 1]; handoff.duration = duration
        handoff.timingFunction = CAMediaTimingFunction(name: .linear)
        if let generation { handoff.setValue(generation, forKey: "generation") }
        handoff.delegate = delegate
        for (layer, animation, key) in [
            (surface, travel, "reading.travel"), (aperture, clip, "reading.aperture"),
            (content, shrink, "reading.content.scale"), (content, fade, "reading.fade"),
            (surface, handoff, "reading.card.handoff")
        ] {
            if let startedAt { animation.beginTime = layer.convertTime(startedAt, from: nil) }
            layer.add(animation, forKey: key)
        }
        CATransaction.commit()
    }
}
