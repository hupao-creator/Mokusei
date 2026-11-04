import AppKit
import SwiftUI

/// Non-TextKit content joins the execution's native line ordering as one row.
/// The inner host keeps SwiftUI's layout and accessibility; its parent owns paint.
struct NativeThreadRevealRow<Content: View>: NSViewRepresentable {
    let contentID: String
    @ViewBuilder var content: Content
    @Environment(\.nativeThreadReveal) private var reveal

    func makeNSView(context: Context) -> ThreadRevealRowView {
        let view = ThreadRevealRowView()
        view.reveal = reveal
        reveal?.register(view)
        return view
    }

    func updateNSView(_ view: ThreadRevealRowView, context: Context) {
        if let previous = view.contentID, previous != contentID { view.reveal?.contentChanged(view) }
        view.contentID = contentID
        view.host.rootView = AnyView(content.environment(\.self, context.environment))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ThreadRevealRowView, context: Context) -> CGSize? {
        let width = proposal.width ?? NativeGeometry.readingWidth
        let measured = nsView.host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: measured.height)
    }

    static func dismantleNSView(_ view: ThreadRevealRowView, coordinator: ()) {
        view.reveal?.unregister(view)
    }
}

@MainActor
final class ThreadRevealRowView: NSView {
    let host = NSHostingController(rootView: AnyView(EmptyView()))
    weak var reveal: NativeThreadContentReveal?
    var contentID: String?
    var awaitsLineReveal = false {
        // SwiftUI can overwrite the representable's alpha during placement.
        // Hide only our inner host until the outer line mask is committed.
        didSet { host.view.isHidden = awaitsLineReveal }
    }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.view.frame = bounds
        host.view.autoresizingMask = [.width, .height]
        addSubview(host.view)
    }
    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ newSize: NSSize) {
        if frame.width > 0, abs(frame.width - newSize.width) > 0.5 { reveal?.contentChanged(self) }
        super.setFrameSize(newSize)
        host.view.frame = bounds
    }
}
