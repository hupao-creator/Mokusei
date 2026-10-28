import AppKit
import CoreText

/// The accepted Electron arc around the current capsule: open 288° span,
/// centered 20° left of the top. Its body remains the production glass capsule.
public struct NativeMokuReasoningArcTrack {
    public let body: CGRect
    public init(body: CGRect) { self.body = body }
    public var radius: CGFloat { max(body.width, body.height) / 2 + 19 }
    public var length: CGFloat { 288 * .pi / 180 * radius }

    public func sample(_ distance: CGFloat) -> (point: CGPoint, angle: CGFloat) {
        let progress: CGFloat = min(1, max(0, distance / max(1, length)))
        let degrees: CGFloat = -254 + progress * 288
        let angle = degrees * CGFloat.pi / 180
        return (CGPoint(x: body.midX + cos(angle) * radius, y: body.midY + sin(angle) * radius), angle + .pi / 2)
    }

    /// Cover the full reading path, including its open lower endpoint. Expanding
    /// by the actual glyph ink radius keeps future FIFO positions inside the
    /// viewport without moving the capsule each time a word advances.
    @MainActor public func inkBounds(for glyphs: [MokuReasoningGlyph]) -> CGRect {
        let inkRadius = NativeMokuReasoningArcPainter.inkRadius(for: glyphs)
        let angles: [CGFloat] = [-254, -180, -90, 0, 34]
        let points = angles.map { angle in
            CGPoint(x: body.midX + cos(angle * .pi / 180) * radius,
                    y: body.midY + sin(angle * .pi / 180) * radius)
        }
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .insetBy(dx: -inkRadius, dy: -inkRadius)
    }
}

/// CoreText only paints prepared glyphs. The activity host owns scheduling,
/// visibility, current text admission and reversible role transitions.
@MainActor public enum NativeMokuReasoningArcPainter {
    private static let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    @MainActor private final class Line {
        let value: CTLine
        let width: Double
        let ink: CGRect
        init(_ text: String) {
            value = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
            ]))
            var ascent = CGFloat.zero, descent = CGFloat.zero
            width = CTLineGetTypographicBounds(value, &ascent, &descent, nil)
            let pathInk = CTLineGetBoundsWithOptions(value, [.useGlyphPathBounds])
            // Color-emoji fonts need not provide an outline path. Their actual
            // typographic metrics still reserve the complete fallback glyph.
            ink = pathInk.isNull || pathInk.isEmpty
                ? CGRect(x: 0, y: -descent, width: width, height: ascent + descent) : pathInk
        }
    }
    private static let cache: NSCache<NSString, Line> = {
        let result = NSCache<NSString, Line>(); result.countLimit = 512; return result
    }()
    private static func line(_ value: String) -> Line {
        let key = value as NSString
        if let result = cache.object(forKey: key) { return result }
        let result = Line(value); cache.setObject(result, forKey: key); return result
    }
    public static func measure(_ value: String) -> Double { line(value).width }

    static func inkRadius(for glyphs: [MokuReasoningGlyph]) -> CGFloat {
        var result: CGFloat = 0
        for value in glyphs.isEmpty ? ["M"] : glyphs.map(\.value) {
            let glyph = line(value)
            guard !glyph.ink.isNull, !glyph.ink.isEmpty else { continue }
            let rect = glyph.ink.offsetBy(dx: -glyph.width / 2, dy: -(font.ascender + font.descender) / 2)
            for x in [rect.minX, rect.maxX] {
                for y in [rect.minY, rect.maxY] { result = max(result, hypot(x, y)) }
            }
        }
        return result + 1 // Antialiased edge coverage outside CoreText's path bounds.
    }

    public static func paint(glyphs: [MokuReasoningGlyph], track: NativeMokuReasoningArcTrack,
                             in context: CGContext, dark: Bool, opacity: Double = 1,
                             gather: Double = 0, reveal: Double = 1) {
        let ink = dark ? NSColor(srgbRed: 0.71, green: 0.77, blue: 0.66, alpha: 1)
                       : NSColor(srgbRed: 0.30, green: 0.365, blue: 0.27, alpha: 1)
        context.saveGState(); defer { context.restoreGState() }
        context.setFillColor(ink.cgColor)
        for glyph in glyphs {
            let group = min(2, Int(floor(glyph.position * 3)))
            let seed = (Double(group) + 0.5) / 3
            let position = glyph.position + (seed - glyph.position) * min(1, max(0, gather))
            let distance = abs(glyph.position * 3 - Double(group) - 0.5) * 2
            let opened = min(1, max(0, (reveal * 1.25 - distance) / 0.25))
            let sample = track.sample(position * track.length)
            let text = line(glyph.value)
            context.saveGState()
            context.translateBy(x: sample.point.x, y: sample.point.y); context.rotate(by: sample.angle)
            context.scaleBy(x: 1, y: -1); context.textMatrix = .identity
            context.setAlpha(glyph.opacity * 0.92 * min(1, max(0, opacity)) * opened)
            context.textPosition = CGPoint(x: -text.width / 2, y: -(font.ascender + font.descender) / 2)
            CTLineDraw(text.value, context); context.restoreGState()
        }
    }
}
