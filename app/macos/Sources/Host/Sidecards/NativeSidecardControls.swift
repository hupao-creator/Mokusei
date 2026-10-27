import MokuseiPluginUI
import SwiftUI
import AppKit

/// One system material belongs to each card's animated subtree. Sharing a glass
/// container across independently folded cards would separate glass and content.
struct NativeSidecardGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) {}

    final class Surface: NSGlassEffectView {
        init() {
            super.init(frame: .zero)
            style = .regular
            cornerRadius = 21
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct NativeSidecardDivider: View {
    let width: CGFloat
    let maximumWidth: CGFloat
    let onWidthChange: (CGFloat) -> Void
    let onDraggingChange: (Bool) -> Void

    var body: some View {
        SidecardDividerBridge(width: width, maximumWidth: maximumWidth,
                              onWidthChange: onWidthChange, onDraggingChange: onDraggingChange)
            .frame(width: 6)
            .frame(maxHeight: .infinity)
    }
}

private struct SidecardDividerBridge: NSViewRepresentable {
    let width: CGFloat
    let maximumWidth: CGFloat
    let onWidthChange: (CGFloat) -> Void
    let onDraggingChange: (Bool) -> Void

    func makeNSView(context: Context) -> SidecardDividerView { SidecardDividerView() }

    func updateNSView(_ view: SidecardDividerView, context: Context) {
        view.width = width
        view.maximumWidth = max(320, maximumWidth)
        view.onWidthChange = onWidthChange
        view.onDraggingChange = onDraggingChange
        view.setAccessibilityValue(Int(width.rounded()))
        view.setAccessibilityMinValue(320)
        view.setAccessibilityMaxValue(Int(view.maximumWidth.rounded()))
    }

    static func dismantleNSView(_ view: SidecardDividerView, coordinator: Void) {
        view.finishDragging(deferred: true)
    }
}

private final class SidecardDividerView: NSView {
    var width: CGFloat = 320
    var maximumWidth: CGFloat = 320
    var onWidthChange: (CGFloat) -> Void = { _ in }
    var onDraggingChange: (Bool) -> Void = { _ in }
    private var dragStart: (width: CGFloat, x: CGFloat)?
    private var hovering = false
    private var hoverTracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityOrientation(.vertical)
        setAccessibilityLabel("Sidecard width")
        setAccessibilityHelp("Use Left Arrow to widen the sidecard and Right Arrow to narrow it.")
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let palette = NativeAppKitPalette.thread
        let active = hovering || dragStart != nil || window?.firstResponder === self
        guard active else { return }
        palette.accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 1, y: bounds.midY - 18, width: 2, height: 36),
                     xRadius: 1, yRadius: 1).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragStart = (width, logicalPointerX(event))
        onDraggingChange(true)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        changeWidth(dragStart.width - (logicalPointerX(event) - dragStart.x))
    }

    override func mouseUp(with event: NSEvent) {
        if let dragStart {
            changeWidth(dragStart.width - (logicalPointerX(event) - dragStart.x))
        }
        finishDragging()
    }

    private func logicalPointerX(_ event: NSEvent) -> CGFloat {
        var ancestor = superview
        while let view = ancestor {
            if view.identifier?.rawValue == "mokusei-native-content-viewport" {
                return view.convert(event.locationInWindow, from: nil).x
            }
            ancestor = view.superview
        }
        // The divider itself moves during resize, so its local coordinate
        // system cannot be used to measure a drag from the original position.
        return window?.contentView?.convert(event.locationInWindow, from: nil).x ?? event.locationInWindow.x
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { finishDragging(deferred: true) }
        super.viewWillMove(toWindow: newWindow)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: changeWidth(width + 24)
        case 124: changeWidth(width - 24)
        case 53 where dragStart != nil: finishDragging()
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformIncrement() -> Bool { changeWidth(width + 24); return true }
    override func accessibilityPerformDecrement() -> Bool { changeWidth(width - 24); return true }

    func finishDragging(deferred: Bool = false) {
        guard dragStart != nil else { return }
        dragStart = nil
        if deferred {
            let callback = onDraggingChange
            Task { @MainActor in callback(false) }
        } else { onDraggingChange(false) }
        needsDisplay = true
    }

    private func changeWidth(_ proposedWidth: CGFloat) {
        let nextWidth = min(max(320, proposedWidth), max(320, maximumWidth))
        guard nextWidth != width else { return }
        width = nextWidth
        setAccessibilityValue(Int(nextWidth.rounded()))
        onWidthChange(nextWidth)
    }
}

/// Use as the full-size background of the selected sidecard's content.
struct NativeSidecardContentFocus: NSViewRepresentable {
    let request: Int
    let enabled: Bool

    func makeNSView(context: Context) -> SidecardContentFocusView { SidecardContentFocusView() }

    func updateNSView(_ view: SidecardContentFocusView, context: Context) {
        view.update(request: request, enabled: enabled)
    }
}

final class SidecardContentFocusView: NSView {
    private var request = 0
    private var enabled = false
    private var pending = false
    private var focusScheduled = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    func update(request: Int, enabled: Bool) {
        let changed = self.request != request
        self.request = request
        self.enabled = enabled
        if changed { pending = true }
        if !enabled { return }
        scheduleFocus()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleFocus()
    }

    override func layout() {
        super.layout()
        scheduleFocus()
    }

    private func scheduleFocus() {
        guard pending, enabled, !focusScheduled, window != nil, !bounds.isEmpty else { return }
        focusScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusScheduled = false
            guard self.enabled, self.pending else { return }
            self.focusContent()
        }
    }

    private func focusContent() {
        guard let window, let root = window.contentView, !bounds.isEmpty else { return }
        // One attempt after valid layout consumes the request. A missing or
        // refusing control must not cause a fresh window scan on every layout.
        pending = false
        // SwiftUI backgrounds need not own their content's AppKit subtree, so
        // restrict the search to controls visibly contained by this marker.
        let scope = convert(bounds, to: root).insetBy(dx: -1, dy: -1)
        if let focused = window.firstResponder as? NSView,
           !focused.visibleRect.isEmpty, scope.contains(focused.convert(focused.visibleRect, to: root)) {
            return
        }
        func focus(in view: NSView) -> Bool {
            guard !view.isHiddenOrHasHiddenAncestor else { return false }
            let visible = view.convert(view.visibleRect, to: root)
            guard !visible.isEmpty, scope.intersects(visible) else { return false }
            let eligible = view !== self && view.window === window && view.canBecomeKeyView
                && (view as? NSControl)?.isEnabled != false && scope.contains(visible)
            if eligible, window.makeFirstResponder(view) { return true }
            for child in view.subviews where focus(in: child) { return true }
            return false
        }
        _ = focus(in: root)
    }
}
