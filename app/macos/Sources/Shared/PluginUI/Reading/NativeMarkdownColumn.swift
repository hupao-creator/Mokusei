import SwiftUI

/// Document blocks flow at the reading column's width; they do not negotiate
/// vertical flexibility. Nested VStacks otherwise multiply native text probes.
struct NativeMarkdownColumn: Layout {
    var spacing: CGFloat = 0

    struct Measurement {
        let width: CGFloat
        let sizes: [CGSize]
        let height: CGFloat
    }
    struct Cache { var measurements: [Measurement] = [] }

    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? NativeGeometry.readingWidth
        let measured = measure(width: width, subviews: subviews, cache: &cache)
        return CGSize(width: width, height: measured.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let measured = measure(width: bounds.width, subviews: subviews, cache: &cache)
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: measured.sizes[index].height))
            y += measured.sizes[index].height + spacing
        }
    }

    private func measure(width: CGFloat, subviews: Subviews, cache: inout Cache) -> Measurement {
        if let measured = cache.measurements.first(where: { $0.width == width }) { return measured }
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
        let measured = Measurement(width: width, sizes: sizes,
            height: sizes.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, sizes.count - 1)))
        // Keep only the few proposals in this layout pass. SwiftUI invalidates
        // this cache on layout/subview changes, including new text and images.
        if cache.measurements.count == 4 { cache.measurements.removeFirst() }
        cache.measurements.append(measured)
        return measured
    }
}

/// A list marker or quote rule owns a fixed leading slot. HStack's flexibility
/// probes otherwise lay out the entire trailing paragraph at a one-point width.
struct NativeMarkdownLeadingColumn: Layout {
    let leadingWidth: CGFloat
    var spacing: CGFloat = 0
    var stretchesLeading = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? NativeGeometry.readingWidth
        let content = subviews[1].sizeThatFits(ProposedViewSize(width: max(0, width - leadingWidth - spacing), height: nil))
        let leading = subviews[0].sizeThatFits(ProposedViewSize(width: leadingWidth,
            height: stretchesLeading ? content.height : nil))
        return CGSize(width: width, height: max(content.height, leading.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let contentWidth = max(0, bounds.width - leadingWidth - spacing)
        // SwiftUI mirrors custom-layout placement for right-to-left content.
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading,
            proposal: ProposedViewSize(width: leadingWidth, height: stretchesLeading ? bounds.height : nil))
        subviews[1].place(at: CGPoint(x: bounds.minX + leadingWidth + spacing, y: bounds.minY), anchor: .topLeading,
            proposal: ProposedViewSize(width: contentWidth, height: bounds.height))
    }
}
