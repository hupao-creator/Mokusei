import AppKit
import SwiftUI

/// Keeps a decoration's frame clock in a small graph with no sizing feedback
/// into its owning card. The parent still owns placement, scale and clipping.
@MainActor
struct NativeCardDecorationHost<Content: View>: NSViewRepresentable {
    let content: Content

    func makeNSView(context: Context) -> NativeCardDecorationContainer<Content> {
        NativeCardDecorationContainer(content: content, environment: context.environment)
    }

    func updateNSView(_ view: NativeCardDecorationContainer<Content>, context: Context) {
        view.update(content: content, environment: context.environment, transaction: context.transaction)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeCardDecorationContainer<Content>,
                     context: Context) -> CGSize? {
        // Match the fill behavior of the hosted GeometryReader without asking
        // its changing graph to compute the outer view's fitting size.
        proposal.replacingUnspecifiedDimensions()
    }

    static func dismantleNSView(_ view: NativeCardDecorationContainer<Content>, coordinator: ()) {
        view.dismantle()
    }
}

@MainActor
final class NativeCardDecorationContainer<Content: View>: NSView {
    private let hosting: NativeCardDecorationHostingView<Content>

    init(content: Content, environment: EnvironmentValues) {
        hosting = NativeCardDecorationHostingView(rootView: .init(content: content, environment: environment))
        super.init(frame: .zero)
        hosting.sizingOptions = []
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(false)
        hosting.setAccessibilityElement(false)
        addSubview(hosting)
    }

    required init?(coder: NSCoder) { return nil }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(content: Content, environment: EnvironmentValues, transaction: Transaction) {
        // Replacing the value, rather than the host or its root type, retains
        // the cloud's seed/epoch and lets its own running-state fade continue.
        withTransaction(transaction) {
            hosting.rootView = .init(content: content, environment: environment)
        }
    }

    func dismantle() {
        var root = hosting.rootView
        root.content = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { hosting.rootView = root }
        hosting.removeFromSuperview()
    }
}

@MainActor
private struct NativeCardDecorationRoot<Content: View>: View {
    var content: Content?
    let environment: EnvironmentValues

    var body: some View {
        Group {
            if let content { content }
        }
        // A separate host does not inherit SwiftUI environment values from
        // the outer graph, including its read-only accessibility preferences.
        .environment(\.self, environment)
        .accessibilityHidden(true)
    }
}

@MainActor
private final class NativeCardDecorationHostingView<Content: View>: NSHostingView<NativeCardDecorationRoot<Content>> {
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
