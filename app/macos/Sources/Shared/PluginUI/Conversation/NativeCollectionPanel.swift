import AppKit
import ChiefCore
import ChiefPluginAPI
import Observation
import SwiftUI

/// A collection owns its contents and lifetime; the workspace owns the viewport.
/// Keeping this above the canvas prevents camera zoom and card clipping from
/// becoming the coordinate system of an expanded collection.
@MainActor @Observable public final class NativeCollectionPanelPresentation {
    public private(set) var owner: UUID?
    public var transitioning: Bool { motion.active }
    public private(set) var closing = false
    public private(set) var readingMember: ApplicationThreadRef?
    public fileprivate(set) var parentVisible = true
    private var memberSource: NativeCollectionPanelSource?
    public var memberFrame: CGRect? { memberSource?.visibleFrame(in: viewport) }
    @ObservationIgnored private var requestedMember: ApplicationThreadRef?
    fileprivate var content = AnyView(EmptyView())
    fileprivate var source: CGRect?
    fileprivate let motion = NativeReadingPageMotion()
    @ObservationIgnored fileprivate let viewport = NativeCollectionPanelSource()
    @ObservationIgnored private var origin: NativeCollectionPanelSource?
    @ObservationIgnored private var onDismiss: ((_ restoreFocus: Bool) -> Void)?

    private let onRetire: () -> Void
    public init(onRetire: @escaping () -> Void = {}) { self.onRetire = onRetire }

    public func present(owner: UUID, source: NativeCollectionPanelSource,
                        content: AnyView, onDismiss: @escaping (_ restoreFocus: Bool) -> Void) {
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
        guard self.owner == owner, !closing, readingMember == nil else { return }
        closing = true
        source = origin?.frame(in: viewport)
        motion.close()
    }

    /// The callback still owns route admission. Only that synchronous navigation
    /// can claim the member frame, even if a later route opens the same report.
    public func openMember(_ member: ApplicationThreadRef, source: NativeCollectionPanelSource,
                           navigate: () -> Void) {
        guard owner != nil, !closing, readingMember == nil else { return }
        requestedMember = member
        memberSource = source
        navigate()
        requestedMember = nil
        if readingMember == nil { memberSource = nil }
    }

    public func acceptOpening(_ member: ApplicationThreadRef) {
        guard requestedMember == member else { return }
        readingMember = member
    }

    public func returnToMembers() {
        readingMember = nil
        memberSource = nil
    }

    public func dismiss(owner: UUID) {
        guard self.owner == owner, readingMember == nil else { return }
        retire()
    }

    public func retire() {
        guard owner != nil else { return }
        let restoreFocus = readingMember == nil
        returnToMembers()
        let callback = onDismiss
        onDismiss = nil; self.owner = nil; origin = nil
        closing = false; parentVisible = true; content = AnyView(EmptyView())
        callback?(restoreFocus)
        onRetire()
    }
}

public extension EnvironmentValues {
    @Entry var collectionReturnMember: ApplicationThreadRef? = nil
    @Entry var nativeCollectionPanel: NativeCollectionPanelPresentation? = nil
    @Entry var collectionReadingSource: NativeOverviewReadingSource? = nil
}

/// The reader can claim its Overview card after the requested member owns the page.
@MainActor public struct NativeOverviewReadingSource {
    public let id = UUID()
    public let member: ApplicationThreadRef
    public let onReady: () -> Void
    public init(member: ApplicationThreadRef, onReady: @escaping () -> Void) {
        self.member = member
        self.onReady = onReady
    }
}

@MainActor public final class NativeCollectionPanelSource {
    fileprivate weak var view: NSView?
    public init() {}
    fileprivate func visibleFrame(in viewport: NativeCollectionPanelSource) -> CGRect? {
        guard let view, let root = viewport.view, let window = view.window,
              window === root.window else { return nil }
        // SwiftUI's unmasked AppKit anchor can report the enclosing scroll
        // viewport as visibleRect, extending well beyond the card itself.
        let visible = view.bounds.intersection(view.visibleRect)
        guard !visible.isEmpty else { return nil }
        let rect = root.convert(visible, from: view).intersection(root.bounds)
        return rect.isEmpty ? nil : rect
    }
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
    func nativeCollectionPanelHost(enabled: Bool = true, presentation: NativeCollectionPanelPresentation? = nil) -> some View {
        modifier(NativeCollectionPanelHost(enabled: enabled, presentation: presentation))
    }
}

private struct NativeCollectionPanelHost: ViewModifier {
    let enabled: Bool
    @State private var presentation: NativeCollectionPanelPresentation
    init(enabled: Bool, presentation: NativeCollectionPanelPresentation?) {
        self.enabled = enabled
        _presentation = State(initialValue: presentation ?? NativeCollectionPanelPresentation())
    }

    func body(content: Content) -> some View {
        let open = presentation.owner != nil
        let interactive = open && presentation.readingMember == nil
        ZStack {
            content
                .opacity(presentation.parentVisible ? 1 : 0)
                .animation(NativeReadingPageTiming.openingAnimation, value: presentation.parentVisible)
                .allowsHitTesting(!open).disabled(open).accessibilityHidden(open)
            NativeReadingPageStack(open: open, identity: "collection-members", motion: presentation.motion,
                stationaryParent: true, emphasizedOpening: true, panel: true, panelUsesGlass: true,
                panelSource: presentation.source, threadPanelMotion: true,
                onParentPresentationChange: { presentation.parentVisible = $0 },
                onPanelOutsideClick: { close() },
                onClose: { presentation.retire() }) {
                    Color.clear
                } front: {
                    presentation.content.padding(.trailing, 76)
                }
                .allowsHitTesting(interactive)
                .disabled(!interactive)
                .accessibilityHidden(!interactive)
        }
        .background(NativeCollectionPanelAnchor(presentation.viewport))
        .environment(\.nativeCollectionPanel, presentation)
        .nativeReadingEscape(perform: interactive ? { close() } : nil)
        .onChange(of: enabled) { _, value in if !value { presentation.retire() } }
        .onDisappear { presentation.retire() }
    }

    private func close() {
        if let owner = presentation.owner { presentation.close(owner: owner) }
    }
}
