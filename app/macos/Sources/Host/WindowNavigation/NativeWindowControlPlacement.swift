import AppKit
import SwiftUI

/// Deliberate AppKit exception: SwiftUI does not expose placement of the real
/// window controls. Their placement is in window points and follows reading offsets.
struct NativeWindowControlPlacement: NSViewRepresentable {
    // Window layout and reading animation must use the same offset; otherwise
    // a deferred toolbar placement can put collapsed controls back on screen.
    private static let readingOffsets = NSMapTable<NSWindow, NSNumber>.weakToStrongObjects()
    private static let placements = NSMapTable<NSWindow, PlacementView>.weakToWeakObjects()

    static func setReadingOffset(_ offset: CGFloat, in window: NSWindow) {
        if offset == 0 { readingOffsets.removeObject(forKey: window) }
        else { readingOffsets.setObject(NSNumber(value: Double(offset)), forKey: window) }
        placeControls(in: window)
    }

    private static func placeControls(in window: NSWindow) {
        guard let content = window.contentView, let placement = placements.object(forKey: window) else { return }
        guard !window.styleMask.contains(.fullScreen) else {
            placement.hideBackdrop()
            return
        }
        let offset = CGFloat(readingOffsets.object(forKey: window)?.doubleValue ?? 0)
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated().compactMap { index, type in
            window.standardWindowButton(type).map { (index, $0) }
        }
        let hidden = offset <= NativeWindowNavigationGeometry.hiddenOffset
        // Visibility changes can reposition siblings. Finish that layout before
        // applying coordinates to the entire group, including on reveal.
        for (_, button) in buttons where button.isHidden != hidden { button.isHidden = hidden }
        for (_, button) in buttons { button.superview?.layoutSubtreeIfNeeded() }
        let top = NativeWindowNavigationGeometry.nativeButtonTop + offset
        for (index, button) in buttons {
            guard let parent = button.superview else { continue }
            let height = button.frame.height
            let y = content.isFlipped ? content.bounds.minY + top : content.bounds.maxY - top - height
            let rect = CGRect(x: NativeWindowNavigationGeometry.nativeButtonLeft + CGFloat(index * 20),
                              y: y, width: button.frame.width, height: button.frame.height)
            let origin = content.convert(rect, to: parent).origin
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
        placement.placeBackdrop(buttons: buttons.map { $0.1 }, hidden: hidden)
    }

    func makeNSView(context: Context) -> PlacementView { PlacementView() }
    func updateNSView(_ view: PlacementView, context: Context) {
        view.schedulePlacement()
    }
    static func dismantleNSView(_ view: PlacementView, coordinator: ()) { view.detach() }

    final class PlacementView: NSView {
        private var placementPending = false
        private var attached = false
        private weak var observedWindow: NSWindow?
        private let backdrop = WindowControlBackdrop()
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
            observedWindow = window
            NativeWindowControlPlacement.placements.setObject(self, forKey: window)
            for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                         NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
                         NSWindow.didExitFullScreenNotification, NSWindow.didChangeScreenNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged), name: name, object: window)
            }
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(windowChanged),
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
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
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            if let observedWindow, NativeWindowControlPlacement.placements.object(forKey: observedWindow) === self {
                NativeWindowControlPlacement.placements.removeObject(forKey: observedWindow)
            }
            observedWindow = nil
            backdrop.removeFromSuperview()
            backdrop.buttons = []
            for observed in observedButtons { observed.button?.postsFrameChangedNotifications = observed.postedFrameChanges }
            observedButtons = []
        }

        @objc private func windowChanged(_ notification: Notification) {
            if notification.name == NSWindow.willEnterFullScreenNotification {
                hideBackdrop()
            } else {
                schedulePlacement()
            }
        }

        fileprivate func hideBackdrop() { backdrop.isHidden = true }

        fileprivate func placeBackdrop(buttons: [NSButton], hidden: Bool) {
            guard !buttons.isEmpty, let content = window?.contentView, let parent = content.superview else {
                backdrop.removeFromSuperview()
                return
            }
            // The native titlebar can be shorter than the visible button row. Its
            // background sits above content to route hits past that ancestor's bounds.
            if backdrop.superview !== parent {
                parent.addSubview(backdrop, positioned: .above, relativeTo: content)
            }
            backdrop.buttons = buttons
            let group = buttons.reduce(CGRect.null) { $0.union($1.convert($1.bounds, to: parent)) }
            let verticalPadding = (NativeWindowNavigationGeometry.height - group.height) / 2
            backdrop.frame = group.insetBy(dx: -12, dy: -verticalPadding)
            backdrop.isHidden = hidden || buttons.allSatisfy(\.isHidden)
            backdrop.updateMaterial()
        }

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

/// The original AppKit buttons retain their actions, accessibility and grouped hover.
private final class WindowControlBackdrop: NSView {
    var buttons: [NSButton] = []
    private let glass = NSGlassEffectView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityHidden(true)
        // AppKit exposes real clear glass on the package's macOS 26 minimum.
        // Keep this untinted; regular glass and translucent fills are different materials.
        glass.style = .clear
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
    }
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point), let superview else { return nil }
        for button in buttons where !button.isHiddenOrHasHiddenAncestor {
            if let parent = button.superview,
               let hit = button.hitTest(parent.convert(point, from: superview)) { return hit }
        }
        // Pass the empty capsule padding through to the workspace's drag gesture.
        return nil
    }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        glass.frame = bounds
        updateMaterial()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateMaterial()
    }

    func updateMaterial() {
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        glass.isHidden = opaque
        glass.cornerRadius = bounds.height / 2
        layer?.cornerRadius = bounds.height / 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = opaque ? NSColor.windowBackgroundColor.cgColor : nil
        }
    }
}
