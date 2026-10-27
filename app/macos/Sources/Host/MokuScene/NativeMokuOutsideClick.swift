import MokuseiPluginUI
import SwiftUI
import AppKit

/// Views that must count as inside even though they live outside the Dock,
/// such as the Overview's Return to Automatic View control.
@MainActor public final class NativeClickExclusions {
    private let views = NSHashTable<NativePlatformView>.weakObjects()

    public init() {}
    public func add(_ view: NativePlatformView) { views.add(view) }
    var registeredCount: Int { views.allObjects.count }
    func windowFrames(in window: NativePlatformWindow) -> [CGRect] {
        views.allObjects.compactMap { view in
            guard view.window === window else { return nil }
            return view.convert(view.bounds, to: nil)
        }
    }

    public func contains(_ point: CGPoint, in window: NativePlatformWindow) -> Bool {
        views.allObjects.contains { view in
            guard view.window === window, !view.isHiddenOrHasHiddenAncestor else { return false }
            return view.bounds.contains(view.convert(point, from: nil))
        }
    }
}

/// Registers the trimmed region without adding a hit target.
struct NativeClickExclusionRegion: NSViewRepresentable {
    let exclusions: NativeClickExclusions

    func makeNSView(context: Context) -> RegionView {
        let view = RegionView()
        view.exclusions = exclusions
        return view
    }

    func updateNSView(_ view: RegionView, context: Context) { view.exclusions = exclusions }

    @MainActor final class RegionView: NSView {
        var exclusions: NativeClickExclusions?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, let exclusions { exclusions.add(self) }
        }
    }
}

/// Boundary for the Dock's outside-click dismissal. Coordinates are local
/// to the Dock's flipped scene, so they match the frames it publishes for the
/// capsule, composer and interaction panel.
enum NativeMokuOutsideClick {
    static func isInside(point: CGPoint, dockRects: [CGRect]) -> Bool {
        guard point.x.isFinite, point.y.isFinite else { return true }
        // The Dock publishes these during layout. Until it has, never turn a
        // missing frame into a dismissal of the user's open composer.
        guard !dockRects.isEmpty else { return true }
        return dockRects.contains { $0.contains(point) }
    }
}

/// Observes clicks without consuming them. A full-window SwiftUI overlay would
/// make thread cards and chrome controls unclickable while the composer is
/// open; the local monitor leaves the original event on its normal path.
/// Talk also observes other windows/apps. The global observer cannot consume
/// events and exists only while that dismissal callback is installed.
struct NativeMokuOutsideClickMonitor: NSViewRepresentable {
    var exclusions: NativeClickExclusions
    var beginClick: () -> Void
    var isActive: () -> Bool
    var usesExclusions = true
    var outsideWindowClick: (() -> Void)? = nil
    var isInside: (CGPoint) -> Bool
    var click: (CGPoint) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.update(exclusions: exclusions, beginClick: beginClick, isActive: isActive,
                    usesExclusions: usesExclusions, outsideWindowClick: outsideWindowClick,
                    isInside: isInside, click: click)
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.update(exclusions: exclusions, beginClick: beginClick, isActive: isActive,
                    usesExclusions: usesExclusions, outsideWindowClick: outsideWindowClick,
                    isInside: isInside, click: click)
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    @MainActor final class MonitorView: NSView {
        private var monitor: Any?
        private var globalMonitor: Any?
        private var usesExclusions = true
        private var outsideWindowClick: (() -> Void)?
        private var exclusions = NativeClickExclusions()
        private var beginClick: () -> Void = {}
        private var isActive: () -> Bool = { false }
        private var isInside: (CGPoint) -> Bool = { _ in true }
        private var click: (CGPoint) -> Void = { _ in }

        // Match the flipped SwiftUI scene rather than AppKit's bottom-left origin.
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func update(exclusions: NativeClickExclusions, beginClick: @escaping () -> Void,
                    isActive: @escaping () -> Bool, usesExclusions: Bool,
                    outsideWindowClick: (() -> Void)?, isInside: @escaping (CGPoint) -> Bool,
                    click: @escaping (CGPoint) -> Void) {
            self.exclusions = exclusions; self.beginClick = beginClick; self.isActive = isActive
            self.isInside = isInside; self.click = click
            self.usesExclusions = usesExclusions; self.outsideWindowClick = outsideWindowClick
            syncGlobalMonitor()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window,
                          !self.isHiddenOrHasHiddenAncestor else { return }
                    guard event.window === window else {
                        self.clickOutsideWindow()
                        return
                    }
                    // A mark only covers the press that created it. Clear any
                    // earlier one before deciding whether this press dismisses.
                    self.beginClick()
                    guard self.isActive() else { return }
                    let point = self.convert(event.locationInWindow, from: nil)
                    guard !self.isInside(point) else { return }
                    guard !self.usesExclusions || !self.exclusions.contains(event.locationInWindow, in: window) else { return }
                    self.click(point)
                }
                return event
            }
            syncGlobalMonitor()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { stop() }
            super.viewWillMove(toWindow: newWindow)
        }

        private func clickOutsideWindow() {
            guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor, isActive() else { return }
            outsideWindowClick?()
        }

        private func syncGlobalMonitor() {
            guard window != nil, outsideWindowClick != nil else {
                if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
                return
            }
            guard globalMonitor == nil else { return }
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.clickOutsideWindow() }
            }
        }

        func stop() {
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }
    }
}
