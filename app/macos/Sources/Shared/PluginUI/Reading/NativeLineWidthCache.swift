import AppKit
import MokuseiCore

/// A bounded cache of exact native measurements shared by immutable text lines.
/// Font equality includes the descriptor/size; paragraph equality includes tabs.
@MainActor
public final class NativeLineWidthCache {
    private struct Key: Hashable {
        let text: JSONText
        let font: NativePlatformFont
        let paragraph: NSParagraphStyle?
    }
    private var values: [Key: CGFloat] = [:]
    private var order: [(Key, Int)] = []
    private var bytes = 0
    public private(set) var measurementCount = 0
    public init() {}

    public func width(_ text: String, font: NativePlatformFont, paragraph: NSParagraphStyle? = nil) -> CGFloat {
        let key = Key(text: JSONText(text), font: font, paragraph: paragraph?.copy() as? NSParagraphStyle)
        if let value = values[key] { return value }
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if let paragraph { attributes[.paragraphStyle] = paragraph }
        let width = (text as NSString).size(withAttributes: attributes).width
        measurementCount += 1
        let cost = text.utf8.count
        if cost <= 32_768 {
            while order.count >= 2048 || bytes + cost > 512 * 1024 {
                let removed = order.removeFirst(); values[removed.0] = nil; bytes -= removed.1
            }
            values[key] = width; order.append((key, cost)); bytes += cost
        }
        return width
    }
}
