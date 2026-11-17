import AppKit
import MokuseiCore
import Observation
import SwiftUI

/// A collection owns its contents and lifetime; the workspace owns the viewport.
/// Keeping this above the canvas prevents camera zoom and card clipping from
/// becoming the coordinate system of an expanded collection.
@MainActor @Observable public final class NativeCollectionPanelPresentation {
    public private(set) var owner: UUID?
    public private(set) var closing = false
    fileprivate var content = AnyView(EmptyView())
    fileprivate var source: CGRect?
    fileprivate let motion = NativeReadingPageMotion()
    @ObservationIgnored fileprivate let viewport = NativeCollectionPanelSource()
    @ObservationIgnored private var origin: NativeCollectionPanelSource?
    @ObservationIgnored private var onDismiss: (() -> Void)?

    public init() {}

    public func present(owner: UUID, source: NativeCollectionPanelSource,
                        content: AnyView, onDismiss: @escaping () -> Void) {
        guard self.owner == nil else { return }
        origin = source
        self.source = source.frame(in: viewport)
        self.content = content
        self.onDismiss = onDismiss
        closing = false
        self.owner = owner
    }

    public func update(owner: UUID, content: AnyView) {
        guard self.owner == owner, !closing else { return }
        self.content = content
    }

    public func close(owner: UUID) {
        guard self.owner == owner, !closing else { return }
        closing = true
        source = origin?.frame(in: viewport)
        motion.close()
    }

    /// Removal, covering navigation and member opens must not leave a returning
    /// surface alive above a new route. Only explicit Back/Close animates return.
    public func dismiss(owner: UUID) {
        guard self.owner == owner else { return }
        let callback = onDismiss
        onDismiss = nil; self.owner = nil; origin = nil
        closing = false; content = AnyView(EmptyView())
        callback?()
    }
}

public extension EnvironmentValues {
    @Entry var nativeCollectionPanel: NativeCollectionPanelPresentation? = nil
}

@MainActor public final class NativeCollectionPanelSource {
    fileprivate weak var view: NSView?
    public init() {}
    fileprivate func frame(in viewport: NativeCollectionPanelSource) -> CGRect? {
        guard let view, let root = viewport.view, view.window != nil,
              view.window === root.window else { return nil }
        return root.convert(view.bounds, from: view)
    }
}

public struct NativeCollectionPanelAnchor: NSViewRepresentable {
    let source: NativeCollectionPanelSource
    public init(_ source: NativeCollectionPanelSource) { self.source = source }
    public func makeNSView(context: Context) -> NSView {
        let view = AnchorView(); source.view = view; return view
    }
    public func updateNSView(_ view: NSView, context: Context) { source.view = view }
    private final class AnchorView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
    }
}

public extension View {
    func nativeCollectionPanelHost(enabled: Bool = true) -> some View {
        modifier(NativeCollectionPanelHost(enabled: enabled))
    }
}

private struct NativeCollectionPanelHost: ViewModifier {
    let enabled: Bool
    @State private var presentation = NativeCollectionPanelPresentation()
    @State private var parentVisible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        NativeReadingPageStack(open: presentation.owner != nil,
            identity: "collection-members", motion: presentation.motion,
            stationaryParent: true, emphasizedOpening: true, panel: true,
            panelSource: presentation.source, threadPanelMotion: true,
            onParentPresentationChange: { parentVisible = $0 },
            onPanelOutsideClick: { close() },
            onClose: { dismiss() }) {
                content
                    .opacity(parentVisible ? 1 : 0)
                    .animation(reduceMotion ? nil : NativeReadingPageTiming.openingAnimation, value: parentVisible)
            } front: {
                // The shared compositor reserves a 76pt auxiliary-control lane.
                // Collections have no sidecards; keep that lane outside the grid.
                presentation.content.padding(.trailing, 76)
            }
            .background(NativeCollectionPanelAnchor(presentation.viewport))
            .environment(\.nativeCollectionPanel, presentation)
            .nativeReadingEscape(perform: presentation.owner == nil ? nil : { close() })
            .onChange(of: enabled) { _, value in if !value { dismiss() } }
            .onDisappear { dismiss() }
    }
    private func close() {
        if let owner = presentation.owner { presentation.close(owner: owner) }
    }
    private func dismiss() {
        if let owner = presentation.owner { presentation.dismiss(owner: owner) }
    }
}
