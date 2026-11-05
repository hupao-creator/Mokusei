import AppKit
import MokuseiCore
import MokuseiPluginAPI
import SwiftUI

extension EnvironmentValues {
    @Entry var nativeMarkdownUsesSwiftUIText = false
}

/// Agent readers use SwiftUI text; other consumers retain their existing native
/// selection and attachment contracts (in particular the Moku note capsules).
struct MarkdownReadingText: View {
    let spans: [MarkdownSpan]
    let fontSize: CGFloat
    var weight: CGFloat = 400
    var muted = false
    var strongInk = false
    var tracking: CGFloat = 0
    var lineHeight: CGFloat? = nil
    var alignment: MarkdownAlignment = .left
    var code = false
    var images: [String: NativePlatformImage] = [:]
    var selectionScope: String? = nil
    var executionLinkHarnesses: [JSONText: AnyHarnessPlugin]? = nil
    var openLink: (URL) -> Void
    @Environment(\.nativeMarkdownUsesSwiftUIText) private var agentDetail
    @Environment(\.nativeThreadReveal) private var reveal
    @State private var navigation = MarkdownSwiftUINavigation()

    var body: some View {
        if agentDetail {
            if reveal != nil {
                // Reuse the existing first-paint gate without changing the
                // animation owner. SwiftUI contributes a block, not glyph lines.
                NativeThreadRevealRow(contentID: spans.map(\.text).joined()) { swiftUIText }
            } else {
                swiftUIText
            }
        } else {
            MarkdownSelectableText(spans: spans, fontSize: fontSize, weight: weight,
                muted: muted, strongInk: strongInk, tracking: tracking, lineHeight: lineHeight,
                alignment: alignment, code: code, images: images, selectionScope: selectionScope,
                executionLinkHarnesses: executionLinkHarnesses, openLink: openLink)
        }
    }

    private var swiftUIText: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                if let span = part.first, let source = span.image, let image = images[source] {
                    if let url = MarkdownURLPolicy.url(span.link) {
                        Button { openLink(url) } label: { preview(image, label: span.text) }
                            .buttonStyle(.plain)
                    } else {
                        preview(image, label: span.text)
                    }
                } else {
                    Text(part.reduce(into: AttributedString()) { $0.append(attributedSpan($1)) })
                        .textSelection(.enabled)
                        .lineLimit(nil)
                        .lineSpacing(extraLineSpacing)
                        // SwiftUI applies lineSpacing only between lines. Keep
                        // first/last-line leading too, including list markers.
                        .padding(.vertical, extraLineSpacing / 2)
                        .multilineTextAlignment(alignment == .center ? .center : alignment == .right ? .trailing : .leading)
                        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : alignment == .right ? .trailing : .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
            .tint(NativePlatformPalette.thread.accent.swiftUI)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == nil, let fragment = url.fragment {
                    navigation.reveal(fragment.removingPercentEncoding ?? fragment)
                } else { openLink(url) }
                return .handled
            })
            .background(MarkdownSwiftUIAnchor(anchors: spans.compactMap(\.anchor), navigation: navigation))
            .help(spans.compactMap(\.title).joined(separator: "\n"))
    }

    private func preview(_ image: NSImage, label: String) -> some View {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            .frame(maxWidth: image.size.width, maxHeight: min(480, image.size.height), alignment: .leading)
            .accessibilityLabel(label)
    }

    // Keep all adjacent styled text in one selectable Text. Images use actual
    // accessible SwiftUI controls rather than unlinked Text image interpolation.
    private var parts: [[MarkdownSpan]] {
        var result: [[MarkdownSpan]] = []
        var text: [MarkdownSpan] = []
        for span in spans {
            if let source = span.image, images[source] != nil {
                if !text.isEmpty { result.append(text); text = [] }
                result.append([span])
            } else { text.append(span) }
        }
        if !text.isEmpty { result.append(text) }
        return result
    }

    private var extraLineSpacing: CGFloat {
        max(0, (lineHeight ?? fontSize * (code ? 1.7 : 1.8)) - fontSize * 1.2)
    }

    private func attributedSpan(_ span: MarkdownSpan) -> AttributedString {
        // Brackets keep the visible footnote target wide enough for SwiftUI's
        // selectable-text link hit region; a lone small digit misses activation.
        var value = AttributedString(span.superscript ? "[\(span.text)]" : span.text)
        let size = span.superscript ? fontSize * 0.72 : span.code ? fontSize * 0.88 : fontSize
        let font = code || span.code
            ? NativeMarkdownTypography.code(size: size, weight: span.strong ? 700 : weight, italic: span.emphasis)
            : NativeTypography.interPlatformFont(size: size, weight: span.strong ? 700 : weight)
        value.font = Font(font)
        value.foregroundColor = (muted ? NativePlatformPalette.thread.muted : strongInk ? NativePlatformPalette.thread.inkStrong : NativePlatformPalette.thread.ink).swiftUI
        value.kern = tracking
        if span.strikethrough { value.strikethroughStyle = .single }
        if span.superscript { value.baselineOffset = fontSize * 0.35 }

        if span.code { value.backgroundColor = NativePlatformPalette.thread.surface.swiftUI }
        if let url = MarkdownURLPolicy.url(span.link) {
            value.link = url
            value.foregroundColor = NativePlatformPalette.thread.accent.swiftUI
            value.underlineStyle = .single
        }
        return value
    }
}

/// Passive navigation geometry only: no text storage, layout manager, selection
/// tracking or private SwiftUI view introspection. References target their block.
@MainActor
private final class MarkdownSwiftUINavigation {
    weak var view: NSView?

    func reveal(_ fragment: String) {
        guard let root = view?.window?.contentView else { return }
        func find(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == fragment || (view as? MarkdownSwiftUIAnchor.View)?.anchors.contains(fragment) == true { return view }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let target = find(root) else { return }
        var ancestor = target.superview
        while let view = ancestor {
            if let scroll = view as? NSScrollView, let document = scroll.documentView {
                document.scrollToVisible(document.convert(target.bounds, from: target))
            }
            ancestor = view.superview
        }
    }
}

private struct MarkdownSwiftUIAnchor: NSViewRepresentable {
    let anchors: [String]
    let navigation: MarkdownSwiftUINavigation
    final class View: NSView {
        var anchors: [String] = []
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ view: View, context: Context) {
        view.anchors = anchors
        navigation.view = view
    }
}

/// Copy actions operate on parsed content, independently of SwiftUI's private
/// selection. Tabs preserve empty table cells; no Markdown delimiters leak out.
enum MarkdownReadingCopy {
    static func table(_ rows: [[[MarkdownSpan]]]) -> String {
        rows.map { $0.map { $0.map(\.text).joined() }.joined(separator: "\t") }.joined(separator: "\n")
    }

}
