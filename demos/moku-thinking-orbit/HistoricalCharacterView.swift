import AppKit
import SwiftUI
import MokuseiPluginUI

struct HistoricalCharacterView: NSViewRepresentable {
    let role: HistoricalResidentRole
    let content: HistoricalReasoningContent
    let motion: Bool

    func makeNSView(context: Context) -> HistoricalCharacterCanvas { HistoricalCharacterCanvas() }
    func updateNSView(_ view: HistoricalCharacterCanvas, context: Context) {
        view.configure(role: role, content: content, motion: motion)
    }
    static func dismantleNSView(_ view: HistoricalCharacterCanvas, coordinator: ()) { view.stop() }
}

/// The study owns only the native display lifecycle. Pose, FIFO, glyph layout,
/// gaze and handoff choreography come from the recovered historical renderer.
@MainActor final class HistoricalCharacterCanvas: NSView {
    private var animation = HistoricalResidentAnimation(now: ProcessInfo.processInfo.systemUptime * 1000)
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var motion = true
    private var stopped = false
    private(set) var frameCount = 0
    var hasScheduledFrame: Bool { timer != nil }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(false)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    isolated deinit {
        timer?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(role: HistoricalResidentRole, content: HistoricalReasoningContent, motion: Bool) {
        self.motion = motion
        animation.update(role: role, scope: "thinking-history", text: content.text, toolName: "read_file",
            now: ProcessInfo.processInfo.systemUptime * 1000, active: visible,
            sourceText: content.sourceText, sourceOffset: content.sourceOffset,
            segmentKey: content.segmentKey, options: content.options)
        needsDisplay = true
        updateVisibility()
    }
    private var visible: Bool {
        !stopped && motion && !isHiddenOrHasHiddenAncestor && !bounds.isEmpty
            && window?.isMiniaturized == false && window?.occlusionState.contains(.visible) == true
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateVisibility() }
                })
            }
        }
        updateVisibility()
    }
    override func viewDidHide() { super.viewDidHide(); updateVisibility() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateVisibility() }
    private func updateVisibility() {
        timer?.invalidate(); timer = nil
        animation.advance(now: ProcessInfo.processInfo.systemUptime * 1000, active: false)
        if visible { schedule() }
    }
    func stop() {
        stopped = true; timer?.invalidate(); timer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }
    private func schedule() {
        guard visible, timer == nil else { return }
        let timer = Timer(timeInterval: NativeFrameRate.interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timer = nil
                self.animation.advance(now: ProcessInfo.processInfo.systemUptime * 1000, active: self.visible)
                self.needsDisplay = true
                self.schedule()
            }
        }
        timer.tolerance = 0.001
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        frameCount += 1
        // Convert the original 640-unit paint sink back to its 400×310 study.
        // Scale the entire reference uniformly, including text and the safe eye bounds.
        let scale = min(bounds.width / 400, bounds.height / 310)
        context.saveGState()
        context.translateBy(x: (bounds.width - 400 * scale) / 2, y: (bounds.height - 310 * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 88, y: 55)
        context.scaleBy(x: 0.35, y: 0.35)
        animation.paint(in: context)
        context.restoreGState()
    }
}
