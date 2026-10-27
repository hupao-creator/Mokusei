import CoreText
import MokuseiPluginUI
import SwiftUI

@MainActor enum NativeMokuTalkTypography {
    static let lineSpacing: CGFloat = 3
    static let verticalPadding: CGFloat = 19
    static let leading: CGFloat = 64
    static let trailing: CGFloat = 20
    static let lineHeight: CGFloat = 16
    static var maximumHeight: CGFloat { lineHeight * 4 + lineSpacing * 3 }
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
    static func capsuleHeight(_ text: String, width: CGFloat, trailingInset: CGFloat? = nil) -> CGFloat {
        max(58, min(maximumHeight, height(text, width: width - leading - (trailingInset ?? trailing))) + verticalPadding * 2)
    }
}
struct NativeMokuTalkContent: View {
    let message: NativeMokuTalkMessage
    @State private var followsTail = true
    var body: some View {
        ScrollView {
            Text(message.text).font(.system(size: 13, weight: .medium))
                .lineSpacing(3).multilineTextAlignment(.center).textSelection(.enabled)
                .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom)
        // Short messages share the eyes' center; overflow still follows its tail.
        .defaultScrollAnchor(.center, for: .alignment)
        .defaultScrollAnchor(followsTail ? .bottom : .top, for: .sizeChanges)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 1
        } action: { _, atBottom in followsTail = atBottom }
        .accessibilityIdentifier("moku-talk-content")
    }
}
