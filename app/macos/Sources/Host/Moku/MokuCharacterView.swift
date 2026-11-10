import MokuseiPluginUI
import AppKit
import SwiftUI

/// A complete native seat handoff, including resident text FIFO and gesture clocks.
/// Preserve this value when a surface moves; a fresh initializer starts new clocks.
@MainActor public struct MokuCharacterSnapshot {
    var model: MokuCharacterModel
    var resident: MokuResidentAnimation?
    var mode: MokuCharacterMode
    var usesResident: Bool
    var eyeMotion: MokuEyeMotion?
    var scope: String
    var identity: String
    var runningElapsed: Double
    var launch: MokuLaunchRequest?
    var handoff: MokuPaintedPose?
    var capturedAt: Double
    var suspendedElapsed: Double
}

public struct MokuLaunchRequest: Equatable, Sendable {
    public var id: UUID
    public var startedAt: Double
    public var speed: Double
    public var capsule: MokuLaunchCapsule
    public init(capsule: MokuLaunchCapsule, speed: Double = 1,
                startedAt: Double = ProcessInfo.processInfo.systemUptime * 1000, id: UUID = UUID()) {
        self.id = id; self.startedAt = startedAt; self.speed = max(0.01, speed); self.capsule = capsule
    }
}

/// Imperative capabilities for launch and cross-surface capture. Animation frames
/// only update the isolated material host, never the surrounding SwiftUI layout.
@MainActor public final class MokuCharacterController {
    private var model: MokuCharacterModel
    private var resident: MokuResidentAnimation?
    private var mode: MokuCharacterMode = .idle
    private var usesResident = true
    private var eyeMotion: MokuEyeMotion?
    private var scope = "", identity = ""
    private var runningElapsed = 0.0
    private var lastWall = 0.0
    private var launchRequest: MokuLaunchRequest?
    private var handoff: MokuPaintedPose?
    private var hasRestoredState = false
    private var suspendedAt: Double?
    private var suspendedElapsed = 550.0
    private weak var canvas: MokuCharacterCanvas?
    public private(set) var paintedFrameCount = 0

    public init() {
        let now = Self.now
        model = MokuCharacterModel(now: now); resident = MokuResidentAnimation(now: now); lastWall = now
    }

    public func snapshot() -> MokuCharacterSnapshot {
        let now = Self.now
        var capturedModel = model, capturedLaunch = launchRequest
        if let pause = suspendedAt {
            capturedModel.shiftClock(by: now - pause)
            if capturedLaunch != nil { capturedLaunch?.startedAt += now - pause }
        }
        return MokuCharacterSnapshot(model: capturedModel, resident: resident, mode: mode, usesResident: usesResident, eyeMotion: eyeMotion,
            scope: scope, identity: identity,
            runningElapsed: runningElapsed, launch: capturedLaunch,
            handoff: handoff, capturedAt: now, suspendedElapsed: suspendedElapsed)
    }

    public func restore(_ snapshot: MokuCharacterSnapshot) {
        hasRestoredState = true
        model = snapshot.model; resident = snapshot.resident; mode = snapshot.mode; usesResident = snapshot.usesResident
        eyeMotion = snapshot.eyeMotion; scope = snapshot.scope
        identity = snapshot.identity; runningElapsed = snapshot.runningElapsed
        launchRequest = snapshot.launch; handoff = snapshot.handoff
        let resumedAt = Self.now
        model.shiftClock(by: resumedAt - snapshot.capturedAt)
        if launchRequest != nil { launchRequest?.startedAt += resumedAt - snapshot.capturedAt }
        suspendedAt = nil
        suspendedElapsed = snapshot.suspendedElapsed; lastWall = Self.now
        resident?.advance(now: lastWall, active: false)
        canvas?.requestFrame()
    }

    public func launch(capsule: MokuLaunchCapsule, speed: Double = 1) {
        launchRequest = MokuLaunchRequest(capsule: capsule, speed: speed)
        runningElapsed = 0; lastWall = Self.now; handoff = nil
        configure(mode: .running, scope: scope, identity: identity,
                  usesResident: usesResident, eyeMotion: eyeMotion)
        handoff = nil
        canvas?.requestFrame()
    }

    fileprivate static var now: Double { ProcessInfo.processInfo.systemUptime * 1000 }
    fileprivate var viewport: CGRect { model.viewport }
    fileprivate func attach(_ view: MokuCharacterCanvas) { canvas = view }
    fileprivate func detach(_ view: MokuCharacterCanvas) { if canvas === view { canvas = nil } }

    fileprivate func configure(mode: MokuCharacterMode, scope: String, identity: String,
                               launch: MokuLaunchRequest? = nil, usesResident: Bool = true,
                               eyeMotion: MokuEyeMotion? = nil) {
        let now = Self.now
        // A new eye track is not a semantic mode change and must not restart
        // the spring, resident, launch, or idle clocks.
        if self.eyeMotion != eyeMotion { self.eyeMotion = eyeMotion; canvas?.requestFrame() }
        let changed = self.mode != mode || self.scope != scope || self.identity != identity
            || self.usesResident != usesResident
        let newLaunch = launch != nil && launch?.id != launchRequest?.id
        guard changed || newLaunch else { return }
        if let pause = suspendedAt {
            model.shiftClock(by: now - pause)
            if launchRequest != nil { launchRequest?.startedAt += now - pause }
            suspendedAt = now
        }
        let oldResident = self.usesResident && Self.residentRole(self.mode) != nil
        let newResident = usesResident ? Self.residentRole(mode) : nil
        if oldResident && newResident == nil, (usesResident || paintedFrameCount > 0 || hasRestoredState),
           let source = resident?.paintedPose() {
            model.adopt(handoff.map { $0.blended(to: source, amount: resident?.handoffProgress ?? 1) } ?? source, now: now)
            handoff = nil
            resident?.suspend(now: now); suspendedElapsed = 0
        }
        if let role = newResident {
            if resident == nil { resident = MokuResidentAnimation(role: role, now: now) }
            resident?.update(role: role, scope: scope, toolName: Self.toolName(mode),
                             now: now, active: oldResident && suspendedAt == nil)
            if !oldResident {
                handoff = model.paintedPose(now: model.lastFrameAt)
                resident?.resume(now: now)
            }
        }
        if newLaunch { launchRequest = launch; runningElapsed = max(0, (now - launch!.startedAt) * launch!.speed); handoff = nil }
        if mode != .running { launchRequest = nil }
        if mode == .running && (self.mode != .running || self.identity != identity) && !newLaunch { runningElapsed = 0 }
        self.mode = mode; self.usesResident = usesResident; self.scope = scope; self.identity = identity
        model.update(mode: mode, identity: identity, now: now)
        lastWall = now
        canvas?.requestFrame()
    }

    fileprivate func suspend() {
        let now = Self.now
        if suspendedAt == nil { suspendedAt = now }
        lastWall = now
        resident?.advance(now: now, active: false)
    }

    fileprivate func resume() {
        let now = Self.now
        if let pause = suspendedAt {
            model.shiftClock(by: now - pause)
            if launchRequest != nil { launchRequest?.startedAt += now - pause }
        }
        suspendedAt = nil; lastWall = now
        resident?.advance(now: now, active: false)
    }

    fileprivate func paint(in context: CGContext, now: Double, material: MokuBodyMaterial? = nil) {
        paintedFrameCount += 1
        let wallNow = now
        let now = suspendedAt == nil ? now : model.lastFrameAt
        let dt = suspendedAt != nil ? 0 : max(0, min(64, now - lastWall))
        lastWall = now
        if mode == .running {
            runningElapsed += dt * (launchRequest?.speed ?? 1)
            if let launchRequest, runningElapsed < MokuLaunchStory.duration {
                runningElapsed = max(runningElapsed, (now - launchRequest.startedAt) * launchRequest.speed)
            }
        }
        let intro = mode == .running && launchRequest != nil ? MokuLaunchStory.sample(elapsed: runningElapsed) : nil
        if usesResident && Self.residentRole(mode) != nil {
            if let intro { resident?.launchFrame(now: now, elapsed: max(0, runningElapsed - MokuLaunchStory.duration), finished: intro.running) }
            if intro == nil || intro!.running {
                resident?.advance(now: wallNow, active: suspendedAt == nil)
                if let from = handoff, let target = resident?.paintedPose() {
                    let amount = resident?.handoffProgress ?? 1
                    from.blended(to: target, amount: amount).paint(in: context, material: material)
                    resident?.paint(in: context, body: false, token: false)
                    if amount >= 1 { handoff = nil }
                } else { resident?.paint(in: context, material: material) }
                return
            }
        }
        model.advance(now: now)
        let story = mode == .running ? intro?.frame ?? MokuRunningStory.sample(time: runningElapsed / MokuRunningStory.beatMS) : nil
        model.paint(in: context, now: now, running: story, launch: intro,
                    launchCapsule: launchRequest?.capsule, launchElapsed: runningElapsed,
                    eyeOffset: eyeMotion?.sample(nowMilliseconds: wallNow) ?? .zero,
                    material: material)
        if !usesResident || Self.residentRole(mode) == nil {
            suspendedElapsed += dt
            resident?.paintSuspended(in: context, now: now)
        }
        if case .message(let message) = mode { Self.paintMessage(message, in: context) }
    }

    fileprivate func nextWake(now: Double) -> Double {
        guard suspendedAt == nil else { return .infinity }
        if mode == .running && launchRequest != nil && runningElapsed < MokuLaunchStory.duration { return now }
        if handoff != nil { return now }
        if usesResident && Self.residentRole(mode) != nil { return resident?.nextWake(now: now) ?? .infinity }
        if mode == .running { return now }
        if eyeMotion?.isActive(nowMilliseconds: now) == true { return now }
        if suspendedElapsed < 550 { return now }
        return model.nextWake(now: now)
    }

    private static func residentRole(_ mode: MokuCharacterMode) -> MokuResidentRole? {
        switch mode {
        case .idle: .idle
        case .running: .running
        case .tool, .namedTool: .tool
        case .reply: .reply
        default: nil
        }
    }
    private static func toolName(_ mode: MokuCharacterMode) -> String { if case .namedTool(let text) = mode { return text }; return "" }
    private static func paintMessage(_ value: String, in context: CGContext) {
        // The original message foreignObject is at (265,275), width 515, 3 lines.
        let lines = MokuMessageLayout.lines(value)
        context.saveGState()
        for (index, line) in lines.enumerated() {
            let text = NSAttributedString(string: line, attributes: [.font: NativeTypography.interPlatformFont(size: 23, weight: 480),
                .foregroundColor: MokuGeometry.eyeColor])
            mokuDrawText(text, at: CGPoint(x: 265, y: 275 + Double(index) * 29), in: context)
        }
        context.restoreGState()
    }
}

/// CoreGraphics surface with a one-shot wake timer. Hidden and occluded surfaces
/// stop drawing. Settled resident idle wakes once per blink, never continuously.
@MainActor public final class MokuCharacterCanvas: NativePlatformView {
    fileprivate var controller: MokuCharacterController
    private let glass = MokuGlassBodyView()
    private let foreground = MokuCharacterForeground()
    private var timer: Timer?
    private var observerTokens: [NSObjectProtocol] = []
    fileprivate var motionActive = true
    fileprivate var drawingViewport: CGRect?
    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { false }

    public init(controller: MokuCharacterController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = NSColor.clear.cgColor
        clipsToBounds = false; layer?.masksToBounds = false
        for view in [glass as NativePlatformView, foreground] {
            view.frame = bounds; view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        foreground.canvas = self
        setAccessibilityElement(false)
        controller.attach(self)
    }
    required init?(coder: NSCoder) { nil }
    isolated deinit {
        timer?.invalidate()
        for token in observerTokens { NotificationCenter.default.removeObserver(token) }
    }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for token in observerTokens { NotificationCenter.default.removeObserver(token) }
        observerTokens = []
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                observerTokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.visibilityChanged() }
                })
            }
        }
        visibilityChanged()
    }
    public override func viewDidHide() { super.viewDidHide(); visibilityChanged() }
    public override func viewDidUnhide() { super.viewDidUnhide(); visibilityChanged() }
    public override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); requestFrame() }

    fileprivate func setController(_ value: MokuCharacterController) {
        guard value !== controller else { return }
        controller.suspend(); controller.detach(self)
        controller = value; controller.attach(self); visibilityChanged()
    }
    fileprivate func visibilityChanged() {
        timer?.invalidate(); timer = nil
        if visible { controller.resume(); requestFrame() }
        else { controller.suspend() }
    }
    private var visible: Bool {
        motionActive && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty && window != nil
        && !(window?.isMiniaturized ?? true) && (window?.occlusionState.contains(.visible) ?? false)
    }
    fileprivate func requestFrame() {
        timer?.invalidate(); timer = nil
        foreground.requestFrame()
    }
    fileprivate func setGlassActions(_ actions: MokuGlassActions?) { glass.update(actions: actions) }
    fileprivate func paint(in context: CGContext) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        timer?.invalidate(); timer = nil
        let now = MokuCharacterController.now
        if !visible { controller.suspend() }
        let material = MokuBodyMaterial(in: context)
        context.saveGState()
        let view = drawingViewport ?? controller.viewport
        let scale = min(bounds.width / view.width, bounds.height / view.height)
        context.translateBy(x: (bounds.width - scale * view.width) / 2, y: (bounds.height - scale * view.height) / 2)
        context.scaleBy(x: scale, y: scale); context.translateBy(x: -view.minX, y: -view.minY)
        controller.paint(in: context, now: now, material: material)
        context.restoreGState()
        glass.update(material)
        guard visible else { return }
        let deadline = controller.nextWake(now: now)
        guard deadline.isFinite else { return }
        let delay = max(NativeFrameRate.interval, (deadline - now) / 1000)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.visible else { return }
                self.timer = nil; self.foreground.requestFrame()
            }
        }
        timer.tolerance = deadline > now ? min(0.02, delay * 0.05) : 0.001
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
}

/// Keep the eyes and decorations above the native glass compositing layer.
@MainActor private final class MokuCharacterForeground: NativePlatformView {
    weak var canvas: MokuCharacterCanvas?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(false)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    func requestFrame() {
        needsDisplay = true
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        canvas?.paint(in: context)
    }
}

/// The nominal view remains 640 units. A larger drawingViewport expands only
/// the drawing surface, preserving the silhouette scale and layout hit region.
public struct MokuCharacterView: View {
    @Environment(\.mokuGlassActions) private var glassActions
    public var mode: MokuCharacterMode
    public var motionActive: Bool
    public var scope: String
    public var identity: String
    public var controller: MokuCharacterController?
    public var launch: MokuLaunchRequest?
    public var drawingViewport: CGRect?
    /// Settings' plain MokuLogo uses the spring character; resident scenes keep
    /// the existing role choreography unless explicitly opting out.
    public var usesResident: Bool
    /// Prepared eye motion retains its original clock across captured seats.
    /// Passing nil cancels the track without disturbing natural gaze or blink.
    public var eyeMotion: MokuEyeMotion?
    public init(mode: MokuCharacterMode = .idle, motionActive: Bool = true,
                scope: String = "", identity: String = "", controller: MokuCharacterController? = nil,
                launch: MokuLaunchRequest? = nil, drawingViewport: CGRect? = nil,
                usesResident: Bool = true, eyeMotion: MokuEyeMotion? = nil) {
        self.mode = mode; self.motionActive = motionActive
        self.scope = scope; self.identity = identity; self.controller = controller; self.launch = launch
        self.drawingViewport = drawingViewport; self.usesResident = usesResident; self.eyeMotion = eyeMotion
    }
    public var body: some View {
        GeometryReader { geometry in
            let base = MokuGeometry.viewport(for: mode.layout)
            let viewport = drawingViewport ?? base
            let scale = min(geometry.size.width / base.width, geometry.size.height / base.height)
            let origin = CGPoint(x: (geometry.size.width - base.width * scale) / 2 + (viewport.minX - base.minX) * scale,
                                 y: (geometry.size.height - base.height * scale) / 2 + (viewport.minY - base.minY) * scale)
            MokuCharacterSurface(mode: mode, motionActive: motionActive,
                scope: scope, identity: identity, controller: controller, launch: launch, drawingViewport: viewport,
                usesResident: usesResident, eyeMotion: eyeMotion,
                glassActions: glassActions?.offsetBy(dx: -origin.x, dy: -origin.y))
                .frame(width: viewport.width * scale, height: viewport.height * scale)
                .offset(x: origin.x, y: origin.y)
        }
        .allowsHitTesting(false)
    }
}

@MainActor private struct MokuCharacterSurface {
    public var mode: MokuCharacterMode
    public var motionActive: Bool
    public var scope: String
    public var identity: String
    public var controller: MokuCharacterController?
    public var launch: MokuLaunchRequest?
    var drawingViewport: CGRect?
    var usesResident: Bool
    var eyeMotion: MokuEyeMotion?
    var glassActions: MokuGlassActions?
    public init(mode: MokuCharacterMode = .idle, motionActive: Bool = true,
                scope: String = "", identity: String = "", controller: MokuCharacterController? = nil,
                launch: MokuLaunchRequest? = nil, drawingViewport: CGRect? = nil,
                usesResident: Bool = true, eyeMotion: MokuEyeMotion? = nil, glassActions: MokuGlassActions? = nil) {
        self.mode = mode; self.motionActive = motionActive
        self.scope = scope; self.identity = identity; self.controller = controller; self.launch = launch
        self.drawingViewport = drawingViewport; self.usesResident = usesResident; self.eyeMotion = eyeMotion
        self.glassActions = glassActions
    }
    @MainActor public final class Coordinator { let defaultController = MokuCharacterController() }
    public func makeCoordinator() -> Coordinator { Coordinator() }
    @MainActor fileprivate func makeView(coordinator: Coordinator) -> MokuCharacterCanvas {
        let view = MokuCharacterCanvas(controller: controller ?? coordinator.defaultController)
        view.controller.configure(mode: mode, scope: scope, identity: identity,
                                  launch: launch, usesResident: usesResident, eyeMotion: eyeMotion)
        view.motionActive = motionActive; view.drawingViewport = drawingViewport
        view.setGlassActions(glassActions)
        return view
    }
    @MainActor fileprivate func updateView(_ view: MokuCharacterCanvas, coordinator: Coordinator) {
        view.setController(controller ?? coordinator.defaultController)
        if view.drawingViewport != drawingViewport { view.drawingViewport = drawingViewport; view.requestFrame() }
        if view.motionActive != motionActive { view.motionActive = motionActive; view.visibilityChanged() }
        view.setGlassActions(glassActions)
        view.controller.configure(mode: mode, scope: scope, identity: identity,
                                  launch: launch, usesResident: usesResident, eyeMotion: eyeMotion)
    }
    @MainActor fileprivate static func dismantleView(_ view: MokuCharacterCanvas) {
        view.motionActive = false; view.visibilityChanged(); view.controller.detach(view)
    }
}

extension MokuCharacterSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> MokuCharacterCanvas { makeView(coordinator: context.coordinator) }
    func updateNSView(_ view: MokuCharacterCanvas, context: Context) { updateView(view, coordinator: context.coordinator) }
    static func dismantleNSView(_ view: MokuCharacterCanvas, coordinator: Coordinator) { dismantleView(view) }
}
