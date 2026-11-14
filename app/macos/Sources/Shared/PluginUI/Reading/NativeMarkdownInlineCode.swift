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
    nonisolated static let horizontalWidth: CGFloat = 5
    override func cellSize() -> NSSize { NSSize(width: Self.horizontalWidth, height: 1) }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {}
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int) {}
}


@MainActor
func markdownCodePadding(attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
    let attachment = NSTextAttachment()
    let cell = MarkdownCodePaddingCell()
    cell.setAccessibilityElement(false)
    attachment.attachmentCell = cell
    attachment.bounds = CGRect(x: 0, y: 0, width: MarkdownCodePaddingCell.horizontalWidth, height: 1)
    let value = NSMutableAttributedString(attachment: attachment)
    var attributes = attributes
    attributes.removeValue(forKey: .link)
    attributes.removeValue(forKey: .strikethroughStyle)
    attributes[.nativeMarkdownPadding] = true
    attributes[.init("NSAccessibilityDescription")] = ""
    value.addAttributes(attributes, range: NSRange(location: 0, length: value.length))
    return value
}

final class MarkdownCodeLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldBreakLineByWordBeforeCharacterAt charIndex: Int) -> Bool {
        guard let storage = textStorage, charIndex > 0, charIndex < storage.length else { return true }
        // Attachment boundaries are otherwise valid word breaks. Keep each
        // padding cell with its code edge, while retaining native word/character
        // wrapping inside long code and the original selectable characters.
        let beforeIsPadding = storage.attribute(.nativeMarkdownPadding, at: charIndex - 1, effectiveRange: nil) as? Bool == true
        let afterIsPadding = storage.attribute(.nativeMarkdownPadding, at: charIndex, effectiveRange: nil) as? Bool == true
        if beforeIsPadding, !afterIsPadding, storage.attribute(.nativeMarkdownCode, at: charIndex, effectiveRange: nil) as? Bool == true { return false }
        if afterIsPadding, !beforeIsPadding, storage.attribute(.nativeMarkdownCode, at: charIndex - 1, effectiveRange: nil) as? Bool == true { return false }
        return true
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard let storage = textStorage, let container = textContainers.first else {
            super.drawBackground(forGlyphRange: glyphsToShow, at: origin); return
        }
        enumerateLineFragments(forGlyphRange: glyphsToShow) { line, _, _, lineGlyphs, _ in
            let characters = self.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
            storage.enumerateAttribute(.nativeMarkdownCode, in: characters) { value, range, _ in
                guard value as? Bool == true,
                      let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NativePlatformFont else { return }
                var hasCode = false
                storage.enumerateAttribute(.nativeMarkdownPadding, in: range) { padding, _, stop in
                    if padding as? Bool != true { hasCode = true; stop.pointee = true }
                }
                // Extremely narrow containers can force even a padding cell
                // onto its own line; that cell must never paint an empty chip.
                guard hasCode else { return }
                let glyphs = NSIntersectionRange(lineGlyphs, self.glyphRange(forCharacterRange: range, actualCharacterRange: nil))
                let glyph = glyphs.location
                // Selection rects preserve disjoint bidi segments, but extend
                // to the container edge at soft wraps and can merge whole lines.
                // Limit them to this line's actual code bounds.
                let bounds = self.boundingRect(forGlyphRange: glyphs, in: container)
                let baseline = line.minY + self.location(forGlyphAt: glyph).y
                self.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { enclosing, _ in
                    let rect = enclosing.intersection(bounds)
                    guard !rect.isEmpty else { return }
                    let box = CGRect(x: rect.minX + origin.x, y: baseline - font.ascender - 2 + origin.y,
                                     width: rect.width, height: font.ascender - font.descender + 4)
                    NativePlatformPalette.thread.surface.setFill()
                    NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
                }
            }
        }
        // Let native selection backgrounds paint over the code's normal fill.
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

extension MarkdownTextView {
    func copyMarkdownSelection() -> Bool {
        guard let storage = markdownStorage else { return false }
        let selection = markdownSelectedRange
        guard selection.length > 0, NSMaxRange(selection) <= storage.length else { return false }
        let selected = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: selection))
        var padding: [NSRange] = []
        selected.enumerateAttribute(.nativeMarkdownPadding, in: NSRange(location: 0, length: selected.length)) { value, range, _ in
            if value as? Bool == true { padding.append(range) }
        }
        for range in padding.reversed() { selected.deleteCharacters(in: range) }
        let copied = MarkdownPlatformActions.copy(selected.markdownPlainText())
        if let rich = try? selected.data(from: NSRange(location: 0, length: selected.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            NSPasteboard.general.setData(rich, forType: .rtf)
        }
        return copied
    }
}
