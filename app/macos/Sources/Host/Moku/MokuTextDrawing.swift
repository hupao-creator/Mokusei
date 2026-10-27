import AppKit

/// Bind AppKit text drawing to the canvas's flipped, top-left coordinate system.
func mokuDrawText(_ text: NSAttributedString, at point: CGPoint, in context: CGContext) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    text.draw(at: point)
    NSGraphicsContext.restoreGraphicsState()
}
