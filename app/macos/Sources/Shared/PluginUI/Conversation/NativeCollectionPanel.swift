import AppKit
import MokuseiCore
import MokuseiPluginAPI
import Observation
import SwiftUI

/// A collection owns its contents and lifetime; the workspace owns the viewport.
/// Keeping this above the canvas prevents camera zoom and card clipping from
/// becoming the coordinate system of an expanded collection.
@MainActor @Observable public final class NativeCollectionPanelPresentation {
    public private(set) var owner: UUID?
    public private(set) var closing = false
    public private(set) var openingMember: ApplicationThreadRef?
    fileprivate var memberFrame: CGRect?
    @ObservationIgnored private var requestedMember: ApplicationThreadRef?
    fileprivate var content = AnyView(EmptyView())
    fileprivate var source: CGRect?
    fileprivate let motion = NativeReadingPageMotion()
    @ObservationIgnored fileprivate let viewport = NativeCollectionPanelSource()
    @ObservationIgnored private var origin: NativeCollectionPanelSource?
    @ObservationIgnored private var onDismiss: ((_ restoreFocus: Bool) -> Void)?

    public init() {}

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
        guard self.owner == owner, !closing else { return }
        closing = true
        source = origin?.frame(in: viewport)
        motion.close()
    }

    /// The callback still owns route admission. Only that synchronous navigation
    /// can claim the member frame, even if a later route opens the same report.
    public func openMember(_ member: ApplicationThreadRef, source: NativeCollectionPanelSource,
                           navigate: () -> Void) {
        guard owner != nil, !closing else { return }
        requestedMember = member
        if let frame = source.visibleFrame(in: viewport), let bounds = viewport.view?.bounds {
            let panel = NativeReadingPanelGeometry.frame(in: bounds.size)
            memberFrame = frame.offsetBy(dx: -panel.minX, dy: -panel.minY)
        }
        navigate()
        requestedMember = nil
        if openingMember == nil { memberFrame = nil }
    }

    public func acceptOpening(_ member: ApplicationThreadRef) {
        guard requestedMember == member else { return }
        openingMember = member
        closing = true
    }

    /// A selected reader deactivates the carousel immediately. Its mounted grid
    /// belongs to the handoff until the workspace has drawn the destination.
    public func dismiss(owner: UUID) {
        guard self.owner == owner, openingMember == nil else { return }
        retire()
    }

    fileprivate func retire() {
        let restoreFocus = openingMember == nil
        openingMember = nil; memberFrame = nil
        let callback = onDismiss
        onDismiss = nil; self.owner = nil; origin = nil
        closing = false; content = AnyView(EmptyView())
        callback?(restoreFocus)
    }
}

public extension EnvironmentValues {
    @Entry var collectionReturnMember: ApplicationThreadRef? = nil
    @Entry var nativeCollectionPanel: NativeCollectionPanelPresentation? = nil
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
    func nativeCollectionPanelHost(enabled: Bool = true, presentation: NativeCollectionPanelPresentation? = nil,
                                   readerReady: Bool = false) -> some View {
        modifier(NativeCollectionPanelHost(enabled: enabled, presentation: presentation, readerReady: readerReady))
    }
}

private struct NativeCollectionPanelHost: ViewModifier {
    let enabled: Bool
    let readerReady: Bool
    @State private var presentation: NativeCollectionPanelPresentation
    @State private var parentVisible = true
    @State private var reveal: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    init(enabled: Bool, presentation: NativeCollectionPanelPresentation?, readerReady: Bool) {
        self.enabled = enabled
        self.readerReady = readerReady
        _presentation = State(initialValue: presentation ?? NativeCollectionPanelPresentation())
    }

    func body(content: Content) -> some View {
        let open = presentation.owner != nil
        let handingOff = presentation.openingMember != nil
        ZStack {
            content
                .opacity(handingOff ? reveal : parentVisible ? 1 : 0)
                .animation(handingOff ? nil : NativeReadingPageTiming.openingAnimation, value: parentVisible)
                .allowsHitTesting(!open).disabled(open).accessibilityHidden(open)
            NativeReadingPageStack(open: open, identity: "collection-members", motion: presentation.motion,
                stationaryParent: true, emphasizedOpening: true, panel: true, panelUsesGlass: true,
                panelSource: presentation.source, threadPanelMotion: true,
                onParentPresentationChange: { parentVisible = $0 },
                onPanelOutsideClick: { close() },
                onClose: { presentation.retire() }) {
                    Color.clear
                } front: {
                    // Collections have no sidecards in the compositor's auxiliary lane.
                    presentation.content
                        .modifier(MemberZoom(source: presentation.memberFrame, progress: reveal))
                        .animation(reduceMotion ? nil : NativeReadingPageTiming.openingAnimation, value: reveal)
                        .clipped()
                        .padding(.trailing, 76)
                }
                .allowsHitTesting(open && !handingOff)
                .opacity(handingOff ? 1 - reveal : 1)
                .accessibilityHidden(!open || handingOff)
        }
        .background(NativeCollectionPanelAnchor(presentation.viewport))
        .environment(\.nativeCollectionPanel, presentation)
        .nativeReadingEscape(perform: open && !handingOff ? { close() } : nil)
        .onChange(of: readerReady && handingOff) { _, ready in
            guard ready, let owner = presentation.owner else { return }
            if reduceMotion || phase != .active { finishHandoff(); return }
            withAnimation(NativeReadingPageTiming.openingAnimation, completionCriteria: .removed) {
                reveal = 1
            } completion: {
                if presentation.owner == owner, presentation.openingMember != nil { finishHandoff() }
            }
        }
        .onChange(of: enabled) { _, value in if !value { finishHandoff() } }
        .onChange(of: phase) { _, value in if handingOff && value != .active { finishHandoff() } }
        .onChange(of: reduceMotion) { _, value in if handingOff && readerReady && value { finishHandoff() } }
        .onDisappear { finishHandoff() }
    }

    private func close() {
        if let owner = presentation.owner { presentation.close(owner: owner) }
    }
    private func finishHandoff() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            presentation.retire()
            parentVisible = true
            reveal = 0
        }
    }
}

/// Grow the selected card in the clipped grid without stretching its cover.
private struct MemberZoom: GeometryEffect {
    let source: CGRect?
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        guard let source, !source.isEmpty else { return ProjectionTransform(CGAffineTransform.identity) }
        let fit = min(size.width / source.width, size.height / source.height)
        let scale = 1 + (fit - 1) * progress
        return ProjectionTransform(CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
            tx: (size.width / 2 - source.midX * fit) * progress,
            ty: (size.height / 2 - source.midY * fit) * progress))
    }
}
