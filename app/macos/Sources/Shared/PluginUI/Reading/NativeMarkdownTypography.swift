import AppKit

/// The existing Markdown CSS's SFMono/Consolas/Liberation Mono fallback resolves
/// to Menlo on macOS. This deliberately differs from the shared JetBrains font
/// used for authors and timestamps. Verified with CSS.getPlatformFontsForNode in
/// the current Electron renderer using its real styles and bundled font faces.
enum NativeMarkdownTypography {
    static let fenceSize: CGFloat = 12 * 0.88
    static let fenceLineHeight: CGFloat = 12 * 1.7

    static func code(size: CGFloat, weight: CGFloat = 400, italic: Bool = false) -> NativePlatformFont {
        let suffix = weight >= 600 ? (italic ? "BoldItalic" : "Bold") : (italic ? "Italic" : "Regular")
        return NativePlatformFont(name: "Menlo-" + suffix, size: size)
            ?? NativePlatformFont.monospacedSystemFont(ofSize: size, weight: weight >= 600 ? .bold : .regular)
    }
}

/// Fences are re-evaluated while neighboring text streams. Measuring every line
/// again is unnecessary; retain a bounded set of complete-source measurements.
@MainActor
enum NativeMarkdownCodeMetrics {
    private static let lineWidths = NativeLineWidthCache()
    private static var cache: [String: CGFloat] = [:]
    private static var order: [(source: String, bytes: Int)] = []
    private static var bytes = 0
    private static let budget = 512 * 1024

    static func width(of source: String) -> CGFloat {
        if let width = cache[source] { return width }
        let font = NativeMarkdownTypography.code(size: NativeMarkdownTypography.fenceSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: font]).width * 8
        var maximum: CGFloat = 0
        for line in source.components(separatedBy: .newlines) {
            maximum = max(maximum, lineWidths.width(line, font: font, paragraph: paragraph))
        }
        let width = ceil(maximum) + 1
        let cost = source.utf8.count
        if cost <= budget {
            while order.count >= 128 || bytes + cost > budget {
                let oldest = order.removeFirst()
                cache[oldest.source] = nil; bytes -= oldest.bytes
            }
            cache[source] = width; order.append((source, cost)); bytes += cost
        }
        return width
    }
}

/// Cell metrics repeat across streaming revisions; bound both retained entries
/// and their source text so a growing table only measures its changed cells.
@MainActor
enum NativeMarkdownCellMetrics {
    struct Metrics { let natural: CGFloat; let minimum: CGFloat }
    private struct Key: Hashable { let spans: [MarkdownSpan]; let weight: CGFloat }
    private static var cache: [Key: Metrics] = [:]
    private static var order: [Key] = []
    private static var retainedCharacters = 0

    private static func cost(_ spans: [MarkdownSpan]) -> Int {
        spans.reduce(0) { $0 + $1.text.utf8.count + ($1.link?.utf8.count ?? 0) + ($1.image?.utf8.count ?? 0) + ($1.title?.utf8.count ?? 0) + ($1.anchor?.utf8.count ?? 0) }
    }

    static func measure(_ spans: [MarkdownSpan], weight: CGFloat) -> Metrics {
        let key = Key(spans: spans, weight: weight)
        if let result = cache[key] { return result }
        let text = NSMutableAttributedString(string: "")
        var minimum: CGFloat = 0
        for span in spans {
            let font = span.code ? NativeMarkdownTypography.code(size: 12 * 0.88, weight: span.strong ? 700 : weight, italic: span.emphasis)
                : NativeTypography.interPlatformFont(size: 12, weight: span.strong ? 700 : weight)
            text.append(NSAttributedString(string: span.text, attributes: [.font: font]))
            for character in Set(span.text) where !character.isNewline {
                minimum = max(minimum, (String(character) as NSString).size(withAttributes: [.font: font]).width)
            }
        }
        let padding = CGFloat(spans.filter(\.code).count) * MarkdownCodePaddingCell.horizontalWidth * 2
        let result = Metrics(natural: ceil(text.size().width + padding) + 23, minimum: ceil(minimum) + 23)
        let count = cost(spans)
        if count <= 32_768 {
            while order.count >= 1024 || retainedCharacters + count > 512 * 1024 {
                let removed = order.removeFirst()
                retainedCharacters -= cost(removed.spans)
                cache.removeValue(forKey: removed)
            }
            cache[key] = result; order.append(key); retainedCharacters += count
        }
        return result
    }
}
