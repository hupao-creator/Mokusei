// Restored from b478a1f0e; Electron design provenance and adaptations: ../README.md.
@testable import MokuseiUI
import AppKit
import CoreText

struct HistoricalResidentContent {
    var glyphs: [HistoricalResidentGlyph] = []
    var toolName = ""
    var center = -110.0
    var span = 288.0
}

/// CoreText and CoreGraphics replace Canvas2D while retaining its authored
/// 400 × 310 study-stage placement inside the 640-unit character surface.
@MainActor enum HistoricalResidentPainter {
    private static let bodyPath = MokuGeometry.path(MokuGeometry.buildShape(.circle, layout: .mark), tension: 0.82)
    private static let textFont = NSFont.systemFont(ofSize: 10)
    private static let toolFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    private static let replyFont = NSFont.systemFont(ofSize: 48.57)
    private final class CachedLine {
        let value: CTLine
        init(_ value: CTLine) { self.value = value }
    }
    private static let lines: NSCache<NSString, CachedLine> = {
        let cache = NSCache<NSString, CachedLine>()
        cache.countLimit = 512
        return cache
    }()

    static func measure(_ value: String) -> Double { measure(value, font: textFont) }
    private static func measure(_ value: String, font: NSFont) -> Double {
        CTLineGetTypographicBounds(line(value, font: font), nil, nil, nil)
    }
    private static func line(_ value: String, font: NSFont) -> CTLine {
        let key = "\(font.fontName)\u{0}\(font.pointSize)\u{0}\(value)" as NSString
        if let cached = lines.object(forKey: key) { return cached.value }
        let result = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ]))
        lines.setObject(CachedLine(result), forKey: key)
        return result
    }
    private static func text(_ value: String, context: CGContext, font: NSFont,
                             x: Double, y: Double, centered: Bool = false, middle: Bool = false) {
        let text = line(value, font: font)
        let width = CTLineGetTypographicBounds(text, nil, nil, nil)
        context.saveGState()
        context.translateBy(x: x - (centered ? width / 2 : 0), y: y)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        // Canvas's middle baseline is the midpoint of the font's em box.
        context.textPosition = CGPoint(x: 0, y: middle ? -(font.ascender + font.descender) / 2 : 0)
        CTLineDraw(text, context)
        context.restoreGState()
    }
    private static func color(_ red: Double, _ green: Double, _ blue: Double) -> CGColor {
        NSColor(srgbRed: historicalResidentClamp(red / 255), green: historicalResidentClamp(green / 255),
                blue: historicalResidentClamp(blue / 255), alpha: 1).cgColor
    }
    private static func circle(_ context: CGContext, x: Double, y: Double, radius: Double) {
        context.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
    }

    static func paint(in context: CGContext, pose: HistoricalResidentPose, content: HistoricalResidentContent,
                      blink: Double = 1, body: Bool = true, token: Bool = true, decorationOpacity: Double = 1,
                      material: MokuBodyMaterial? = nil) {
        let p = pose
        context.saveGState()
        context.scaleBy(x: 1 / 0.35, y: 1 / 0.35)
        context.translateBy(x: -88, y: -55)
        context.saveGState()
        context.translateBy(x: 88, y: 55); context.scaleBy(x: 0.35, y: 0.35)
        context.translateBy(x: p["x"], y: p["y"])
        context.translateBy(x: 320, y: 300); context.rotate(by: p["angle"] * .pi / 180)
        context.scaleBy(x: p["sx"], y: p["sy"]); context.translateBy(x: -320, y: -300)
        if body { MokuBodyMaterial.fill(bodyPath, in: context, material: material) }
        context.setFillColor(MokuGeometry.eyeColor.cgColor)
        if body {
            for side in ["l", "r"] {
                context.saveGState()
                context.translateBy(x: p[side + "x"], y: p[side + "y"])
                context.rotate(by: p[side + "a"] * .pi / 180)
                let w = max(1, p[side + "w"]), h = max(2, p[side + "h"] * blink * historicalResidentClamp(p["lid"]))
                context.addPath(CGPath(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h),
                                       cornerWidth: min(w, h) / 2, cornerHeight: min(w, h) / 2, transform: nil))
                context.fillPath(); context.restoreGState()
            }
        }
        context.restoreGState()
        if token && p["dotAlpha"] > 0.001 {
            context.saveGState()
            context.translateBy(x: 88, y: 55); context.scaleBy(x: 0.35, y: 0.35)
            context.translateBy(x: p["x"], y: p["y"])
            context.setAlpha(historicalResidentClamp(p["dotAlpha"]))
            circle(context, x: p["dotX"], y: p["dotY"], radius: max(1, p["dotRadius"]) * (0.8 + historicalResidentClamp(p["dotAlpha"]) * 0.2))
            context.setFillColor(color(p["dotRed"], p["dotGreen"], p["dotBlue"]))
            if p["dotStroke"] > 0.1 {
                context.setStrokeColor(MokuGeometry.eyeColor.cgColor); context.setLineWidth(p["dotStroke"])
                context.drawPath(using: .fillStroke)
            } else { context.fillPath() }
            if p["replyAlpha"] > 0.001 {
                context.setAlpha(historicalResidentClamp(p["dotAlpha"]) * historicalResidentClamp(p["replyAlpha"]))
                context.setFillColor(NSColor.white.cgColor)
                text("1", context: context, font: replyFont, x: p["dotX"] - 1.43, y: p["dotY"] - 2.86, centered: true, middle: true)
            }
            context.restoreGState()
        }
        context.saveGState()
        context.translateBy(x: 88, y: 55); context.scaleBy(x: 0.35, y: 0.35)
        context.translateBy(x: p["x"], y: p["y"])
        for index in 0...2 {
            let key = "d\(index)"
            if p[key + "a"] <= 0.001 { continue }
            context.setAlpha(historicalResidentClamp(p[key + "a"]) * decorationOpacity)
            context.setFillColor(color(p[key + "r"], p[key + "g"], p[key + "b"]))
            circle(context, x: p[key + "x"], y: p[key + "y"], radius: MokuRunningStory.dotRadius * max(0.05, p[key + "s"]))
            context.fillPath()
        }
        context.restoreGState()
        if p["arcAlpha"] > 0.001 {
            context.saveGState()
            let alpha = historicalResidentClamp(p["arcAlpha"]) * 0.7 * decorationOpacity
            context.translateBy(x: p["x"] * 0.35, y: p["y"] * 0.35 + p["arcOffset"])
            for glyph in content.glyphs {
                let group = min(2, Int(floor(glyph.position * 3)))
                let seed = p["arcCenter"] + Double(group - 1) * content.span / 3 * p["arcGroupSpan"]
                let unfolded = content.center + (glyph.position - 0.5) * content.span
                let angle = (unfolded + (seed - unfolded) * historicalResidentClamp(p["arcGather"])) * .pi / 180
                let distance = abs(glyph.position * 3 - Double(group) - 0.5) * 2
                let reveal = historicalResidentClamp((p["arcReveal"] * 1.25 - distance) / 0.25)
                let gather = historicalResidentClamp(p["arcGather"]), grouped = historicalResidentClamp(p["arcGroupSpan"])
                let ink = [113.0, 130, 105].enumerated().map { channel, base in
                    let token = p[["dotRed", "dotGreen", "dotBlue"][channel]]
                    let seed = token + (p["d\(group)" + ["r", "g", "b"][channel]] - token) * grouped
                    return base + (seed - base) * gather * 0.8
                }
                context.saveGState()
                context.translateBy(x: 200 + cos(angle) * p["arcRadius"], y: 160 + sin(angle) * p["arcRadius"])
                context.rotate(by: angle + .pi / 2)
                context.setAlpha(alpha * reveal * (1 - gather * 0.6) * glyph.opacity)
                context.setFillColor(color(ink[0], ink[1], ink[2]))
                text(glyph.value, context: context, font: textFont, x: 0, y: 0, centered: true)
                context.restoreGState()
            }
            context.restoreGState()
        }
        if p["toolAlpha"] > 0.001 {
            context.saveGState()
            context.setAlpha(historicalResidentClamp(p["toolAlpha"]) * decorationOpacity)
            context.translateBy(x: p["x"] * 0.35, y: p["y"] * 0.35 + p["toolOffset"])
            var name = content.toolName
            if measure(name, font: toolFont) > 108 {
                var characters = Array(name)
                while !characters.isEmpty && measure(String(characters) + "…", font: toolFont) > 108 { characters.removeLast() }
                name = String(characters) + "…"
            }
            let nameWidth = measure(name, font: toolFont), opened = historicalResidentClamp(p["toolReveal"])
            context.setFillColor(color(155, 163, 147))
            text("()", context: context, font: toolFont, x: p["toolX"] + (nameWidth + 3) * opened, y: 121)
            context.saveGState()
            context.clip(to: CGRect(x: p["toolX"], y: 108, width: nameWidth * opened, height: 18))
            context.setFillColor(color(120, 129, 115))
            text(name, context: context, font: toolFont, x: p["toolX"], y: 121)
            context.restoreGState(); context.restoreGState()
        }
        context.restoreGState()
    }
}
