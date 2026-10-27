import AppKit
import SwiftUI

/// Plugin-owned reading/editing regions retain native scroll and pinch input.
/// Weak native anchors follow presentation geometry without publishing per-frame
/// rectangles through the entire SwiftUI card tree.
@MainActor public final class NativeCanvasInputRegions {
    private let views = NSHashTable<NativePlatformView>.weakObjects()
    public init() {}
    public func contains(_ point: CGPoint, in window: NativePlatformWindow) -> Bool {
        views.allObjects.contains { view in
            guard view.window === window else { return false }
            guard !view.isHiddenOrHasHiddenAncestor else { return false }
            // Modern NSViews need not clip to bounds; visibleRect may extend
            // across their parent. Only this registered region owns navigation.
            return view.bounds.intersection(view.visibleRect).contains(view.convert(point, from: nil))
        }
    }
    fileprivate func add(_ view: NativePlatformView) { views.add(view) }
}

private struct CanvasInputRegionsKey: EnvironmentKey {
    static let defaultValue: NativeCanvasInputRegions? = nil
}

extension EnvironmentValues {
    public var nativeCanvasInputRegions: NativeCanvasInputRegions? {
        get { self[CanvasInputRegionsKey.self] }
        set { self[CanvasInputRegionsKey.self] = newValue }
    }
}

extension View {
    /// No effect outside a canvas that provides an input-region registry.
    public func nativeCanvasNavigationRegion() -> some View { modifier(CanvasInputRegionModifier()) }
}

private struct CanvasInputRegionModifier: ViewModifier {
    @Environment(\.nativeCanvasInputRegions) private var regions
    func body(content: Content) -> some View {
        content.background { if let regions { CanvasInputRegion(regions: regions) } }
    }
}

private struct CanvasInputRegion: NSViewRepresentable {
    let regions: NativeCanvasInputRegions
    func makeNSView(context: Context) -> RegionView { RegionView() }
    func updateNSView(_ view: RegionView, context: Context) { regions.add(view) }
    final class RegionView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
