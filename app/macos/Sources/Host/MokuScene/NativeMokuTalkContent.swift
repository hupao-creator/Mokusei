import AppKit
import CoreText
import MokuseiPluginUI
import SwiftUI

@MainActor enum NativeMokuTalkTypography {
    static let lineSpacing: CGFloat = 3
    static let verticalPadding: CGFloat = 19
    static let leading: CGFloat = 18
    static let trailing: CGFloat = 20
    static let lineHeight: CGFloat = 16
    static var maximumHeight: CGFloat { lineHeight * 4 + lineSpacing * 3 }
    /// Talk stays inside a four-line notification viewport. Live dictation has no
    /// equivalent length bound, so it may grow to twice that before the same
    /// internal scroller takes over; a normal sentence never shows only its tail.
    static var transcriptMaximumHeight: CGFloat { lineHeight * 8 + lineSpacing * 7 }
    static func height(_ text: String, width: CGFloat) -> CGFloat {
        // Match the rendered weight so Latin wrapping and the viewport agree.
        let font = NativePlatformFont.systemFont(ofSize: 13, weight: .medium)
        var spacing = lineSpacing
        let paragraph = withUnsafePointer(to: &spacing) { pointer in
            var setting = CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: pointer)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let value = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph])
        let framesetter = CTFramesetterCreateWithAttributedString(value)
        return ceil(CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: max(1, width), height: .greatestFiniteMagnitude), nil).height)
    }
    static func scrollbarGutter(for style: NSScroller.Style) -> CGFloat {
        style == .legacy ? NSScroller.scrollerWidth(for: .mini, scrollerStyle: style) : 0
    }
    static func capsuleHeight(_ text: String, width: CGFloat, trailingInset: CGFloat? = nil,
                              maximumHeight: CGFloat = NativeMokuTalkTypography.maximumHeight,
                              scrollbarStyle: NSScroller.Style = NSScroller.preferredScrollerStyle) -> CGFloat {
        max(58, min(maximumHeight, height(text, width: width - leading - (trailingInset ?? trailing) - scrollbarGutter(for: scrollbarStyle))) + verticalPadding * 2)
    }
}
struct NativeMokuTalkContent: View {
    let message: NativeMokuTalkMessage
    var scrollbarStyle: NSScroller.Style = NSScroller.preferredScrollerStyle
    @State private var followsTail = true
    var body: some View {
        GeometryReader { viewport in
            NativeScrollView {
                // Pin the text to its natural height before the viewport clips it.
                // Otherwise a shorter proposal can truncate wrapped transcript text
                // instead of letting the scroller reveal it.
                Text(message.text).font(.system(size: 13, weight: .medium))
                    .lineSpacing(3).multilineTextAlignment(.center).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    // AppKit reserves a persistent gutter after SwiftUI has proposed
                    // the full scroll width. Constrain prose to the actual clip width;
                    // the flexible outer frame prevents it centering under that
                    // gutter without forcing the native viewport to grow for it.
                    .frame(maxWidth: max(1, viewport.size.width - NativeMokuTalkTypography.scrollbarGutter(for: scrollbarStyle)))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
            .defaultScrollAnchor(.bottom)
            // Short messages share the row center; overflow still follows its tail.
            .defaultScrollAnchor(.center, for: .alignment)
            .defaultScrollAnchor(followsTail ? .bottom : .top, for: .sizeChanges)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 1
            } action: { _, atBottom in followsTail = atBottom }
            .accessibilityIdentifier("moku-talk-content")
        }
    }
}
