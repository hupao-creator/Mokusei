// Historical contour comparison only; production Arc lives in MokuseiUI.
import AppKit
import CoreText
import MokuseiPluginUI
import SwiftUI

/// Accepted native study: equal arc-length travel around the capsule, retaining
/// the resident reader's tangent orientation (including the inverted bottom).
struct ThinkingCapsuleReasoningTrack {
    static let margin: CGFloat = 32
    let body: CGRect
    var radius: CGFloat { body.height / 2 + 19 }
    var straight: CGFloat { max(0, body.width - body.height) }
    var length: CGFloat { 2 * straight + 2 * .pi * radius }

    static func dockFrame(_ frame: CGRect, viewport: CGRect, reasoning: Bool) -> CGRect {
        guard reasoning else { return frame }
        // Reserve the external ink below Historical, including in short/clipped seats.
        let lift = max(0, margin - (viewport.maxY - frame.maxY))
        return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: max(0, frame.height - lift))
    }

    func sample(_ distance: CGFloat) -> (point: CGPoint, angle: CGFloat) {
        guard body.width >= body.height, body.height > 0 else { return (CGPoint(x: body.midX, y: body.midY), 0) }
        let s = (distance.truncatingRemainder(dividingBy: length) + length).truncatingRemainder(dividingBy: length)
        let left = body.minX + body.height / 2, right = body.maxX - body.height / 2
        if s < straight { return (CGPoint(x: left + s, y: body.midY - radius), 0) }
        if s < straight + .pi * radius {
            let angle = -.pi / 2 + (s - straight) / radius
            return (CGPoint(x: right + cos(angle) * radius, y: body.midY + sin(angle) * radius), angle + .pi / 2)
        }
        if s < 2 * straight + .pi * radius {
            return (CGPoint(x: right - (s - straight - .pi * radius), y: body.midY + radius), .pi)
        }
        let angle = .pi / 2 + (s - 2 * straight - .pi * radius) / radius
        return (CGPoint(x: left + cos(angle) * radius, y: body.midY + sin(angle) * radius), angle + .pi / 2)
    }
}

@MainActor private enum ThinkingReasoningType {
    static let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    @MainActor final class Line {
        let value: CTLine
        let width: Double
        init(_ value: String) {
            self.value = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [
                .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
            ]))
            width = CTLineGetTypographicBounds(self.value, nil, nil, nil)
        }
    }
    static let cache: NSCache<NSString, Line> = {
        let cache = NSCache<NSString, Line>(); cache.countLimit = 512; return cache
    }()
    static func line(_ value: String) -> Line {
        let key = value as NSString
        if let line = cache.object(forKey: key) { return line }
        let line = Line(value); cache.setObject(line, forKey: key); return line
    }
    static func measure(_ value: String) -> Double { line(value).width }
}

/// No observable state or source mutation at paint/layout time. Execution/segment
/// replacement and terminal/no-content states discard the old reader atomically.
@MainActor struct ThinkingCapsuleReasoningAnimation {
    private(set) var content: HistoricalReasoningContent?
    private(set) var phase = 0.0
    private(set) var clock = 0.0
    private var length = 0.0
    private var reader = HistoricalResidentText()
    var glyphs: [HistoricalResidentGlyph] { reader.visible(now: clock) }

    mutating func configure(_ next: HistoricalReasoningContent?, length: Double) {
        let next = next.flatMap { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        guard content != next || self.length != length else { return }
        if content?.segmentKey != next?.segmentKey || next == nil {
            reader = HistoricalResidentText(); clock = 0; phase = 0
        }
        content = next; self.length = length
        guard let next, length > 0 else { return }
        reader.update(text: next.text, sourceText: next.sourceText, sourceOffset: next.sourceOffset,
            segmentKey: next.segmentKey, mode: .soft, length: length, now: clock,
            measure: ThinkingReasoningType.measure)
    }

    mutating func advance(milliseconds: Double) {
        guard content != nil else { return }
        let dt = max(0, min(64, milliseconds))
        clock += dt
        // Same direction as the FIFO's source-position advance. Appends do not
        // reverse the continuous flow or restart the phase.
        phase = (phase - 26 * dt / 1000).truncatingRemainder(dividingBy: max(1, length + 34))
        reader.advance(dt: dt, now: clock, measure: ThinkingReasoningType.measure)
    }
}

struct ThinkingCapsuleReasoning: NSViewRepresentable {
    var content: HistoricalReasoningContent?
    var presenting: Bool
    var motion = true
    var capsuleSize = CGSize(width: 168, height: 44)
    @Environment(\.colorScheme) private var colorScheme
    func makeNSView(context: Context) -> ThinkingCapsuleReasoningCanvas { ThinkingCapsuleReasoningCanvas() }
    func updateNSView(_ view: ThinkingCapsuleReasoningCanvas, context: Context) {
        view.configure(content: presenting ? content : nil, dark: colorScheme == .dark, motion: motion, capsuleSize: capsuleSize)
    }
    static func dismantleNSView(_ view: ThinkingCapsuleReasoningCanvas, coordinator: ()) { view.stop() }
}

@MainActor final class ThinkingCapsuleReasoningCanvas: NSView {
    private(set) var animation = ThinkingCapsuleReasoningAnimation()
    private var content: HistoricalReasoningContent?
    private var dark = false
    private var active = false
    private var motion = true
    private var capsuleSize = CGSize(width: 168, height: 44)
    private var stopped = false
    private var lastWall = ProcessInfo.processInfo.systemUptime
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    var hasScheduledFrame: Bool { timer != nil }
    var track: ThinkingCapsuleReasoningTrack {
        .init(body: CGRect(x: bounds.midX - capsuleSize.width / 2, y: bounds.midY - capsuleSize.height / 2,
                          width: capsuleSize.width, height: capsuleSize.height))
    }
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

    func configure(content: HistoricalReasoningContent?, dark: Bool, motion: Bool = true, capsuleSize: CGSize = CGSize(width: 168, height: 44)) {
        guard !stopped else { return }
        self.content = content; self.dark = dark; self.motion = motion; self.capsuleSize = capsuleSize
        configureReader(); updateVisibility(); needsDisplay = true
    }
    private func configureReader() {
        let valid = track.body.width >= track.body.height && track.body.height > 0
        animation.configure(valid ? content : nil, length: max(0, track.length - 34))
    }
    override func layout() { super.layout(); configureReader() }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize); configureReader(); updateVisibility(); needsDisplay = true
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
        configureReader(); updateVisibility()
    }
    override func viewDidHide() { super.viewDidHide(); updateVisibility() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateVisibility() }
    func updateVisibility() {
        let visible = !stopped && motion && animation.content != nil && !isHiddenOrHasHiddenAncestor && !bounds.isEmpty
            && window?.isMiniaturized == false && window?.occlusionState.contains(.visible) == true
        guard visible != active else { return }
        active = visible; lastWall = ProcessInfo.processInfo.systemUptime
        timer?.invalidate(); timer = nil
        if active { schedule() }
    }
    func stop() {
        stopped = true; active = false; content = nil
        animation.configure(nil, length: 0)
        timer?.invalidate(); timer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []; needsDisplay = true
    }
    private func schedule() {
        guard active, timer == nil else { return }
        let timer = Timer(timeInterval: NativeFrameRate.interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timer = nil; self.updateVisibility()
                guard self.active else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.animation.advance(milliseconds: (now - self.lastWall) * 1000); self.lastWall = now
                self.needsDisplay = true; self.schedule()
            }
        }
        timer.tolerance = 0.001
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard animation.content != nil, let cg = NSGraphicsContext.current?.cgContext else { return }
        let ink = dark ? NSColor(srgbRed: 0.71, green: 0.77, blue: 0.66, alpha: 1)
                       : NSColor(srgbRed: 0.30, green: 0.365, blue: 0.27, alpha: 1)
        cg.setFillColor(ink.cgColor)
        for glyph in animation.glyphs {
            let sample = track.sample(glyph.position * (track.length - 34) + animation.phase)
            let line = ThinkingReasoningType.line(glyph.value)
            cg.saveGState(); cg.translateBy(x: sample.point.x, y: sample.point.y); cg.rotate(by: sample.angle)
            cg.scaleBy(x: 1, y: -1); cg.textMatrix = .identity
            cg.setAlpha(glyph.opacity * 0.92)
            cg.textPosition = CGPoint(x: -line.width / 2,
                y: -(ThinkingReasoningType.font.ascender + ThinkingReasoningType.font.descender) / 2)
            CTLineDraw(line.value, cg); cg.restoreGState()
        }
    }
}
