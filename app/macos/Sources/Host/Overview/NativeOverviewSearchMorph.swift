import SwiftUI
import MokuseiPluginUI

private struct OverviewSearchMorphDurationKey: EnvironmentKey {
    static let defaultValue = OverviewSearchMorphGeometry.duration
}
extension EnvironmentValues {
    // A native fixture can slow the real transition without altering the app
    // or introducing a preview control into the production product surface.
    var overviewSearchMorphDuration: Double {
        get { self[OverviewSearchMorphDurationKey.self] }
        set { self[OverviewSearchMorphDurationKey.self] = newValue }
    }
}

/// Geometry comes from the live toolbar, including its horizontal scroll clip.
/// The ordinary tag hierarchy stays mounted so selection, focus and scroll are
/// restored without rebuilding controls.
struct OverviewSearchTagBounds: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

extension View {
    func overviewSearchAnchor(_ id: String) -> some View {
        // A bar/scroll anchor must preserve the anchors of its descendants.
        transformAnchorPreference(key: OverviewSearchTagBounds.self, value: .bounds) { bounds, anchor in
            bounds[id] = anchor
        }
    }
}

struct OverviewSearchMorphGeometry {
    static let duration = 0.38
    struct Source: Identifiable {
        let id: String
        let title: String
        let count: Int?
        let directory: Bool
        let selected: Bool
        let frame: CGRect
        let labelFrame: CGRect
        var childTitle: String? = nil
        var emoji: String? = nil
    }
    static func sources(bounds: [String: CGRect], filters: [NativeOverviewFilter], all: String,
                        selectedTag: String, selectedScope: String = "",
                        selectedKind: NativeOverviewTagKind?, selectedChildren: [String: NativeOverviewFilter] = [:]) -> [Source] {
        guard let bar = bounds["__bar__"] else { return [] }
        var result: [Source] = []
        if let frame = bounds["__all__"]?.intersection(bar), !frame.isEmpty {
            result.append(.init(id: "__all__", title: all, count: nil, directory: false,
                                selected: selectedTag.isEmpty, frame: frame, labelFrame: frame))
        }
        let clip = (bounds["__scroll__"] ?? bar).intersection(bar)
        for filter in filters {
            guard let full = bounds[filter.id] else { continue }
            let visible = full.intersection(clip)
            guard !visible.isEmpty, visible.width >= 4 else { continue }
            let childSelected = filter.isDirectory && selectedKind == .semantic && !selectedTag.isEmpty && selectedScope == filter.scope
            result.append(.init(id: filter.id, title: filter.displayTag, count: filter.count, directory: filter.isDirectory,
                                selected: childSelected || filter.matches(selectedTag, kind: selectedKind, scope: selectedScope),
                                frame: visible, labelFrame: full, childTitle: selectedChildren[filter.id]?.tag,
                                emoji: selectedChildren[filter.id]?.emoji))
        }
        return result
    }
    static func carrier(in sources: [Source]) -> Source? {
        sources.first(where: \.selected) ?? sources.first(where: { $0.id == "__all__" }) ?? sources.first
    }
    static func frame(source: CGRect, target: CGRect, progress: CGFloat) -> CGRect {
        let p = min(1, max(0, progress))
        return CGRect(x: source.minX + (target.minX - source.minX) * p,
                      y: source.minY + (target.minY - source.minY) * p,
                      width: source.width + (target.width - source.width) * p,
                      height: source.height + (target.height - source.height) * p)
    }
    static func displacedFrame(source: CGRect, origin: CGRect, target: CGRect, progress: CGFloat) -> CGRect {
        let p = min(1, max(0, progress))
        let expanded = frame(source: origin, target: target, progress: p)
        let left = source.midX < origin.midX
        let distance = left ? max(0, origin.minX - expanded.minX) : max(0, expanded.maxX - origin.maxX)
        return source.offsetBy(dx: (left ? -1 : 1) * (distance + 24 * p), dy: 0)
    }
    static func neighborOpacity(progress: CGFloat) -> CGFloat {
        max(0, min(1, 1 - progress / 0.75))
    }
}

/// The selected tag expands while its neighbors make room and fade. This
/// temporary visual plane owns no query, camera or card animation.
struct OverviewSearchMorphLayer<Controls: View>: View, @preconcurrency Animatable {
    var progress: CGFloat
    let searching: Bool
    let sources: [OverviewSearchMorphGeometry.Source]
    let target: CGRect
    @ViewBuilder let controls: (Bool) -> Controls
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    private var selectedSource: OverviewSearchMorphGeometry.Source? {
        OverviewSearchMorphGeometry.carrier(in: sources)
    }
    private var origin: CGRect {
        selectedSource?.frame ?? CGRect(x: target.minX, y: target.midY - 16, width: min(52, target.width), height: 32)
    }
    private var carrier: CGRect {
        OverviewSearchMorphGeometry.frame(source: origin, target: target, progress: progress)
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
            // Independent glass surfaces avoid merging displaced neighbors back
            // into the search carrier. Draw the expanding selected tag last.
            ZStack(alignment: .topLeading) {
                ForEach(sources.filter { $0.id != selectedSource?.id }) { source in
                    surface(source, isCarrier: false)
                }
                surface(selectedSource, isCarrier: true)
            }.allowsHitTesting(false).accessibilityHidden(true)
            if searching {
                // e0a68053: contents share the PRESENTED carrier rect and clip,
                // rather than appearing at the eventual search bounds early.
                controls(progress >= 0.999)
                    .frame(width: max(96, carrier.width), height: carrier.height)
                    .frame(width: carrier.width, height: carrier.height, alignment: .trailing)
                    .clipShape(Capsule())
                    .opacity(min(1, max(0, (progress - 0.45) / 0.30)))
                    .allowsHitTesting(progress > 0.45)
                    .position(x: carrier.midX, y: carrier.midY)
            }
        }
    }
    private func surface(_ source: OverviewSearchMorphGeometry.Source?, isCarrier: Bool) -> some View {
        let rect = isCarrier ? carrier : OverviewSearchMorphGeometry.displacedFrame(
            source: source?.frame ?? origin, origin: origin, target: target, progress: progress)
        return Group {
            if let source {
                HStack(spacing: OverviewTagMetrics.chipContentSpacing) {
                    if source.directory { OverviewTagPrefix(emoji: source.emoji) }
                    OverviewTagTitle(title: source.title, child: source.childTitle)
                    if let count = source.count {
                        Text(String(count)).font(NativeTypography.inter(size: OverviewTagMetrics.countFont, weight: 680))
                            .frame(minWidth: OverviewTagMetrics.countMinWidth)
                            .padding(.horizontal, OverviewTagMetrics.countHorizontalInset)
                            .padding(.vertical, OverviewTagMetrics.countVerticalInset)
                            .background(.foreground.opacity(0.08), in: Capsule())
                    }
                }
                .padding(.horizontal, OverviewTagMetrics.chipLabelInset)
                .frame(width: source.labelFrame.width, height: source.labelFrame.height)
                .offset(x: (source.labelFrame.midX - source.frame.midX) * (isCarrier ? 1 - progress : 1))
                .opacity(isCarrier ? max(0, 1 - progress * 2.5) : 1)
            } else { Color.clear }
        }
        .frame(width: rect.width, height: rect.height)
        .clipped()
        .background { if reduceTransparency { Capsule().fill(NativePalette.overview.surface.swiftUI) } }
        .glassEffect((!isCarrier || progress < 0.001 ? Glass.clear : Glass.regular)
            .tint(source?.selected == true && progress < 0.5 ? NativePalette.overview.accent.swiftUI.opacity(0.16 * (1 - progress * 2)) : nil), in: .capsule)
        .opacity(isCarrier ? 1 : OverviewSearchMorphGeometry.neighborOpacity(progress: progress))
        .overviewSearchAnchor(isCarrier ? "__search_carrier__" : "__search_neighbor__\(source?.id ?? "")")
        .position(x: rect.midX, y: rect.midY)
    }
}
