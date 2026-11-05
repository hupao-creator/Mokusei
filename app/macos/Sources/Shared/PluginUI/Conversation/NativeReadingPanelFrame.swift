import AppKit
import SwiftUI

/// A noninteractive native frame anchor lets mounted replay/diagnostics measure
/// the panel rather than the union of its synthesized accessibility children.
public struct NativeReadingPanelFrame: NSViewRepresentable {
    let identifier: String
    public init(identifier: String = "agent-reading-panel") { self.identifier = identifier }
    public func makeNSView(context: Context) -> NSView {
        let view = FrameView(); view.identifier = NSUserInterfaceItemIdentifier(identifier + "-frame")
        view.setAccessibilityElement(false); return view
    }
    public func updateNSView(_ view: NSView, context: Context) {}
    private final class FrameView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
