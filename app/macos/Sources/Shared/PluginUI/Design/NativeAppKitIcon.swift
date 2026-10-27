import SwiftUI
import AppKit

public extension NativeIcon {
    /// Native controls on both platforms use the same bundled Lucide paths.
    @MainActor
    static func platformImage(name: String, size: CGFloat = 16, strokeWidth: CGFloat = 1.5) -> NativePlatformImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(name: name, bounds: bounds, size: size, strokeWidth: strokeWidth, in: context)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = contains(name) ? name : "Unknown Lucide icon: \(name)"
        return image
    }

    @MainActor
    static func nsImage(name: String, size: CGFloat = 16, strokeWidth: CGFloat = 1.5) -> NativePlatformImage {
        platformImage(name: name, size: size, strokeWidth: strokeWidth)
    }

    private static func draw(name: String, bounds: CGRect, size: CGFloat, strokeWidth: CGFloat, in context: CGContext) {
        context.addPath(path(named: name, in: bounds).cgPath)
        context.setLineWidth(strokeWidth * size / 24)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.strokePath()
    }
}
