import AppKit
import SwiftUI

/// A fence keeps its source lines intact. Own the native document geometry as
/// well as the viewport so the clipped tail has a real horizontal scroll range.
struct MarkdownCodeViewport: NSViewRepresentable {
    let source: String
    private let sourceBytes: Data
    let scrollerStyle: NSScroller.Style

    init(source: String, scrollerStyle: NSScroller.Style) {
        self.source = source; self.sourceBytes = Data(source.utf8)
        self.scrollerStyle = scrollerStyle
    }

    func makeNSView(context: Context) -> MarkdownCodeScrollView { MarkdownCodeScrollView() }

    func updateNSView(_ view: MarkdownCodeScrollView, context: Context) { view.setSource(source) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkdownCodeScrollView, context: Context) -> CGSize? {
        let gutter = scrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .mini, scrollerStyle: scrollerStyle) : 0
        return CGSize(width: max(1, proposal.width ?? NativeGeometry.readingWidth),
                      height: nsView.codeSize.height + gutter)
    }
}

final class MarkdownCodeScrollView: NativeStyledScrollView {
    private final class Document: NSView { override var isFlipped: Bool { true } }
    private let codeDocument = Document()
    private let codeText: MarkdownTextView
    private(set) var codeSize = CGSize.zero

    init() {
        codeText = MarkdownSelectableText(spans: [], fontSize: NativeMarkdownTypography.fenceSize,
                                          code: true, openLink: { _, _ in }).makeTextView()
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = true
        hasVerticalScroller = false
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        codeDocument.addSubview(codeText)
        documentView = codeDocument
        NativeScrollbarStyle.apply(to: self)
    }

    required init?(coder: NSCoder) { nil }

    override func scrollWheel(with event: NSEvent) {
        // The fence owns horizontal input, including Shift-wheel. Ordinary
        // vertical scrolling must still reach the enclosing reading viewport.
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), !event.modifierFlags.contains(.shift) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    func setSource(_ source: String) {
        let text = source.hasSuffix("\n") ? String(source.dropLast()) : source
        MarkdownSelectableText(spans: [MarkdownSpan(text: text)],
            fontSize: NativeMarkdownTypography.fenceSize,
            lineHeight: NativeMarkdownTypography.fenceLineHeight, code: true,
            openLink: { _, _ in }).updateTextView(codeText)
        let width = max(1, NativeMarkdownCodeMetrics.width(of: source))
        let height = codeText.measuredHeight(width: width)
        codeText.frame = CGRect(x: 16, y: 16, width: width, height: height)
        codeSize = CGSize(width: width + 32, height: height + 32)
        codeDocument.setFrameSize(codeSize)
        // Source changes can shrink the document while retaining a previous
        // right-edge selection/offset. Clamp through AppKit's own clip policy.
        contentView.scroll(to: contentView.constrainBoundsRect(contentView.bounds).origin)
        reflectScrolledClipView(contentView)
    }
}
