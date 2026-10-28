import AppKit
import SwiftUI
import Testing

/// AppKit is used by the test runner to host real SwiftUI, never by the production scene.
@MainActor enum SwiftUIReplay {
    /// `NSApp` is nil until something touches `NSApplication.shared`; window-less
    /// tests (draft-only) never do. The test runner owns that initialization so
    /// replayed AppKit surfaces and plain draft tests share one safe entry point.
    private static var app: NSApplication { NSApp ?? NSApplication.shared }
    private static var reportedEnvironment = false

    static func window<Content: View>(_ content: Content, width: CGFloat = 1180, height: CGFloat = 780, offscreen: Bool = false) -> NSWindow {
        let sharedApp = app
        sharedApp.setActivationPolicy(.regular)
        sharedApp.unhide(nil)
        sharedApp.activate(ignoringOtherApps: true)
        let window = ReplayWindow(contentRect: .init(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if !reportedEnvironment {
            print("NATIVE ENVIRONMENT systemReduceMotion=\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) backingScale=\(window.backingScaleFactor) screens=\(NSScreen.screens.map(\.frame))")
            reportedEnvironment = true
        }
        let host = NSHostingView(rootView: content.frame(width: width, height: height).accessibilityElement(children: .contain))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.contentView = host
        window.allowsOffscreenPlacement = offscreen
        if offscreen {
            window.setFrameOrigin(CGPoint(x: 0, y: (NSScreen.screens.map { $0.frame.maxY }.max() ?? 1000) + 100))
        }
        window.makeKeyAndOrderFront(nil)
        return window
    }
    static func wait(timeout: Duration = .seconds(3), _ predicate: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + timeout
        var settled = false
        while ContinuousClock.now < deadline {
            // Model-only callers must not initialize AppKit in a headless run.
            for window in NSApp?.windows ?? [] { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
            settled = predicate()
            if settled { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        // A timeout is one failed expectation, not a second cancellation issue.
        try #require(settled, "SwiftUI presentation did not settle within \(timeout); AppKit running: \(NSApp?.isRunning == true), visible windows: \(NSApp?.windows.filter(\.isVisible).count ?? 0)", sourceLocation: sourceLocation)
    }
    static func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap { textField(in: $0) }.first
    }
    static func editor(in view: NSView) -> NSTextView? {
        if let field = view as? NSTextField, field.isEditable, let window = field.window {
            if let editor = field.currentEditor() as? NSTextView { return editor }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(field)
            return field.currentEditor() as? NSTextView
        }
        if let text = view as? NSTextView, text.isEditable {
            if let window = text.window, window.firstResponder !== text {
                window.makeKeyAndOrderFront(nil); window.makeFirstResponder(text)
            }
            return text
        }
        return view.subviews.lazy.compactMap { editor(in: $0) }.first
    }
    static func text(in root: NSView) -> Set<String> {
        var found = Set<String>(), seen = Set<ObjectIdentifier>()
        func visit(_ object: AnyObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted, seen.count < 10000,
                  let element = object as? NSObject else { return }
            for key in ["accessibilityLabel", "accessibilityValue"] {
                let selector = NSSelectorFromString(key)
                if element.responds(to: selector), let text = element.perform(selector)?.takeUnretainedValue() as? String { found.insert(text) }
            }
            let selector = NSSelectorFromString("accessibilityChildren")
            if element.responds(to: selector), let children = element.perform(selector)?.takeUnretainedValue() as? [AnyObject] {
                children.forEach(visit)
            }
            if let view = element as? NSView { view.subviews.forEach(visit) }
        }
        if let window = root.window { _ = window.accessibilityChildren() }
        visit(root)
        return found
    }
}

/// AX and direct input snapshots must not race real pointer hover. AppKit
/// otherwise constrains a newly shown window back onto a physical screen.
@MainActor private final class ReplayWindow: NSWindow {
    var allowsOffscreenPlacement = false
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsOffscreenPlacement ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}
