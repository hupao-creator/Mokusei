import AppKit
import Metal
import QuartzCore
import SwiftUI

/// Overview's native driver for the existing point-space cloud shader. Geometry,
/// palette and lifecycle arrive from SwiftUI; frame callbacks do not publish state
/// or ask its hosting graph to lay out or draw.
@MainActor
struct NativeOverviewCloudView: NSViewRepresentable {
    let palette: NativeCloudPalette
    let running: Bool
    let isAnimating: Bool
    let isVisible: Bool

    static var isAvailable: Bool { NativeOverviewCloudPipeline.shared != nil }

    func makeNSView(context: Context) -> NativeOverviewCloudSurface {
        NativeOverviewCloudSurface(palette: palette, running: running, isAnimating: isAnimating,
                                   isVisible: isVisible, environment: context.environment)
    }

    func updateNSView(_ view: NativeOverviewCloudSurface, context: Context) {
        view.update(palette: palette, running: running, isAnimating: isAnimating, isVisible: isVisible,
                    environment: context.environment, animate: !context.transaction.disablesAnimations)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeOverviewCloudSurface, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    static func dismantleNSView(_ view: NativeOverviewCloudSurface, coordinator: ()) { view.dismantle() }
}

@MainActor
final class NativeOverviewCloudSurface: NSView {
    private let metal = CAMetalLayer()
    private var renderer: NativeOverviewCloudRenderer?
    private var palette: NativeCloudPalette
    private var colors: [SIMD4<Float16>]
    private var colorScheme: ColorScheme
    private var animates: Bool
    private var visible: Bool
    private var targetIntensity: Double
    private var fade: Fade?
    private let seed = UInt64.random(in: .min ... .max)
    private let startedAt = Date()
    private var frozenMotionTime: TimeInterval = 0
    private var frameLink: CADisplayLink?
    private var linkTarget: NativeOverviewCloudLinkTarget?
    private var frameGeneration: UInt64 = 0
    private var needsFrame = true
    private var redrawVersion: UInt64 = 0
    private var nextFrameID: UInt64 = 0
    private var awaitingFrame: UInt64?
    private var suspended = true
    private var dismantled = false

    init(palette: NativeCloudPalette, running: Bool, isAnimating: Bool, isVisible: Bool, environment: EnvironmentValues) {
        self.palette = palette
        colors = Self.resolveColors(palette, in: environment)
        colorScheme = environment.colorScheme
        animates = isAnimating
        visible = isVisible
        targetIntensity = running ? 1 : 0
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        metal.pixelFormat = .rgba16Float
        metal.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        metal.wantsExtendedDynamicRangeContent = false
        metal.isOpaque = false
        metal.backgroundColor = NSColor.clear.cgColor
        metal.framebufferOnly = true
        metal.maximumDrawableCount = 2
        metal.allowsNextDrawableTimeout = true
        metal.presentsWithTransaction = false
        // The existing SwiftUI RoundedRectangle remains the clipping authority.
        // Do not add a second native corner curve with potentially different ink.
        metal.isHidden = true
        if let pipeline = NativeOverviewCloudPipeline.shared {
            metal.device = pipeline.device
            renderer = NativeOverviewCloudRenderer(layer: metal, pipeline: pipeline)
        }
        layer?.addSublayer(metal)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { return nil }
    isolated deinit {
        frameLink?.invalidate()
        renderer?.stop()
        NotificationCenter.default.removeObserver(self)
    }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }

    func update(palette: NativeCloudPalette, running: Bool, isAnimating: Bool, isVisible: Bool,
                environment: EnvironmentValues, animate: Bool) {
        guard !dismantled else { return }
        let nextColors = Self.resolveColors(palette, in: environment)
        let target: Double = running ? 1 : 0
        guard !Self.samePalette(self.palette, palette) || colors != nextColors
            || colorScheme != environment.colorScheme || target != targetIntensity
            || animates != isAnimating || visible != isVisible else { return }
        if animates && !isAnimating { frozenMotionTime = Date().timeIntervalSince(startedAt) }
        if target != targetIntensity {
            let now = CACurrentMediaTime(), current = intensity(at: now)
            targetIntensity = target
            fade = animate && current != target ? Fade(from: current, to: target, startedAt: now) : nil
        }
        self.palette = palette
        colors = nextColors
        colorScheme = environment.colorScheme
        animates = isAnimating
        visible = isVisible
        requestFrame()
        refreshDriver()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: window)
        if newWindow == nil { suspendSurface(); stopLink() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowVisibilityChanged),
                name: NSWindow.didChangeOcclusionStateNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowVisibilityChanged),
                name: NSWindow.didChangeScreenNotification, object: window)
        }
        updateGeometry()
        requestFrame()
        refreshDriver()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateGeometry()
        requestFrame()
        refreshDriver()
    }

    override func viewDidHide() {
        super.viewDidHide()
        suspendSurface()
        frameLink?.isPaused = true
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateGeometry()
        requestFrame()
        refreshDriver()
    }

    override func layout() {
        super.layout()
        if updateGeometry() { requestFrame(); refreshDriver() }
    }

    @discardableResult
    private func updateGeometry() -> Bool {
        let scale = window?.backingScaleFactor ?? 1
        let size = CGSize(width: max(0, ceil(bounds.width * scale)), height: max(0, ceil(bounds.height * scale)))
        let changed = metal.frame != bounds || metal.drawableSize != size || metal.contentsScale != scale
        if changed {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            metal.frame = bounds
            metal.contentsScale = scale
            metal.drawableSize = size
            CATransaction.commit()
        }
        return changed
    }

    @objc private func windowVisibilityChanged(_ notification: Notification) {
        updateGeometry()
        frameLink?.preferredFrameRateRange = NativeFrameRate.preferredRange(for: window?.screen)
        requestFrame()
        refreshDriver()
    }

    private var canRenderCloud: Bool {
        !dismantled && visible && !isHiddenOrHasHiddenAncestor
            && window?.occlusionState.contains(.visible) == true
            && bounds.width.isFinite && bounds.height.isFinite && bounds.width > 0 && bounds.height > 0
    }

    private func intensity(at now: TimeInterval) -> Double {
        guard let fade else { return targetIntensity }
        let progress = (now - fade.startedAt) / 0.4
        return fade.from + (fade.to - fade.from) * UnitCurve.easeInOut.value(at: progress)
    }

    private func refreshDriver() {
        let now = CACurrentMediaTime()
        if let fade, now - fade.startedAt >= 0.4 { self.fade = nil }
        guard renderer != nil, !colors.isEmpty, intensity(at: now) > 0 || fade != nil else {
            clearSurface(); frameLink?.isPaused = true; return
        }
        // Visibility pauses preserve the most recent image, including while an
        // Overview transition still exposes part of its outgoing contents.
        guard canRenderCloud else { suspendSurface(); frameLink?.isPaused = true; return }
        suspended = false
        if frameLink == nil {
            let target = NativeOverviewCloudLinkTarget(view: self)
            let link = displayLink(target: target, selector: #selector(NativeOverviewCloudLinkTarget.tick(_:)))
            link.preferredFrameRateRange = NativeFrameRate.preferredRange(for: window?.screen)
            link.add(to: .main, forMode: .common)
            linkTarget = target
            frameLink = link
        }
        // A static or paused field draws once. A pending first frame stays on the
        // link until a drawable is ready; no setNeedsDisplay/layout propagation.
        frameLink?.isPaused = !(animates || fade != nil || needsFrame || awaitingFrame != nil)
    }

    fileprivate func tick() {
        refreshDriver()
        guard canRenderCloud, let renderer, frameLink?.isPaused == false else { return }
        // Wait for the requested static frame's completion without submitting
        // duplicate frames when the GPU has finished but its main-actor task has
        // not yet run. A new input change still requests a replacement frame.
        guard animates || fade != nil || needsFrame else { return }
        let value = intensity(at: CACurrentMediaTime())
        guard value > 0 else { return }
        let motionTime = animates ? Date().timeIntervalSince(startedAt) : frozenMotionTime
        let lights = NativeCloudField(palette: palette, intensity: value,
            time: motionTime * 1.4 + palette.phase, seed: seed).lights(in: bounds.size, colorScheme: colorScheme)
        let frame = NativeOverviewCloudFrame(geometry: lights.geometry, colors: colors,
                                            pointSize: SIMD2(Float(bounds.width), Float(bounds.height)))
        let generation = frameGeneration
        let version = redrawVersion
        let requestCompletion = needsFrame || metal.isHidden
        nextFrameID &+= 1
        let frameID = nextFrameID
        let completion: (@Sendable (Bool) -> Void)?
        if requestCompletion {
            completion = { [weak self] succeeded in
                Task { @MainActor [weak self] in
                    self?.completedFrame(succeeded, generation: generation, version: version, id: frameID)
                }
            }
        } else { completion = nil }
        if renderer.submit(frame, generation: generation, completion: completion) {
            needsFrame = false
            if requestCompletion { awaitingFrame = frameID }
        }
    }

    private func completedFrame(_ succeeded: Bool, generation: UInt64, version: UInt64, id: UInt64) {
        guard !dismantled, generation == frameGeneration, awaitingFrame == id else { return }
        awaitingFrame = nil
        if succeeded && version == redrawVersion && canRenderCloud && intensity(at: CACurrentMediaTime()) > 0 {
            if metal.isHidden {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                metal.isHidden = false
                CATransaction.commit()
            }
        } else { needsFrame = true }
        refreshDriver()
    }

    private func requestFrame() {
        redrawVersion &+= 1
        needsFrame = true
    }

    private func suspendSurface() {
        if !suspended {
            frameGeneration = renderer?.retireFrames() ?? frameGeneration
            suspended = true
        }
        awaitingFrame = nil
        needsFrame = true
    }

    private func clearSurface() {
        suspendSurface()
        if !metal.isHidden {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            metal.isHidden = true
            CATransaction.commit()
        }
    }

    private func stopLink() {
        frameLink?.invalidate()
        frameLink = nil
        linkTarget = nil
    }

    func dismantle() {
        guard !dismantled else { return }
        dismantled = true
        NotificationCenter.default.removeObserver(self)
        clearSurface()
        stopLink()
        renderer?.stop()
        renderer = nil
        metal.removeFromSuperlayer()
    }

    private static func resolveColors(_ palette: NativeCloudPalette, in environment: EnvironmentValues) -> [SIMD4<Float16>] {
        palette.channels.flatMap { channel in
            let color = channel.color.resolve(in: environment)
            let alpha = color.opacity
            let rgba = SIMD4<Float16>(Float16(color.linearRed * alpha), Float16(color.linearGreen * alpha),
                                      Float16(color.linearBlue * alpha), Float16(alpha))
            // NativeCloudField emits three lobes with two scales per channel.
            return Array(repeating: rgba, count: 6)
        }
    }

    private static func samePalette(_ lhs: NativeCloudPalette, _ rhs: NativeCloudPalette) -> Bool {
        lhs.phase == rhs.phase && lhs.lobeScale == rhs.lobeScale && lhs.channels.count == rhs.channels.count
            && zip(lhs.channels, rhs.channels).allSatisfy { pair in
                pair.0.seed == pair.1.seed && pair.0.energy == pair.1.energy && pair.0.color == pair.1.color
            }
    }

    private struct Fade {
        let from: Double
        let to: Double
        let startedAt: TimeInterval
    }
}

@MainActor
private final class NativeOverviewCloudLinkTarget: NSObject {
    weak var view: NativeOverviewCloudSurface?
    init(view: NativeOverviewCloudSurface) { self.view = view }
    @objc func tick(_ link: CADisplayLink) {
        guard let view else { link.invalidate(); return }
        view.tick()
    }
}
