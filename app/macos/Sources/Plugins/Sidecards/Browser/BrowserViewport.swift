import AppKit
import MokuseiPluginUI
import SwiftUI

typealias BrowserViewportNativeView = BrowserViewportNSView

@MainActor
struct BrowserViewport: NSViewRepresentable {
    let session: BrowserWebSession
    let suppressed: Bool
    let coveredBottom: CGFloat
    var cardRect: CGRect? = nil

    func makeNSView(context: Context) -> BrowserViewportNSView { BrowserViewportNSView(session: session) }
    func updateNSView(_ view: BrowserViewportNSView, context: Context) {
        view.update(session: session, suppressed: suppressed, coveredBottom: coveredBottom, cardRect: cardRect)
    }
    static func dismantleNSView(_ nsView: BrowserViewportNSView, coordinator: ()) { nsView.detach() }
}

/// Clipping changes the native painting/hit-test region without changing the
/// webpage's viewport when the annotation list expands over it.
@MainActor
final class BrowserViewportNSView: NSView {
    private var session: BrowserWebSession
    private let clippingView = BrowserWebClipView()
    private var editor: NSHostingView<AnyView>?
    private let editorViewport = BrowserWebClipView()
    private weak var portalRoot: NSView?
    private var nativeVisible = false
    private var hostZoomFactor: CGFloat = 1
    private var renderedHostScale: CGFloat = 1
    private var pageCSSRect = CGRect.zero
    private var cardRect: CGRect?
    private var coveredBottom: CGFloat = 0
    private var suppressed = true
    private var previousSize = CGSize.zero
    override var isFlipped: Bool { true }
    // Only the visible document/editor own input. Transparent and suppressed
    // parts of the representable must not cover other SwiftUI controls.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !suppressed, nativeVisible, session.viewport === self else { return nil }
        let local = convert(point, from: superview)
        if editorViewport.superview === self, let hit = editorViewport.hitTest(local) { return hit }
        return clippingView.superview === self ? clippingView.hitTest(local) : nil
    }

    init(session: BrowserWebSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        clippingView.identifier = NSUserInterfaceItemIdentifier("mokusei-browser-document-portal")
        clippingView.wantsLayer = true
        clippingView.layer?.masksToBounds = true
        clippingView.layer?.cornerRadius = 12
        editorViewport.wantsLayer = true
        editorViewport.identifier = NSUserInterfaceItemIdentifier("mokusei-browser-annotation-portal")
        editorViewport.layer?.masksToBounds = true
        clippingView.addSubview(session.webView)
        session.viewport = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(session: BrowserWebSession, suppressed: Bool, coveredBottom: CGFloat, cardRect: CGRect? = nil) {
        if self.session !== session {
            guard session.viewport == nil || session.viewport === self else { detachPortals(); return }
            if self.session.viewport === self {
                self.session.webView.removeFromSuperview(); self.session.viewport = nil
            }
            self.session = session
            clippingView.addSubview(session.webView); session.viewport = self
        }
        guard session.viewport === self else { detachPortals(); return }
        self.coveredBottom = max(0, coveredBottom)
        self.cardRect = cardRect
        setSuppressed(suppressed)
        refreshEditor()
        needsLayout = true
    }
    func setSuppressed(_ hidden: Bool) {
        let changed = suppressed != hidden
        suppressed = hidden
        if hidden, let responder = window?.firstResponder as? NSView,
           (session.viewport === self && responder === session.webView) || responder.isDescendant(of: clippingView) || responder.isDescendant(of: editorViewport) {
            window?.makeFirstResponder(nil)
        }
        if hidden {
            nativeVisible = false
            detachPortals()
        } else if changed {
            // Reattach only after layout has placed the portal at its final
            // geometry. A stale frame must never intercept toolbar clicks.
            needsLayout = true
        }
    }
    override func layout() {
        super.layout()
        guard session.viewport === self else { nativeVisible = false; detachPortals(); return }
        guard !suppressed else { return }
        guard let root = window?.contentView, bounds.width > 0, bounds.height > 0 else {
            nativeVisible = false; synchronizePortals(); return
        }
        portalRoot = root
        let visual = convert(bounds, to: root)
        renderedHostScale = visual.width / bounds.width
        guard renderedHostScale.isFinite, renderedHostScale > 0 else { return }
        // SwiftUI already applies the workspace scale when converting to the
        // window. Recover logical coordinates once before placing native web content.
        hostZoomFactor = renderedHostScale
        let visualTop = root.isFlipped ? visual.minY : root.bounds.maxY - visual.maxY
        let css = CGRect(x: visual.minX / hostZoomFactor, y: visualTop / hostZoomFactor,
                         width: visual.width / hostZoomFactor, height: visual.height / hostZoomFactor)
        let cssTop = css.minY
        pageCSSRect = css
        func edge(_ value: CGFloat, maximum: CGFloat) -> CGFloat { min(maximum, max(0, (value * hostZoomFactor).rounded())) }
        let left = edge(css.minX, maximum: root.bounds.width), right = edge(css.maxX, maximum: root.bounds.width)
        let top = edge(cssTop, maximum: root.bounds.height), bottom = edge(cssTop + css.height, maximum: root.bounds.height)
        let size = CGSize(width: max(0, right - left), height: max(0, bottom - top))
        let covered = min(size.height, max(0, (coveredBottom * hostZoomFactor).rounded()))
        let clippedHeight = max(0, size.height - covered)
        // Keep native DIP bounds for WebKit, compensating the host's transform
        // with this AppKit container's frame/bounds mapping. Its layer stays
        // inside the representable: NSHostingView owns its root sublayer list
        // and can discard layers belonging to manually inserted root children.
        let clipFrame = CGRect(x: left, y: root.isFlipped ? top : root.bounds.height - top - clippedHeight,
                               width: size.width, height: clippedHeight)
        let localClipFrame = convert(clipFrame, from: root)
        if clippingView.frame != localClipFrame { clippingView.frame = localClipFrame }
        let clipBounds = CGRect(origin: .zero, size: clipFrame.size)
        if clippingView.bounds != clipBounds { clippingView.bounds = clipBounds }
        if clippingView.layer?.cornerRadius != 12 * hostZoomFactor { clippingView.layer?.cornerRadius = 12 * hostZoomFactor }
        let pageFrame = CGRect(origin: .zero, size: size)
        if session.webView.frame != pageFrame { session.webView.frame = pageFrame }
        nativeVisible = size.width > 0 && size.height > 0
        synchronizePortals()
        layoutEditor()
        if size != previousSize {
            previousSize = size
            session.refreshSelectionAfterResize()
        }
    }
    private func synchronizePortals() {
        guard session.viewport === self, !suppressed, nativeVisible, let root = window?.contentView, root === portalRoot else {
            detachPortals(); return
        }
        if clippingView.superview !== self { addSubview(clippingView) }
        if editor != nil {
            if editorViewport.superview !== self { addSubview(editorViewport, positioned: .above, relativeTo: clippingView) }
        } else { editorViewport.removeFromSuperview() }
    }
    private func detachPortals() {
        let owner = clippingView.window ?? editorViewport.window ?? window
        if let responder = owner?.firstResponder as? NSView,
           (session.viewport === self && responder === session.webView) || responder.isDescendant(of: clippingView) || responder.isDescendant(of: editorViewport) {
            owner?.makeFirstResponder(nil)
        }
        clippingView.removeFromSuperview(); editorViewport.removeFromSuperview()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeAncestorGeometry()
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeAncestorGeometry()
    }
    private func observeAncestorGeometry() {
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        guard window != nil else {
            nativeVisible = false; detachPortals(); portalRoot = nil
            return
        }
        var ancestor = superview
        while let view = ancestor {
            view.postsBoundsChangedNotifications = true; view.postsFrameChangedNotifications = true
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(ancestorGeometryChanged(_:)), name: name, object: view)
            }
            ancestor = view.superview
        }
        needsLayout = true
    }
    @objc private func ancestorGeometryChanged(_ notification: Notification) {
        // AppKit coalesces these notifications into its next layout pass.
        // Reentrant layout here repeatedly resizes WebKit during host animation.
        needsLayout = true
    }
    func refreshEditor() {
        guard session.viewport === self else { detachPortals(); return }
        guard session.selection != nil, session.annotating else {
            if let editor, let responder = window?.firstResponder as? NSView, responder.isDescendant(of: editor), !suppressed { window?.makeFirstResponder(session.webView) }
            editor?.removeFromSuperview(); editor = nil; editorViewport.removeFromSuperview()
            return
        }
        if editor == nil {
            let next = NSHostingView(rootView: AnyView(BrowserAnnotationEditor(session: session)))
            next.sizingOptions = []
            editor = next; editorViewport.addSubview(next)
            synchronizePortals()
        }
        layoutEditor()
    }
    private func layoutEditor() {
        guard session.viewport === self, let selection = session.selection, let editor else { return }
        guard let root = portalRoot else { return }
        let available = CGSize(width: root.bounds.width / hostZoomFactor, height: root.bounds.height / hostZoomFactor)
        let rawCard = (cardRect ?? bounds).offsetBy(dx: pageCSSRect.minX, dy: pageCSSRect.minY)
        // Position in window coordinates, then map into our owned container.
        // Keep the editor below the toolbar
        // even when a tall selection leaves no room above or below itself.
        let x = max(0, min(rawCard.minX, available.width - 24))
        let y = max(0, min(max(rawCard.minY, pageCSSRect.minY), available.height - 24))
        let card = CGRect(x: x, y: y, width: max(24, min(rawCard.maxX, available.width) - x),
                          height: max(24, min(rawCard.maxY, available.height) - y))
        let width = max(1, min(436, card.width - 16))
        let height = max(1, min(session.captureError.isEmpty ? 66 : 94, card.height - 16))
        let pageScale = CGFloat(session.webView.pageZoom) / hostZoomFactor
        let minX = card.minX + 8, minY = card.minY + 8
        let maxX = max(minX, card.maxX - width - 8), maxY = max(minY, card.maxY - height - 8)
        let below = pageCSSRect.minY + selection.rect.maxY * pageScale + 4
        let above = pageCSSRect.minY + selection.rect.minY * pageScale - height - 4
        let logical = CGRect(x: max(minX, min(pageCSSRect.minX + selection.rect.minX * pageScale - 8, maxX)),
                             y: max(minY, min(below <= maxY ? below : above >= minY ? above : maxY, maxY)), width: width, height: height)
        let nativeSize = CGSize(width: max(1, (logical.width * hostZoomFactor).rounded()), height: max(1, (logical.height * hostZoomFactor).rounded()))
        let nativeTop = (logical.minY * hostZoomFactor).rounded()
        let native = CGRect(x: (logical.minX * hostZoomFactor).rounded(),
                            y: root.isFlipped ? nativeTop : root.bounds.height - nativeTop - nativeSize.height,
                            width: nativeSize.width, height: nativeSize.height)
        editorViewport.frame = convert(native, from: root)
        editorViewport.bounds = CGRect(x: 0, y: 0, width: native.width / renderedHostScale, height: native.height / renderedHostScale)
        editor.frame = editorViewport.bounds
        editor.rootView = AnyView(BrowserAnnotationEditor(session: session).frame(width: logical.width, height: logical.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
    }
    func detach() {
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        setSuppressed(true)
        if session.viewport === self { session.viewport = nil; session.webView.removeFromSuperview() }
        detachPortals(); portalRoot = nil
        editor?.removeFromSuperview(); editor = nil
    }
}

private final class BrowserWebClipView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // NSView hit testing otherwise permits a large child outside its bounds.
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return super.hitTest(point)
    }
}


@MainActor
struct BrowserAnnotationEditor: View {
    @Bindable var session: BrowserWebSession
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                TextField("描述要修改的内容…", text: Binding(get: { session.comment }, set: { session.comment = BrowserText.limit($0, utf16: 10_000) }))
                    .textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(.white)
                    .focused($focused).disabled(session.capturing).onSubmit { session.captureAnnotation() }
                    .accessibilityLabel("批注内容")
                Button { session.captureAnnotation() } label: { NativeIcon(name: "Check", size: 18).frame(width: 36, height: 36) }
                    .buttonStyle(.plain).foregroundStyle(Color(white: 0.19)).background(.white, in: Circle())
                    .disabled(session.capturing || session.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(session.capturing || session.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
                    .accessibilityLabel("添加批注")
            }
            .padding(.leading, 18).padding(.trailing, 7).frame(height: 50)
            .background(BrowserAnnotationBackdrop()).clipShape(Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.2), radius: 14, y: 4)
            if !session.captureError.isEmpty {
                Text(session.captureError).font(.system(size: 11)).foregroundStyle(.white).lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(Color(white: 0.19), in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { focused = true }
        .onChange(of: session.capturing) { _, busy in if !busy { focused = true } }
        .nativeOnExitCommand { session.cancelAnnotation() }
        .preferredColorScheme(.dark)
    }
}

struct BrowserAnnotationBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow; view.blendingMode = .withinWindow; view.state = .active
        view.wantsLayer = true; view.layer?.backgroundColor = NSColor(white: 0.137, alpha: 0.56).cgColor
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
