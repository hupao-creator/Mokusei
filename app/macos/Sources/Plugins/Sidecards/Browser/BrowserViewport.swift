import AppKit
import MokuseiPluginUI
import SwiftUI

typealias BrowserViewportNativeView = BrowserViewportNSView

@MainActor
struct BrowserViewport: NSViewRepresentable {
    let session: BrowserWebSession
    let suppressed: Bool
    let coveredBottom: CGFloat

    func makeNSView(context: Context) -> BrowserViewportNSView { BrowserViewportNSView(session: session) }
    func updateNSView(_ view: BrowserViewportNSView, context: Context) {
        view.update(session: session, suppressed: suppressed, coveredBottom: coveredBottom)
    }
    static func dismantleNSView(_ nsView: BrowserViewportNSView, coordinator: ()) { nsView.detach() }
}

/// Clipping changes the native painting/hit-test region without changing the
/// webpage's viewport when the annotation list expands over it.
@MainActor
final class BrowserViewportNSView: NSView {
    private var session: BrowserWebSession
    private let clippingView = BrowserWebClipView()
    private weak var portalRoot: NSView?
    private var nativeVisible = false
    private var hostZoomFactor: CGFloat = 1
    private var renderedHostScale: CGFloat = 1
    private var coveredBottom: CGFloat = 0
    private var suppressed = true
    private var previousSize = CGSize.zero
    override var isFlipped: Bool { true }
    // Only the visible document owns input. Transparent and suppressed
    // parts of the representable must not cover other SwiftUI controls.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !suppressed, nativeVisible, session.viewport === self else { return nil }
        let local = convert(point, from: superview)
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
        clippingView.addSubview(session.webView)
        session.viewport = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(session: BrowserWebSession, suppressed: Bool, coveredBottom: CGFloat) {
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
        setSuppressed(suppressed)
        refreshAnnotationGeometry()
        needsLayout = true
    }
    func setSuppressed(_ hidden: Bool) {
        let changed = suppressed != hidden
        suppressed = hidden
        if hidden, let responder = window?.firstResponder as? NSView,
           (session.viewport === self && responder === session.webView) || responder.isDescendant(of: clippingView) {
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
    }
    private func detachPortals() {
        let owner = clippingView.window ?? window
        if let responder = owner?.firstResponder as? NSView,
           (session.viewport === self && responder === session.webView) || responder.isDescendant(of: clippingView) {
            owner?.makeFirstResponder(nil)
        }
        clippingView.removeFromSuperview()
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
    // Selection/zoom changes still invalidate native geometry. Description
    // input belongs to the resident Dock rather than a portal over the page.
    func refreshAnnotationGeometry() { needsLayout = true }
    func detach() {
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        setSuppressed(true)
        if session.viewport === self { session.viewport = nil; session.webView.removeFromSuperview() }
        detachPortals(); portalRoot = nil
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
