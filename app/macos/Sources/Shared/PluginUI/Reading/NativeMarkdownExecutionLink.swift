import AppKit
import MokuseiCore
import MokuseiPluginAPI
import SwiftUI

extension NSAttributedString.Key {
    static let nativeMarkdownExecution = NSAttributedString.Key("MokuseiMarkdownExecution")
}

/// TextKit owns the inline seat, wrapping and source selection. The live native
/// surface occupies that seat without replacing the document's text layout.
final class MarkdownExecutionAttachment: NSTextAttachment {
    let title: String
    let url: URL
    let harness: AnyHarnessPlugin?
    let fontSize: CGFloat
    let size: CGSize

    @MainActor init(title: String, url: URL, harness: AnyHarnessPlugin?, fontSize: CGFloat, width: CGFloat) {
        self.title = title; self.url = url; self.harness = harness; self.fontSize = fontSize
        let font = NativeTypography.interPlatformFont(size: fontSize)
        let scale = fontSize / 13
        let chrome = 57 * scale
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3 * scale
        let text = NSAttributedString(string: title, attributes: [.font: font, .paragraphStyle: paragraph])
        let fittedWidth = min(width, ceil(text.size().width) + chrome)
        let height = text.boundingRect(with: CGSize(width: max(1, fittedWidth - chrome), height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        size = CGSize(width: max(1, fittedWidth), height: ceil(max(fontSize * 1.2, height) + 14 * scale))
        super.init(data: nil, ofType: nil)
        let cell = MarkdownExecutionCell(size: size, baseline: font.descender - 7 * scale)
        cell.setAccessibilityElement(false)
        attachmentCell = cell
    }

    required init?(coder: NSCoder) { nil }
}

private final class MarkdownExecutionCell: NSTextAttachmentCell {
    let size: CGSize
    let baseline: CGFloat
    init(size: CGSize, baseline: CGFloat) {
        self.size = size; self.baseline = baseline
        super.init(textCell: "")
    }
    required init(coder: NSCoder) { fatalError("Execution cells are document-owned") }
    override func cellSize() -> NSSize { size }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: baseline) }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {}
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int) {}
}

private struct MarkdownExecutionCapsule: View {
    let attachment: MarkdownExecutionAttachment
    let selected: Bool
    let open: () -> Void
    @Environment(\.locale) private var locale
    private var scale: CGFloat { attachment.fontSize / 13 }
    private var name: String {
        attachment.harness?.descriptor.displayName.string
            ?? (locale.language.languageCode?.identifier == "zh" ? "执行记录" : "Execution")
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6 * scale) {
                Group {
                    if let harness = attachment.harness { harness.logo(size: 15 * scale) }
                    else { Image(systemName: "terminal").resizable().scaledToFit().foregroundStyle(NativePalette.thread.muted.swiftUI) }
                }.frame(width: 15 * scale, height: 15 * scale).accessibilityHidden(true)
                Text(attachment.title).font(NativeTypography.inter(size: attachment.fontSize))
                    .foregroundStyle(NativePalette.thread.inkStrong.swiftUI)
                    .lineSpacing(3 * scale).fixedSize(horizontal: false, vertical: true)
                Image(systemName: "arrow.up.right").font(.system(size: 10 * scale, weight: .medium))
                    .foregroundStyle(NativePalette.thread.muted.swiftUI).accessibilityHidden(true)
            }
            .padding(.horizontal, 10 * scale).padding(.vertical, 7 * scale)
            .frame(width: attachment.size.width, height: attachment.size.height)
            .contentShape(RoundedRectangle(cornerRadius: 15 * scale))
        }
        .buttonStyle(.plain)
        // A is deliberately stable under the pointer: no interactive glass,
        // hover scale or replacement of the user's selection by hover state.
        .glassEffect(.clear, in: .rect(cornerRadius: 15 * scale))
        .overlay {
            if selected { RoundedRectangle(cornerRadius: 15 * scale).strokeBorder(NativePalette.thread.accent.swiftUI, lineWidth: 1) }
        }
        .help("\(name) · \(attachment.title)")
        .accessibilityLabel("\(name) · \(attachment.title)")
        .accessibilityIdentifier("moku-note-execution-link")
    }
}

/// Pointer events stay with TextKit, including drag selection beginning on a
/// capsule. The hosted Button remains keyboard/AX activatable independently.
final class MarkdownExecutionHost: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        sizingOptions = []; safeAreaRegions = []
    }
    required init?(coder: NSCoder) { nil }

    func update(_ attachment: MarkdownExecutionAttachment, selected: Bool, locale: Locale, dark: Bool, open: @escaping () -> Void) {
        rootView = AnyView(MarkdownExecutionCapsule(attachment: attachment, selected: selected, open: open)
            .environment(\.locale, locale).environment(\.colorScheme, dark ? .dark : .light))
    }
}

extension MarkdownTextView {
    func updateExecutionSurfaces() {
        guard let storage = textStorage, let layout = layoutManager, let container = textContainer else { return }
        var retained = Set<Int>()
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? MarkdownExecutionAttachment else { return }
            let index = range.location
            retained.insert(index)
            let host = executionSurfaces[index] ?? MarkdownExecutionHost(rootView: AnyView(EmptyView()))
            if host.superview == nil { addSubview(host); executionSurfaces[index] = host }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += textContainerOrigin.x; rect.origin.y += textContainerOrigin.y
            host.frame = CGRect(origin: rect.origin, size: attachment.size)
            host.update(attachment, selected: NSIntersectionRange(selectedRange(), range).length > 0, locale: executionLocale,
                        dark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua) { [weak self] in
                guard let self else { return }
                _ = self.delegate?.textView?(self, clickedOnLink: attachment.url, at: index)
            }
        }
        for index in executionSurfaces.keys where !retained.contains(index) {
            executionSurfaces.removeValue(forKey: index)?.removeFromSuperview()
        }
    }
}
