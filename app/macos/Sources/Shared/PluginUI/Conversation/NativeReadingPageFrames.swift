import AppKit
import QuartzCore
import SwiftUI

/// The stack owns progress and navigation; this object only delivers display
/// callbacks. Its separate request generation also fences preparation that is
/// still asleep when SwiftUI dismantles the native anchor.
@MainActor final class NativeReadingPageFrames: NSObject {
    private weak var anchor: NativeReadingPageFrameView?
    private weak var screen: NSScreen?
    private var link: CADisplayLink?
    private var generation = 0
    private var onFrame: (@MainActor () -> Void)?

    func begin() -> Int {
        stop()
        return generation
    }

    func start(generation expected: Int, onFrame: @escaping @MainActor () -> Void) {
        guard generation == expected else { return }
        self.onFrame = onFrame
        windowChanged()
    }

    func stop() {
        generation += 1
        onFrame = nil
        invalidateLink()
    }

    fileprivate func attach(_ view: NativeReadingPageFrameView) {
        guard anchor !== view else { return }
        view.owner?.detach(view)
        anchor?.owner = nil
        invalidateLink()
        anchor = view
        view.owner = self
        windowChanged()
    }

    fileprivate func detach(_ view: NativeReadingPageFrameView) {
        guard anchor === view else { return }
        stop()
        anchor = nil
        view.owner = nil
    }

    fileprivate func windowChanged() {
        guard onFrame != nil, let window = anchor?.window,
              let nextScreen = window.screen ?? NSScreen.main ?? NSScreen.screens.first else {
            // An unmounted request remains cancellable. Do not synthesize frames
            // or complete navigation while no window can receive the motion.
            invalidateLink()
            return
        }
        guard link == nil || screen !== nextScreen else { return }
        invalidateLink()
        screen = nextScreen
        // A screen clock also serves a real window positioned offscreen; a
        // view/window clock would pause there. Moving screens rebinds this link.
        let next = nextScreen.displayLink(target: self, selector: #selector(displayFrame(_:)))
        link = next
        next.add(to: .main, forMode: .common)
    }

    private func invalidateLink() {
        link?.invalidate()
        link = nil
        screen = nil
    }

    @objc private func displayFrame(_ sender: CADisplayLink) {
        guard sender === link else { return }
        // Stay inside this callback. An asynchronous hop would add another
        // independently scheduled producer between the display and progress.
        onFrame?()
    }
}

struct NativeReadingPageFrameSource: NSViewRepresentable {
    let frames: NativeReadingPageFrames
    func makeNSView(context: Context) -> NativeReadingPageFrameView { NativeReadingPageFrameView() }
    func updateNSView(_ view: NativeReadingPageFrameView, context: Context) { frames.attach(view) }
    static func dismantleNSView(_ view: NativeReadingPageFrameView, coordinator: ()) { view.detach() }
}

@MainActor final class NativeReadingPageFrameView: NSView {
    fileprivate weak var owner: NativeReadingPageFrames?
    private var observers: [NSObjectProtocol] = []
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }

    isolated deinit { removeObservers() }

    fileprivate func detach() {
        removeObservers()
        owner?.detach(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        if let window {
            for (name, object) in [(NSWindow.didChangeScreenNotification, window as AnyObject?),
                                   (NSApplication.didChangeScreenParametersNotification, nil)] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.owner?.windowChanged() }
                })
            }
        }
        owner?.windowChanged()
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }
}
