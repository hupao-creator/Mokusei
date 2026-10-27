import AppKit
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import WebKit
@testable import MokuseiUI

@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeHTMLGeometryTests {
    @Test func documentInheritsAncestorScrollAndStableTrackingIsReused() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 30, y: 30, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: .init(x: 0, y: 0, width: 600, height: 400))
        let ancestor = NSView(frame: .init(x: 10, y: 20, width: 500, height: 350))
        let container = HTMLDocumentContainer(frame: .init(x: 50, y: 40, width: 300, height: 200))
        root.addSubview(ancestor); ancestor.addSubview(container)
        window.contentView = root
        let document = WKWebView()
        container.documentView = document
        window.orderFront(nil); root.layoutSubtreeIfNeeded()
        defer { container.releaseDocument(); window.close() }
        let portal = try #require(container.subviews.first { $0.identifier?.rawValue == "mokusei-report-document-portal" })
        func expected() -> CGRect {
            container.bounds
        }
        #expect(portal.frame == expected())
        ancestor.bounds.origin.y = 30
        // The document inherits ancestor transforms without a separate window overlay.
        #expect(portal.frame == expected())
        #expect(document.frame == portal.bounds)
        #expect(portal.convert(portal.bounds, to: root) == container.convert(container.bounds, to: root))
        container.updateTrackingAreas()
        let tracking = try #require(container.trackingAreas.first)
        container.updateTrackingAreas()
        #expect(container.trackingAreas.count == 1 && container.trackingAreas.first === tracking)
        container.suppressed = true
        #expect(portal.superview == nil && document.superview == nil)
        container.suppressed = false
        #expect(portal.superview === container && portal.frame == expected())
        container.removeFromSuperview()
        #expect(portal.superview == nil)
    }
}
