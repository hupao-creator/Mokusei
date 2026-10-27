import AppKit

extension NSAttributedString.Key {
    static let nativeMarkdownCode = NSAttributedString.Key("MokuseiMarkdownInlineCode")
    static let nativeMarkdownPadding = NSAttributedString.Key("MokuseiMarkdownCodePadding")
}

/// Inline code's CSS uses real horizontal padding, a three-point radius and a
/// background sized to the code font, independently from the prose line height.
/// Zero-drawing spacing cells reserve that padding without making code atomic:
/// every code character remains native selectable text.
final class MarkdownCodePaddingCell: NSTextAttachmentCell {
    override func cellSize() -> NSSize { NSSize(width: 5, height: 1) }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {}
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int) {}
}


@MainActor
func markdownCodePadding(attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
    let attachment = NSTextAttachment()
    let cell = MarkdownCodePaddingCell()
    cell.setAccessibilityElement(false)
    attachment.attachmentCell = cell
    attachment.bounds = CGRect(x: 0, y: 0, width: 5, height: 1)
    let value = NSMutableAttributedString(attachment: attachment)
    var attributes = attributes
    attributes.removeValue(forKey: .link)
    attributes.removeValue(forKey: .strikethroughStyle)
    attributes[.nativeMarkdownPadding] = true
    attributes[.init("NSAccessibilityDescription")] = ""
    value.addAttributes(attributes, range: NSRange(location: 0, length: value.length))
    return value
}

final class MarkdownCodeLayoutManager: MarkdownSelectionLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard let storage = textStorage, let container = textContainers.first else {
            super.drawBackground(forGlyphRange: glyphsToShow, at: origin); return
        }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.nativeMarkdownCode, in: characters) { value, range, _ in
            guard value as? Bool == true,
                  let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NativePlatformFont else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                let glyph = self.glyphIndex(for: CGPoint(x: rect.minX, y: rect.midY), in: container)
                guard glyph < self.numberOfGlyphs else { return }
                let line = self.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let baseline = line.minY + self.location(forGlyphAt: glyph).y
                let box = CGRect(x: rect.minX + origin.x, y: baseline - font.ascender - 2 + origin.y,
                                 width: rect.width, height: font.ascender - font.descender + 4)
                NativePlatformPalette.thread.surface.setFill()
                NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
            }
        }
        // Let native selection backgrounds paint over the code's normal fill.
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

extension MarkdownTextView {
    func copyWithoutCodePadding() -> Bool {
        guard let storage = markdownStorage else { return false }
        let selection = markdownSelectedRange
        guard selection.length > 0, NSMaxRange(selection) <= storage.length else { return false }
        let selected = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: selection))
        var padding: [NSRange] = []
        selected.enumerateAttribute(.nativeMarkdownPadding, in: NSRange(location: 0, length: selected.length)) { value, range, _ in
            if value as? Bool == true { padding.append(range) }
        }
        guard !padding.isEmpty else { return false }
        for range in padding.reversed() { selected.deleteCharacters(in: range) }
        let copied = MarkdownPlatformActions.copy(selected.markdownPlainText())
        if let rich = try? selected.data(from: NSRange(location: 0, length: selected.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            NSPasteboard.general.setData(rich, forType: .rtf)
        }
        return copied
    }
}
