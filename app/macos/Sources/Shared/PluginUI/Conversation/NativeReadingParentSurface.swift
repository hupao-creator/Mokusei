import AppKit
import SwiftUI

/// A settled reading panel needs the parent's appearance, not its live window
/// subtree. Keep the SwiftUI owner mounted, but hide its native host behind one
/// image until return preparation resumes the latest parent layout.
struct NativeReadingParentSurface<Content: View>: NSViewRepresentable {
    let frozen: Bool
    let content: Content

    func makeNSView(context: Context) -> NativeReadingParentView { NativeReadingParentView() }
    func updateNSView(_ view: NativeReadingParentView, context: Context) {
        view.update(content: AnyView(content.environment(\.self, context.environment)), frozen: frozen)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeReadingParentView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
    static func dismantleNSView(_ view: NativeReadingParentView, coordinator: ()) { view.retire() }
}

@MainActor final class NativeReadingParentView: NSView {
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    private let still = NSImageView()
    private var freezeRequested = false
    private var captureTask: Task<Void, Never>?
    private var generation = 0

    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hosting.sizingOptions = []
        // The workspace already supplies full-content bounds. A nested host
        // must not inset and clip its canvas again below the window titlebar.
        hosting.safeAreaRegions = []
        still.imageScaling = .scaleAxesIndependently
        still.isHidden = true
        still.setAccessibilityElement(false)
        addSubview(hosting)
        addSubview(still)
    }
    required init?(coder: NSCoder) { nil }

    func update(content: AnyView, frozen: Bool) {
        freezeRequested = frozen
        if !frozen {
            generation += 1
            captureTask?.cancel(); captureTask = nil
            hosting.rootView = content
            hosting.frame = bounds
            hosting.isHidden = false
            still.isHidden = true; still.image = nil
        } else if !hosting.isHidden {
            hosting.rootView = content
            scheduleCapture()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { scheduleCapture() }
    }
    override func layout() {
        super.layout()
        still.frame = bounds
        // Resizing a frozen backdrop stretches only the cached appearance.
        // The real host adopts the current viewport before return's receipt.
        if !hosting.isHidden { hosting.frame = bounds }
        scheduleCapture()
    }
    private func scheduleCapture() {
        guard freezeRequested, !hosting.isHidden, captureTask == nil,
              window != nil, bounds.width > 0, bounds.height > 0 else { return }
        let token = generation
        captureTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            defer { if generation == token { captureTask = nil } }
            guard !Task.isCancelled, generation == token, freezeRequested, window != nil else { return }
            hosting.frame = bounds
            hosting.layoutSubtreeIfNeeded()
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let image = NSImage(size: hosting.bounds.size)
            image.addRepresentation(bitmap)
            still.image = image; still.frame = bounds; still.isHidden = false
            hosting.isHidden = true
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        freezeRequested ? nil : super.hitTest(point)
    }
    override func accessibilityChildren() -> [Any]? {
        freezeRequested ? [] : super.accessibilityChildren()
    }
    func retire() {
        generation += 1
        captureTask?.cancel(); captureTask = nil
        still.image = nil
        hosting.rootView = AnyView(EmptyView())
    }
}
