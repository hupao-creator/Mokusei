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
        let targets = buttons.map { $0.target as AnyObject? }
        let parents = buttons.map(\.superview)
        let labels = buttons.map { $0.accessibilityLabel() }
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
                #expect(button.target as AnyObject? === targets[index])
                #expect(button.superview === parents[index])
                #expect(button.accessibilityLabel() == labels[index])
                let frameView = try #require(content.superview)
                let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: frameView.superview)
                let hit = frameView.hitTest(point)
                #expect(hit === button || hit?.isDescendant(of: button) == true)
            }
        }

        let parent = try #require(buttons[0].superview)
        let backdrop = try #require(parent.subviews.first { view in
            view.subviews.contains { ($0 as? NSGlassEffectView)?.style == .clear }
        })
        let glass = try #require(backdrop.subviews.compactMap { $0 as? NSGlassEffectView }.first)
        #expect(glass.style == .clear && glass.tintColor == nil)
        #expect(glass.isHidden == NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
        #expect(backdrop.isAccessibilityHidden())
        #expect(!backdrop.acceptsFirstResponder && backdrop.mouseDownCanMoveWindow)
        let group = buttons.reduce(CGRect.null) { $0.union($1.convert($1.bounds, to: parent)) }
        let expectedBackdrop = CGRect(x: group.minX - 12, y: group.midY - 21, width: group.width + 24, height: 42)
        #expect(backdrop.frame == expectedBackdrop)
        #expect(backdrop.frame.height == OverviewTagMetrics.chipHeight)
        #expect(backdrop.frame.height == OverviewTagMetrics.actionDiameter)
        #expect(glass.frame == backdrop.bounds)
        #expect(glass.cornerRadius == backdrop.bounds.height / 2)
        #expect(backdrop.hitTest(backdrop.frame.origin) == nil)
        let frameView = try #require(content.superview)
        let paddingPoint = backdrop.convert(CGPoint(x: 4, y: backdrop.bounds.midY), to: frameView.superview)
        let paddingHit = frameView.hitTest(paddingPoint)
        #expect(paddingHit !== backdrop && paddingHit?.isDescendant(of: backdrop) != true)

        NativeWindowControlPlacement.setReadingOffset(-20, in: window)
        #expect(!backdrop.isHidden)
        #expect(abs(backdrop.frame.midY - group.midY - 20) < 0.5)
        NativeWindowControlPlacement.setReadingOffset(NativeWindowNavigationGeometry.hiddenOffset, in: window)
        #expect(backdrop.isHidden && buttons.allSatisfy(\.isHidden))
        NativeWindowControlPlacement.setReadingOffset(0, in: window)
        #expect(!backdrop.isHidden && buttons.allSatisfy { !$0.isHidden })
        #expect(backdrop.frame == expectedBackdrop)

        // Entry immediately hides decoration; AppKit still owns the actual
        // fullscreen transition and its standard buttons.
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        #expect(backdrop.isHidden)
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!backdrop.isHidden)

        placement.detach()
        #expect(backdrop.superview == nil)
        #expect(frameView.hitTest(paddingPoint) === paddingHit)
        buttons[0].setFrameOrigin(.zero)
        try await Task.sleep(for: .milliseconds(100))
        #expect(buttons[0].frame.origin == .zero)
    }
}
