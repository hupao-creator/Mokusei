import AppKit
import QuartzCore
import SwiftUI

/// Semantic targets and source admission are separate. Covering a live thinking
/// segment retires its painted glyphs without making a hidden reader consume text.
struct NativeMokuCharacterInput: Equatable {
    var expression: MokuExpression
    var focus: Double
    var running: Bool
    var reasoning: MokuReasoningContent?
    var presentsReasoning: Bool
    var executionKey: String?
    var capsuleSize: CGSize
    var cornerRadius: CGFloat
    var motion: Bool
    var reduceMotion: Bool
    var dark: Bool
}

struct NativeMokuCharacterPose {
    var values: [String: Double]
    subscript(_ key: String) -> Double {
        get { values[key, default: 0] }
        set { values[key] = newValue }
    }
    func map(_ transform: (String) -> Double) -> Self {
        Self(values: Dictionary(uniqueKeysWithValues: values.keys.map { ($0, transform($0)) }))
    }
    func eye(_ side: String) -> MokuEye {
        MokuEye(x: self[side + "x"], y: self[side + "y"], w: max(1, self[side + "w"]),
                h: max(1, self[side + "h"]), radius: max(0, self[side + "r"]),
                rotation: self[side + "a"], opacity: 1)
    }
}

/// One native display clock owns both seats. The eyes are never cross-faded or
/// replaced when a role changes; redirection inherits their current derivative.
@MainActor final class NativeMokuCharacterMotion: NSObject {
    private(set) var input: NativeMokuCharacterInput?
    private(set) var reasoningAnimation = MokuReasoningAnimation()
    private(set) var clock = 0.0
    private(set) var pose = NativeMokuCharacterPose(values: [:])
    private(set) var frameCount = 0
    private(set) var retiredGlyphs: [MokuReasoningGlyph] = []
    private var arcSize = CGSize.zero
    private var from = NativeMokuCharacterPose(values: [:])
    private var velocity = NativeMokuCharacterPose(values: [:])
    private var transitionAt = 0.0
    private var duration = 0.0
    private var runningElapsed = 0.0
    private var lastWall = ProcessInfo.processInfo.systemUptime
    private var replacementAt = -Double.infinity
    private var replacementGlyphs: [MokuReasoningGlyph] = []
    private var link: CADisplayLink?
    private weak var linkView: NativeMokuCharacterCanvas?
    private weak var face: NativeMokuCharacterCanvas?
    private weak var decorations: NativeMokuCharacterCanvas?
    private var wasVisible = false
    private var retirementPending = false
    var onReasoningRetired: (() -> Void)?

    var currentReasoning: MokuReasoningContent? { input?.presentsReasoning == true ? reasoningAnimation.content : nil }
    var paintedReasoningGlyphs: [MokuReasoningGlyph] { reasoningAnimation.glyphs + retiredGlyphs + replacementGlyphs }
    var runningMilliseconds: Double { runningElapsed }
    var isTransitioning: Bool { clock < transitionAt + duration }
    var hasScheduledFrame: Bool { link?.isPaused == false && visible }
    var isRetiringReasoning: Bool { !retiredGlyphs.isEmpty && pose["arcAlpha"] > 0.001 }
    private var visible: Bool {
        input?.motion == true && input?.reduceMotion == false
            && (face?.motionVisible == true || decorations?.motionVisible == true)
    }

    func attach(_ view: NativeMokuCharacterCanvas) {
        if view.seat == .face { face = view } else { decorations = view }
        visibilityChanged()
    }
    func detach(_ view: NativeMokuCharacterCanvas) {
        if face === view { face = nil }
        if decorations === view { decorations = nil }
        visibilityChanged()
    }

    func configure(_ next: NativeMokuCharacterInput) {
        guard input != next else { return }
        let previous = input
        let previousPose = previous == nil ? nil : sample(at: clock)
        let previousVelocity = previousPose.map { before in
            let after = sample(at: clock + 0.01)
            return before.map { key in
                // The authored palette is quantized to 8-bit channels. Inferring
                // velocity from a single quantization step magnifies it over the
                // handoff and can flash a saturated color. Blend color values;
                // preserve derivatives for geometry and opacity only.
                if key.hasPrefix("d") && ["r", "g", "b"].contains(String(key.suffix(1))) { return 0 }
                return (after[key] - before[key]) / 0.01
            }
        }
        let wasThinking = previous?.presentsReasoning == true
        let isThinking = next.presentsReasoning && next.reasoning != nil
        if wasThinking && !isThinking {
            retiredGlyphs = reasoningAnimation.glyphs
            retirementPending = true
        }
        if isThinking { retirementPending = false }
        if wasThinking && isThinking, let oldReasoning = reasoningAnimation.content,
           let newReasoning = next.reasoning, !oldReasoning.sharesSegment(with: newReasoning) {
            replacementGlyphs = reasoningAnimation.glyphs; replacementAt = clock
        }
        if previous?.executionKey != next.executionKey {
            runningElapsed = 0
            replacementGlyphs = []
            // A new execution cannot restore a retired source from the old one.
            if isThinking { retiredGlyphs = [] }
        }
        input = next
        if isThinking { arcSize = next.capsuleSize }
        let track = NativeMokuReasoningArcTrack(body: CGRect(origin: .zero, size: next.capsuleSize))
        reasoningAnimation.configure(next.reasoning, length: track.length,
                                     animated: isThinking && !next.reduceMotion)
        let changed = previous.map { old in
            old.expression != next.expression || old.focus != next.focus || old.running != next.running
                || old.presentsReasoning != next.presentsReasoning || old.capsuleSize != next.capsuleSize
                || old.cornerRadius != next.cornerRadius || old.executionKey != next.executionKey
        } ?? true
        if changed {
            from = previousPose ?? target(at: clock)
            velocity = previousVelocity ?? from.map { _ in 0 }
            transitionAt = clock
            duration = previous == nil || next.reduceMotion ? 0
                : (previous?.running != next.running || wasThinking != isThinking ? 550 : 420)
        }
        if next.reduceMotion {
            duration = 0; retiredGlyphs = []; replacementGlyphs = []
            retirementPending = false
        }
        pose = sample(at: clock)
        face?.needsDisplay = true; decorations?.needsDisplay = true
        visibilityChanged()
    }

    func visibilityChanged() {
        let active = visible
        if active != wasVisible { lastWall = ProcessInfo.processInfo.systemUptime; wasVisible = active }
        guard active, let anchor = face ?? decorations else {
            link?.isPaused = true
            if input?.presentsReasoning != true, retirementPending {
                retiredGlyphs = []; finishRetirement()
            }
            if face == nil && decorations == nil {
                link?.invalidate(); link = nil; linkView = nil
                retiredGlyphs = []; replacementGlyphs = []
            }
            face?.needsDisplay = true; decorations?.needsDisplay = true
            return
        }
        if linkView !== anchor {
            link?.invalidate()
            link = anchor.displayLink(target: self, selector: #selector(displayFrame(_:)))
            linkView = anchor
            link?.add(to: .main, forMode: .common)
        }
        link?.isPaused = false
    }

    @objc private func displayFrame(_ displayLink: CADisplayLink) {
        guard visible else { visibilityChanged(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = max(0, min(64, (now - lastWall) * 1000)); lastWall = now
        clock += dt
        if input?.running == true { runningElapsed += dt }
        if input?.presentsReasoning == true { reasoningAnimation.advance(milliseconds: dt) }
        pose = sample(at: clock)
        if !isTransitioning && input?.presentsReasoning != true {
            retiredGlyphs = []; finishRetirement()
        }
        if clock - replacementAt >= 220 { replacementGlyphs = [] }
        frameCount += 1
        face?.needsDisplay = true; decorations?.needsDisplay = true
    }

    private func finishRetirement() {
        guard retirementPending else { return }
        retirementPending = false
        // Configuration can run inside NSViewRepresentable.updateNSView. Let
        // SwiftUI finish that update before releasing the reserved arc seat.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.input?.presentsReasoning != true else { return }
            self.onReasoningRetired?()
        }
    }

    private func sample(at time: Double) -> NativeMokuCharacterPose {
        let target = target(at: time)
        guard duration > 0, time < transitionAt + duration else { return target }
        let p = max(0, min(1, (time - transitionAt) / duration))
        let blend = p * p * (3 - 2 * p)
        let tangent = p * p * p - 2 * p * p + p
        return target.map { from[$0] + (target[$0] - from[$0]) * blend + velocity[$0] * duration * tangent }
    }

    private func target(at time: Double) -> NativeMokuCharacterPose {
        guard let input else { return .init(values: [:]) }
        let running = input.running
        let thinking = input.presentsReasoning && input.reasoning != nil
        let story = NativeMokuRunningGeometry.sample(milliseconds: runningElapsed + (running ? time - clock : 0),
            capsuleSize: input.capsuleSize, cornerRadius: input.cornerRadius, still: input.reduceMotion)
        let eyes = NativeMokuCapsuleEyes.resolved(expression: running ? .idle : input.expression, focus: running ? 0 : input.focus)
        var result = NativeMokuCharacterPose(values: ["arcAlpha": thinking ? 1 : 0,
                                                       "arcGather": thinking ? 0 : 1, "arcReveal": thinking ? 1 : 0])
        for (side, eye) in [("l", eyes.left), ("r", eyes.right)] {
            result[side + "x"] = eye.x + (running ? story.eyes.x * 0.12 / 0.22 : 0)
            result[side + "y"] = eye.y * (running ? story.eyes.scaleY : 1) + (running ? story.eyes.y * 0.12 / 0.22 : 0)
            result[side + "w"] = eye.w; result[side + "h"] = eye.h * (running ? story.eyes.scaleY : 1)
            result[side + "r"] = eye.radius; result[side + "a"] = eye.rotation
        }
        let track = NativeMokuReasoningArcTrack(body: CGRect(x: -input.capsuleSize.width / 2,
            y: -input.capsuleSize.height / 2, width: input.capsuleSize.width, height: input.capsuleSize.height))
        for (index, dot) in story.dots.enumerated() {
            let key = "d\(index)", color = MokuGeometry.colorComponents(dot.color)
            let seed = track.sample(track.length * (Double(index) + 0.5) / 3).point
            result[key + "x"] = running ? (dot.x - 320) * 0.075 : thinking ? seed.x : 0
            result[key + "y"] = running ? (dot.y - 300) * 0.075 : thinking ? seed.y : input.capsuleSize.height / 2 + 5.5
            result[key + "a"] = running ? dot.opacity : 0
            result[key + "r"] = color.red; result[key + "g"] = color.green; result[key + "b"] = color.blue
            result[key + "radius"] = running ? 2.5 : 0.4
        }
        return result
    }

    func paintFace(in context: CGContext, bounds: CGRect) {
        guard let input else { return }
        context.saveGState(); defer { context.restoreGState() }
        let blink = visible ? NativeMokuCapsuleBlinkTiming.factor(at: Date()) : 1
        let shape = NativeMokuCapsuleEyes(left: pose.eye("l"), right: pose.eye("r"), blink: blink)
        context.setFillColor((input.dark ? NSColor.white : NSColor.black).cgColor)
        context.addPath(shape.path(in: bounds).cgPath); context.fillPath()
    }

    func paintDecorations(in context: CGContext, bounds: CGRect) {
        guard let input else { return }
        context.saveGState(); defer { context.restoreGState() }
        for index in 0...2 {
            let key = "d\(index)", opacity = max(0, min(1, pose[key + "a"]))
            guard opacity > 0.001 else { continue }
            let radius = max(0, pose[key + "radius"])
            context.setAlpha(opacity)
            context.setFillColor(NSColor(srgbRed: max(0, min(1, pose[key + "r"])),
                green: max(0, min(1, pose[key + "g"])), blue: max(0, min(1, pose[key + "b"])), alpha: 1).cgColor)
            context.fillEllipse(in: CGRect(x: bounds.midX + pose[key + "x"] - radius,
                y: bounds.midY + pose[key + "y"] - radius, width: radius * 2, height: radius * 2))
        }
        let size = input.presentsReasoning ? input.capsuleSize : arcSize
        let track = NativeMokuReasoningArcTrack(body: CGRect(x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2, width: size.width, height: size.height))
        let replacement = max(0, min(1, (clock - replacementAt) / 220))
        let current = input.presentsReasoning ? reasoningAnimation.glyphs : retiredGlyphs
        NativeMokuReasoningArcPainter.paint(glyphs: current, track: track, in: context, dark: input.dark,
            opacity: pose["arcAlpha"] * (replacementGlyphs.isEmpty ? 1 : replacement),
            gather: pose["arcGather"], reveal: pose["arcReveal"])
        if !replacementGlyphs.isEmpty {
            NativeMokuReasoningArcPainter.paint(glyphs: replacementGlyphs, track: track, in: context, dark: input.dark,
                opacity: pose["arcAlpha"] * (1 - replacement), gather: pose["arcGather"], reveal: pose["arcReveal"])
        }
    }
}

enum NativeMokuCharacterSeat { case face, decorations }

struct NativeMokuCharacterSurface: NSViewRepresentable {
    let controller: NativeMokuCharacterMotion
    let input: NativeMokuCharacterInput
    let seat: NativeMokuCharacterSeat
    func makeNSView(context: Context) -> NativeMokuCharacterCanvas {
        NativeMokuCharacterCanvas(controller: controller, seat: seat)
    }
    func updateNSView(_ view: NativeMokuCharacterCanvas, context: Context) { controller.configure(input) }
    static func dismantleNSView(_ view: NativeMokuCharacterCanvas, coordinator: ()) { view.detach() }
}

/// Passive drawing seats share one controller. AppKit owns display pacing and
/// stops its link when the view leaves the display; no fixed-rate sampler exists.
@MainActor final class NativeMokuCharacterCanvas: NSView {
    let controller: NativeMokuCharacterMotion
    let seat: NativeMokuCharacterSeat
    private var observers: [NSObjectProtocol] = []
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    var motionVisible: Bool {
        !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty && window?.isMiniaturized == false
            && window?.occlusionState.contains(.visible) == true
    }
    init(controller: NativeMokuCharacterMotion, seat: NativeMokuCharacterSeat) {
        self.controller = controller; self.seat = seat
        super.init(frame: .zero)
        wantsLayer = true; clipsToBounds = false; layer?.masksToBounds = false
        setAccessibilityElement(false)
        controller.attach(self)
    }
    required init?(coder: NSCoder) { nil }
    isolated deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func detach() { controller.detach(self) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.controller.visibilityChanged() }
                })
            }
        }
        controller.visibilityChanged()
    }
    override func viewDidHide() { super.viewDidHide(); controller.visibilityChanged() }
    override func viewDidUnhide() { super.viewDidUnhide(); controller.visibilityChanged() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); controller.visibilityChanged(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if seat == .face { controller.paintFace(in: context, bounds: bounds) }
        else { controller.paintDecorations(in: context, bounds: bounds) }
    }
}
