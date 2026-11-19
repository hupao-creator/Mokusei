import SwiftUI

/// Keep a long reply scrollable without constructing every TextKit view on
/// entry. Once admitted, a section keeps its measured layout and selection for
/// this visit. Scrolling back cannot turn it into an estimate again.
struct MarkdownReadingSections: View {
    static let blocksPerSection = 12
    let blocks: [MarkdownBlock]
    let options: MarkdownViewOptions
    @State private var readingWidth: CGFloat?

    var body: some View {
        let count = (blocks.count + Self.blocksPerSection - 1) / Self.blocksPerSection
        NativeMarkdownColumn {
            ForEach(0..<count, id: \.self) { section in
                let start = section * Self.blocksPerSection
                let end = min(start + Self.blocksPerSection, blocks.count)
                let content = MarkdownContent(blocks: Array(blocks[start..<end]), options: options,
                    precedingBlock: start == 0 ? nil : blocks[start - 1], isFinal: end == blocks.count)
                if start == 0 {
                    content
                } else if let readingWidth {
                    DeferredMarkdownSection(content: content, width: readingWidth)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if width > 0 { readingWidth = width }
        }
    }
}

private struct DeferredMarkdownSection: View {
    let content: MarkdownContent
    let width: CGFloat
    @State private var admitted = false

    var body: some View {
        if admitted {
            content
        } else {
            Color.clear
                .frame(height: NativeStreamingPageMetrics.estimatedHeight(of: content.blocks, width: width,
                    fontSize: content.options.fontSize, precedingBlock: content.precedingBlock, isFinal: content.isFinal))
                .accessibilityHidden(true)
                .onGeometryChange(for: Bool.self) { geometry in
                    guard let viewport = geometry.bounds(of: .scrollView(axis: .vertical)) else { return true }
                    let nearby = viewport.insetBy(dx: 0, dy: -viewport.height)
                    return nearby.intersects(CGRect(origin: .zero, size: geometry.size))
                } action: { nearby in
                    if nearby { admitted = true }
                }
        }
    }
}
