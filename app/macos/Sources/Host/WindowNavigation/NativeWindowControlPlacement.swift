import AppKit
import SwiftUI

/// Deliberate AppKit exception: SwiftUI does not expose placement of the real
/// window controls. This bridge owns their historical coordinates and reading offset.
struct NativeWindowControlPlacement: NSViewRepresentable {
    // Window layout and reading animation must use the same offset; otherwise
    // a deferred toolbar placement can put collapsed controls back on screen.
    private static let readingOffsets = NSMapTable<NSWindow, NSNumber>.weakToStrongObjects()

    static func setReadingOffset(_ offset: CGFloat, in window: NSWindow) {
        if offset == 0 { readingOffsets.removeObject(forKey: window) }
        else { readingOffsets.setObject(NSNumber(value: Double(offset)), forKey: window) }
        placeControls(in: window)
    }

    private static func placeControls(in window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen), let content = window.contentView else { return }
        let offset = CGFloat(readingOffsets.object(forKey: window)?.doubleValue ?? 0)
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated().compactMap { index, type in
            window.standardWindowButton(type).map { (index, $0) }
        }
        let hidden = offset <= NativeWindowNavigationGeometry.hiddenOffset
        // Visibility changes can reposition siblings. Finish that layout before
        // applying coordinates to the entire group, including on reveal.
        for (_, button) in buttons where button.isHidden != hidden { button.isHidden = hidden }
        for (_, button) in buttons { button.superview?.layoutSubtreeIfNeeded() }
        for (index, button) in buttons {
            guard let parent = button.superview else { continue }
            let top = NativeWindowNavigationGeometry.nativeButtonTop + offset
            let y = content.isFlipped ? top : content.bounds.height - top - button.frame.height
            let rect = CGRect(x: NativeWindowNavigationGeometry.nativeButtonLeft + CGFloat(index * 20),
                              y: y, width: button.frame.width, height: button.frame.height)
            let origin = content.convert(rect, to: parent).origin
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }

    func makeNSView(context: Context) -> PlacementView { PlacementView() }
    func updateNSView(_ view: PlacementView, context: Context) { view.schedulePlacement() }
    static func dismantleNSView(_ view: PlacementView, coordinator: ()) { view.detach() }

    final class PlacementView: NSView {
        private var placementPending = false
        private var attached = false
        private struct ObservedButton {
            weak var button: NSButton?
            let postedFrameChanges: Bool
        }
        private var observedButtons: [ObservedButton] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard let window else { return }
            attached = true
            for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                         NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.didExitFullScreenNotification, NSWindow.didChangeScreenNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged), name: name, object: window)
            }
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(type) else { continue }
                observedButtons.append(.init(button: button, postedFrameChanges: button.postsFrameChangedNotifications))
                button.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged),
                    name: NSView.frameDidChangeNotification, object: button)
            }
            schedulePlacement()
        }

        override func layout() {
            super.layout()
            schedulePlacement()
        }

        func detach() {
            attached = false
            NotificationCenter.default.removeObserver(self)
            for observed in observedButtons { observed.button?.postsFrameChangedNotifications = observed.postedFrameChanges }
            observedButtons = []
        }

        @objc private func windowChanged(_ notification: Notification) { schedulePlacement() }

        func schedulePlacement() {
            guard attached, !placementPending else { return }
            placementPending = true
            // AppKit can reset these frames during toolbar/window layout.
            // Apply after that layout, coalescing resize and SwiftUI updates.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.placementPending = false
                self.placeControls()
            }
        }

        private func placeControls() {
            guard attached, let window else { return }
            NativeWindowControlPlacement.placeControls(in: window)
        }
    }
}
