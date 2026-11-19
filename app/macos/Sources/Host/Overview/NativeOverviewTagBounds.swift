import SwiftUI

struct OverviewTagBounds: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

extension View {
    func overviewTagAnchor(_ id: String) -> some View {
        // A bar/scroll anchor must preserve the anchors of its descendants.
        transformAnchorPreference(key: OverviewTagBounds.self, value: .bounds) { bounds, anchor in
            bounds[id] = anchor
        }
    }
}
