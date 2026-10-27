import Foundation

/// Matches layoutSvgMessage's code-point budget, including its CJK widths and
/// ellipsis. TextKit's automatic wrapping would choose different breakpoints.
public enum MokuMessageLayout {
    public static func lines(_ message: String, lineWidth: Double = 22.3, lineCount: Int = 3) -> [String] {
        let normalized = message.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let glyphs = normalized.unicodeScalars.map(String.init)
        var lines: [String] = [], cursor = 0
        while cursor < glyphs.count && lines.count < lineCount {
            while cursor < glyphs.count && glyphs[cursor] == " " { cursor += 1 }
            let start = cursor
            var width = 0.0, lastSpaceWidth = 0.0, lastSpace = -1
            while cursor < glyphs.count {
                let glyph = glyphs[cursor], nextWidth = width + glyphWidth(glyph)
                if nextWidth > lineWidth && cursor > start { break }
                width = nextWidth
                if glyph == " " { lastSpace = cursor; lastSpaceWidth = width }
                cursor += 1
            }
            var end = cursor
            if cursor < glyphs.count && lastSpace > start && lastSpaceWidth >= lineWidth * 0.65 {
                end = lastSpace; cursor = lastSpace + 1
            }
            lines.append(glyphs[start..<end].joined().trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if cursor < glyphs.count && !lines.isEmpty {
            var final = lines.removeLast()
            while !final.isEmpty && textWidth(final + "…") > lineWidth {
                final = String(String.UnicodeScalarView(final.unicodeScalars.dropLast())).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            lines.append(final + "…")
        }
        return lines.isEmpty ? [""] : lines
    }
    public static func textWidth(_ value: String) -> Double { value.unicodeScalars.reduce(0) { $0 + glyphWidth(String($1)) } }
    private static func glyphWidth(_ glyph: String) -> Double {
        guard let scalar = glyph.unicodeScalars.first else { return 0 }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return 0.38 }
        let value = scalar.value
        if (0x2e80...0x9fff).contains(value) || (0xf900...0xfaff).contains(value) { return 1 }
        if (65...90).contains(value) { return 0.62 }
        if (97...122).contains(value) || (48...57).contains(value) { return 0.52 }
        if ".,'\"`·，。、“”‘’：；！？!?()[]{}".contains(glyph) { return 0.42 }
        return 0.72
    }
}
