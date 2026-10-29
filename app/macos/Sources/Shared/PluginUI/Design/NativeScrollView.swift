import AppKit
import SwiftUI

/// App-owned viewports share the native narrow, rounded scroller. AppKit keeps
/// ownership of hit targets, tracking, fading, contrast and appearance changes.
@MainActor public enum NativeScrollbarStyle {
    public static func apply(to scroll: NSScrollView) {
        // Install once, before selecting the style. AppKit wires the new controls
        // to its native scrolling actions; subsequent configuration keeps them.
        if let scroller = scroll.verticalScroller, !(scroller is NativeTracklessScroller) {
            scroll.verticalScroller = NativeTracklessScroller(frame: scroller.frame)
        }
        if let scroller = scroll.horizontalScroller, !(scroller is NativeTracklessScroller) {
            scroll.horizontalScroller = NativeTracklessScroller(frame: scroller.frame)
        }
        // Respect Always/When Scrolling/Automatically and changes of input device.
        // Forcing overlay here would ignore the user's persistent-scrollbar choice.
        let style = NSScroller.preferredScrollerStyle
        if scroll.scrollerStyle != style { scroll.scrollerStyle = style }
        if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }
        for scroller in [scroll.verticalScroller, scroll.horizontalScroller].compactMap({ $0 }) {
            if scroller.controlSize != .mini { scroller.controlSize = .mini }
        }
    }
}

/// Parts-based customization preserves AppKit's independent knob fade, hover
/// expansion, mouse tracking and accessibility. Overriding draw(_:) would break
/// overlay fading (see NSScroller's overlay-compatibility contract).
@MainActor final class NativeTracklessScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}

/// Use at each owned SwiftUI viewport rather than traversing the window or
/// changing NSScrollView/NSScroller globally. Hidden indicators remain hidden.
public struct NativeScrollView<Content: View>: View {
    private let axes: Axis.Set
    private let showsIndicators: Bool
    private let content: Content

    public init(_ axes: Axis.Set = .vertical, showsIndicators: Bool = true,
                @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.showsIndicators = showsIndicators
        self.content = content()
    }

    public var body: some View {
        ScrollView(axes, showsIndicators: showsIndicators) {
            content.background(ScrollbarConfiguration().allowsHitTesting(false))
        }
    }
}

private struct ScrollbarConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollbarConfigurationView { ScrollbarConfigurationView() }
    func updateNSView(_ view: ScrollbarConfigurationView, context: Context) { view.configure() }
}

@MainActor private final class ScrollbarConfigurationView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(self, selector: #selector(configure),
            name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); configure() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }
    @objc func configure() {
        if let scroll = enclosingScrollView { NativeScrollbarStyle.apply(to: scroll) }
    }
}

/// AppKit editors and diff panes opt in without replacing their document,
/// responder chain, clipping, scroll synchronization or enabled axes.
@MainActor open class NativeStyledScrollView: NSScrollView {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(self, selector: #selector(configureScrollbars),
            name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        configureScrollbars()
    }
    public required init?(coder: NSCoder) { nil }
    open override func tile() {
        super.tile()
        NativeScrollbarStyle.apply(to: self)
    }
    open override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configureScrollbars() }
    @objc private func configureScrollbars() { NativeScrollbarStyle.apply(to: self) }
}
