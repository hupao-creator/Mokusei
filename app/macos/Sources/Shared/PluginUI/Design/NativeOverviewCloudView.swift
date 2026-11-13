import AppKit
import QuartzCore
import SwiftUI

@MainActor
struct NativeOverviewCloudView: View {
    let palette: NativeCloudPalette
    let running: Bool
    let isAnimating: Bool
    let isVisible: Bool
    @State private var failedStyle: NativeCloudLoopStyle?

    var body: some View {
        if let style = palette.loopStyle, failedStyle != style {
            NativeOverviewCloudPlayback(style: style, running: running, animates: isAnimating, visible: isVisible,
                failed: { failedStyle = $0 })
        } else if NativeLiveOverviewCloudView.isAvailable {
            NativeLiveOverviewCloudView(palette: palette, running: running, isAnimating: isAnimating, isVisible: isVisible)
        } else {
            NativeCloudLoading(palette: palette, intensity: running ? 1 : 0, isAnimating: isAnimating, motionSpeed: 1.4)
                .animation(.easeInOut(duration: 0.4), value: running)
        }
    }
}

@MainActor
private struct NativeOverviewCloudPlayback: NSViewRepresentable {
    let style: NativeCloudLoopStyle
    let running: Bool
    let animates: Bool
    let visible: Bool
    let failed: @MainActor (NativeCloudLoopStyle) -> Void

    func makeNSView(context: Context) -> NativeOverviewCloudSurface {
        NativeOverviewCloudSurface(asset: .init(style: style, dark: context.environment.colorScheme == .dark),
            running: running, animates: animates, visible: visible, failed: failed)
    }
    func updateNSView(_ view: NativeOverviewCloudSurface, context: Context) {
        view.update(asset: .init(style: style, dark: context.environment.colorScheme == .dark),
            running: running, animates: animates, visible: visible, animate: !context.transaction.disablesAnimations)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeOverviewCloudSurface, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
    static func dismantleNSView(_ view: NativeOverviewCloudSurface, coordinator: ()) { view.dismantle() }
}

/// The compositor owns playback; AppKit only receives state/geometry changes.
@MainActor
final class NativeOverviewCloudSurface: NSView {
    private let cloud = CALayer()
    private var asset: NativeOverviewCloudAsset
    private var running: Bool
    private var animates: Bool
    private var visible: Bool
    private let failed: @MainActor (NativeCloudLoopStyle) -> Void
    private var loaded: NativeOverviewCloudAsset?
    private var requested: NativeOverviewCloudAsset?
    private var atlas: NativeOverviewCloudAtlas?
    private var loadTask: Task<Void, Never>?
    private var fadeTask: Task<Void, Never>?
    private var fadeGeneration: UInt64 = 0
    private var animateOpacity = false
    private let epoch = CACurrentMediaTime()
    private let phaseOffset = Double.random(in: 0..<8)
    private var lastRate: Float = 0
    private var lastDisplay: UInt32 = 0
    private var dismantled = false

    init(asset: NativeOverviewCloudAsset, running: Bool, animates: Bool, visible: Bool,
         failed: @escaping @MainActor (NativeCloudLoopStyle) -> Void) {
        self.asset = asset; self.running = running; self.animates = animates; self.visible = visible; self.failed = failed
        super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = NSColor.clear.cgColor
        cloud.name = "overview.cloud"; cloud.opacity = 0; cloud.isOpaque = false
        cloud.contentsGravity = .resize; cloud.minificationFilter = .linear; cloud.magnificationFilter = .linear
        layer?.addSublayer(cloud); setAccessibilityElement(false)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }
    required init?(coder: NSCoder) { return nil }
    isolated deinit { NotificationCenter.default.removeObserver(self); loadTask?.cancel(); fadeTask?.cancel() }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }

    func update(asset: NativeOverviewCloudAsset, running: Bool, animates: Bool, visible: Bool, animate: Bool) {
        guard !dismantled, self.asset != asset || self.running != running || self.animates != animates || self.visible != visible else { return }
        let changedRun = self.running != running
        self.asset = asset; self.running = running; self.animates = animates; self.visible = visible
        animateOpacity = animate
        if changedRun { setOpacity(animate: animate) }
        refresh()
    }
    private func setOpacity(animate: Bool) {
        fadeTask?.cancel(); fadeTask = nil; fadeGeneration &+= 1
        let from = cloud.presentation()?.opacity ?? cloud.opacity
        let target: Float = running && atlas != nil ? 1 : 0
        CATransaction.begin(); CATransaction.setDisableActions(true); cloud.opacity = target; CATransaction.commit()
        cloud.removeAnimation(forKey: "energy")
        guard animate, from != target else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from; fade.toValue = target; fade.duration = 0.4
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fade.preferredFrameRateRange = NativeFrameRate.preferredRange(for: window?.screen)
        cloud.add(fade, forKey: "energy")
        if !running {
            let generation = fadeGeneration
            fadeTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                guard let self, !self.dismantled, generation == self.fadeGeneration else { return }
                self.fadeTask = nil; self.refresh()
            }
        }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didChangeScreenNotification] {
            NotificationCenter.default.removeObserver(self, name: name, object: window)
        }
        if newWindow == nil { pause(); cancelLoad() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didChangeScreenNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: name, object: window)
            }
        }
        geometry(); refresh()
    }
    override func layout() { super.layout(); geometry(); refresh() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); geometry(); refresh() }
    override func viewDidHide() { super.viewDidHide(); pause(); cancelLoad() }
    override func viewDidUnhide() { super.viewDidUnhide(); refresh() }
    @objc private func screenChanged(_ notification: Notification) { geometry(); refresh() }
    private func geometry() {
        let scale = window?.backingScaleFactor ?? 1
        guard cloud.frame != bounds || cloud.contentsScale != scale else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        cloud.frame = bounds; cloud.contentsScale = scale
        CATransaction.commit()
    }
    private func refresh() {
        guard !dismantled else { return }
        guard running || fadeTask != nil else {
            pause(); cancelLoad()
            CATransaction.begin(); CATransaction.setDisableActions(true); cloud.contents = nil; CATransaction.commit()
            atlas = nil; loaded = nil; return
        }
        guard visible, !isHiddenOrHasHiddenAncestor, window?.occlusionState.contains(.visible) == true,
              bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            pause(); cancelLoad(); return
        }
        if loaded != asset {
            guard requested != asset else { return }
            cancelLoad(); requested = asset
            let key = asset
            loadTask = Task { [weak self] in
                do {
                    let image = try await NativeOverviewCloudAssets.load(key)
                    guard !Task.isCancelled, let self, !self.dismantled, self.requested == key else { return }
                    let first = self.atlas == nil
                    self.atlas = image; self.loaded = key; self.requested = nil; self.loadTask = nil
                    self.pause()
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    self.cloud.contents = image.image
                    self.cloud.contentsRect = image.rectangles[Int(self.phase(at: CACurrentMediaTime()) * Double(image.metadata.fps)) % image.metadata.count]
                    CATransaction.commit()
                    if first { self.setOpacity(animate: self.animateOpacity) }
                    self.refresh()
                } catch {
                    guard !Task.isCancelled, let self, !self.dismantled, self.requested == key else { return }
                    self.loadTask = nil; self.requested = nil; self.failed(key.style)
                }
            }
            return
        }
        guard let atlas else { return }
        guard animates else { pause(); return }
        let screen = window?.screen
        let display = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let mode = display == 0 ? 0 : CGDisplayCopyDisplayMode(display)?.refreshRate ?? 0
        let cap = min(Float(atlas.metadata.fps), Float(screen?.maximumFramesPerSecond ?? atlas.metadata.fps))
        let rate = max(1, mode > 0 ? min(cap, Float(mode)) : cap)
        if cloud.animation(forKey: "loop") != nil, rate == lastRate, display == lastDisplay { return }
        let now = CACurrentMediaTime()
        let motion = CAKeyframeAnimation(keyPath: "contentsRect")
        motion.values = (atlas.rectangles + [atlas.rectangles[0]]).map { NSValue(rect: $0) }
        motion.keyTimes = (0...atlas.metadata.count).map { NSNumber(value: Double($0) / Double(atlas.metadata.count)) }
        motion.calculationMode = .discrete; motion.duration = atlas.metadata.duration; motion.repeatCount = .infinity
        motion.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        // Screen/appearance changes rejoin the same timeline, not a frame counter.
        motion.beginTime = cloud.convertTime(now, from: nil) - phase(at: now)
        cloud.add(motion, forKey: "loop"); lastRate = rate; lastDisplay = display
    }
    private func phase(at time: CFTimeInterval) -> Double { (time - epoch + phaseOffset).truncatingRemainder(dividingBy: 8) }
    private func pause() {
        guard cloud.animation(forKey: "loop") != nil else { return }
        let rectangle = cloud.presentation()?.contentsRect ?? cloud.contentsRect
        CATransaction.begin(); CATransaction.setDisableActions(true)
        cloud.contentsRect = rectangle; cloud.removeAnimation(forKey: "loop")
        CATransaction.commit()
    }
    private func cancelLoad() { loadTask?.cancel(); loadTask = nil; requested = nil }
    func dismantle() {
        guard !dismantled else { return }
        dismantled = true; NotificationCenter.default.removeObserver(self); cancelLoad(); fadeTask?.cancel(); fadeTask = nil
        cloud.removeAllAnimations(); cloud.contents = nil; cloud.removeFromSuperlayer(); atlas = nil
    }
}
