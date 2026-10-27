import AppKit
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiUI

private final class OffscreenPlacementWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeWindowControlPlacementTests {
    @Test func nativeControlsKeepTheirPositionAndHitTargetsAfterLayout() async throws {
        _ = NSApplication.shared
        let window = OffscreenPlacementWindow(contentRect: CGRect(x: -10000, y: -10000, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "traffic-light-placement-test")
        let placement = NativeWindowControlPlacement.PlacementView()
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 1100, height: 700))
        content.addSubview(placement)
        window.contentView = content
        window.orderFront(nil)
        defer { placement.detach(); window.close() }

        let buttons = try [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map {
            try #require(window.standardWindowButton($0))
        }
        let actions = buttons.map(\.action)
        let sizes = buttons.map { $0.frame.size }
        for width in [850.0, 1300.0, 1100.0] {
            window.setFrame(CGRect(x: -10000, y: -10000, width: width, height: 700), display: true)
            // Reproduce AppKit resetting the buttons in a later toolbar layout.
            for (index, button) in buttons.enumerated() { button.setFrameOrigin(CGPoint(x: index * 23, y: 0)) }
            try await Task.sleep(for: .milliseconds(100))
            #expect(content.bounds.height >= 600)
            for (index, button) in buttons.enumerated() {
                let rect = button.convert(button.bounds, to: content)
                #expect(abs(rect.minX - CGFloat(24 + 20 * index)) < 0.5)
                #expect(abs(content.bounds.height - rect.maxY - 31) < 0.5)
                #expect(button.action == actions[index] && button.frame.size == sizes[index])
                let frameView = try #require(content.superview)
                let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: frameView.superview)
                let hit = frameView.hitTest(point)
                #expect(hit === button || hit?.isDescendant(of: button) == true)
            }
        }

        placement.detach()
        buttons[0].setFrameOrigin(.zero)
        try await Task.sleep(for: .milliseconds(100))
        #expect(buttons[0].frame.origin == .zero)
    }
}
