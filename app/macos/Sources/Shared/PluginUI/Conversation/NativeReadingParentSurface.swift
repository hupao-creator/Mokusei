import AppKit
import SwiftUI

/// Retain the parent's state without drawing its cards behind a settled panel.
/// The window's existing material supplies the backdrop; return preparation
/// resumes this same native host with the latest layout.
struct NativeReadingParentSurface<Content: View>: NSViewRepresentable {
    let frozen: Bool
    let content: Content

    func makeNSView(context: Context) -> NativeReadingParentView { NativeReadingParentView() }
    func updateNSView(_ view: NativeReadingParentView, context: Context) {
        view.update(content: AnyView(content.environment(\.self, context.environment)), frozen: frozen)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeReadingParentView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
    static func dismantleNSView(_ view: NativeReadingParentView, coordinator: ()) { view.retire() }
}

@MainActor final class NativeReadingParentView: NSView {
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    private var freezeRequested = false
    private var hideScheduled = false
    private var retired = false

    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hosting.sizingOptions = []
        // The workspace already supplies full-content bounds. A nested host
        // must not inset and clip its canvas again below the window titlebar.
        hosting.safeAreaRegions = []
        addSubview(hosting)
    }
    required init?(coder: NSCoder) { nil }

    func update(content: AnyView, frozen: Bool) {
        freezeRequested = frozen
        if frozen {
            guard !hosting.isHidden, !hideScheduled else { return }
            hideScheduled = true
            // Hiding a focused host synchronously asks AppKit for its next key
            // view. That traversal reads SwiftUI geometry and would re-enter
            // the graph currently evaluating this representable. Input and AX
            // close immediately; the already-transparent host hides afterward.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.hideScheduled = false
                guard !self.retired, self.freezeRequested else { return }
                self.hosting.isHidden = true
            }
        } else {
            hosting.rootView = content
            hosting.frame = bounds
            hosting.isHidden = false
        }
    }

    override func layout() {
        super.layout()
        // The hidden tree keeps its last viewport until return preparation.
        if !freezeRequested && !hosting.isHidden {
            hosting.frame = bounds
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        freezeRequested ? nil : super.hitTest(point)
    }
    override func accessibilityChildren() -> [Any]? {
        freezeRequested ? [] : super.accessibilityChildren()
    }
    func retire() {
        retired = true
        hosting.rootView = AnyView(EmptyView())
    }
}
