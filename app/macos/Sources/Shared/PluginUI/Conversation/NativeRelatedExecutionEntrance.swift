import AppKit
import QuartzCore
import SwiftUI

/// One related-execution visit owns admission, independently of manifest and
/// row resource revisions. Hidden preparation keeps the real reader mounted.
public struct NativeRelatedExecutionEntrance<Content: View>: View {
    private let content: Content
    @State private var preparation = NativeReadingContentPreparation()
    @State private var admitted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nativeReadingInteractionActive) private var interactionActive

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        ZStack {
            if !admitted {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            RelatedExecutionFade(admitted: admitted, reduceMotion: reduceMotion) {
                content
                // A manifest mounts before its row and asynchronous Markdown.
                // Use the reader's content signal plus the existing parse gate;
                // an onAppear fade would be consumed by the loading document.
                .environment(\.nativeReadingContentPreparation, preparation)
                .environment(\.nativeThreadContentReveal, false)
                .onPreferenceChange(NativeReadingContentRevealStatusKey.self) { status in
                    guard status.complete, !admitted else { return }
                    preparation.admit {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { admitted = true }
                    }
                }
                .transaction(value: admitted) { $0.animation = nil }
                .environment(\.nativeReadingInteractionActive, interactionActive && admitted)
                .disabled(!admitted)
                .allowsHitTesting(admitted)
                .accessibilityHidden(!admitted)
            }
        }
        .onDisappear { preparation.cancel() }
    }
}

/// Core Animation owns only paint; native text gets its destination layout once.
/// Removing this animation also settles an in-flight Reduce Motion change.
private struct RelatedExecutionFade<Content: View>: NSViewRepresentable {
    let admitted: Bool
    let reduceMotion: Bool
    @ViewBuilder let content: Content

    func makeNSView(context: Context) -> RelatedExecutionFadeView { RelatedExecutionFadeView() }
    func updateNSView(_ view: RelatedExecutionFadeView, context: Context) {
        view.update(content: AnyView(content.environment(\.self, context.environment)),
                    admitted: admitted, reduceMotion: reduceMotion)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RelatedExecutionFadeView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
    static func dismantleNSView(_ view: RelatedExecutionFadeView, coordinator: ()) {
        view.host.layer?.removeAllAnimations()
        view.host.rootView = AnyView(EmptyView())
    }
}

@MainActor private final class RelatedExecutionFadeView: NSView {
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    private var admitted = false
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("related-execution-entrance")
        host.sizingOptions = []; host.safeAreaRegions = []
        host.wantsLayer = true; host.alphaValue = 0
        addSubview(host)
    }
    required init?(coder: NSCoder) { nil }
    func update(content: AnyView, admitted: Bool, reduceMotion: Bool) {
        host.rootView = content
        if admitted && !self.admitted {
            self.admitted = true
            host.frame = bounds
            host.layoutSubtreeIfNeeded()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            host.alphaValue = 1
            if !reduceMotion {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.2
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                host.layer?.add(fade, forKey: "related.execution.entrance")
            }
            CATransaction.commit()
        }
        if reduceMotion { host.layer?.removeAnimation(forKey: "related.execution.entrance") }
    }
    override func layout() { super.layout(); host.frame = bounds }
    override func hitTest(_ point: NSPoint) -> NSView? { admitted ? super.hitTest(point) : nil }
    override func accessibilityChildren() -> [Any]? { admitted ? super.accessibilityChildren() : [] }
}
