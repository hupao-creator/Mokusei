import AppKit
import MokuseiPluginUI
import Observation
import QuartzCore
import SwiftUI

@MainActor final class NativeMokuCapsuleMotionHandle {
    weak var view: MokuCapsuleMotionView?

    /// nil leaves Note, Settings, Talk and voice with their existing routing.
    func contains(_ point: CGPoint) -> Bool? { view?.containsViewportPoint(point) }
    var frameInViewport: CGRect? { view?.frameInViewport }
}

struct NativeMokuCapsuleDestination: Equatable {
    let shell: CGRect
    let face: CGPoint
    let faceScale: CGFloat
    let viewport: CGSize
    let viewportOffset: CGPoint
    let nativeShell: Bool
    let composerVisible: Bool
    let chromeControlsVisible: Bool
    let immediate: Bool
    let reading: Bool
    let opaque: Bool
    let hovered: Bool
}

/// Three persistent hosts: destination-layout content, unscaled editor ink and
/// a passive identity seat. Only the shell changes size. No frame callback or
/// SwiftUI Animatable value drives the morph.
struct NativeMokuCapsuleMotion: NSViewRepresentable {
    let handle: NativeMokuCapsuleMotionHandle
    let destination: NativeMokuCapsuleDestination
    let chrome: AnyView
    let composer: AnyView
    let face: AnyView
    let openInput: () -> Void
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> MokuCapsuleMotionView { MokuCapsuleMotionView(handle: handle) }
    func updateNSView(_ view: MokuCapsuleMotionView, context: Context) {
        context.environment.nativeCanvasInputRegions?.register(view)
        var chromeEnvironment = context.environment
        if destination.nativeShell { chromeEnvironment.nativeCanvasInputRegions = nil }
        var composerEnvironment = context.environment
        composerEnvironment.nativeCanvasInputRegions = nil
        view.configure(destination, chrome: AnyView(chrome.environment(\.self, chromeEnvironment)),
            composer: AnyView(composer.environment(\.self, composerEnvironment)),
            face: AnyView(face.environment(\.self, context.environment)),
            transaction: context.transaction, openInput: openInput, onHover: onHover)
    }
    static func dismantleNSView(_ view: MokuCapsuleMotionView, coordinator: ()) { view.retire() }
}

@MainActor final class MokuCapsuleMotionView: NSView, NativeCanvasInputRegionGeometry {
    private let shell = MokuInputShellView()
    private let chrome = MokuCapsuleSeat()
    private let composer = MokuCapsuleSeat()
    private let identity = MokuCapsuleSeat()
    private let aperture = CAShapeLayer()
    private let handle: NativeMokuCapsuleMotionHandle
    private var destination: NativeMokuCapsuleDestination?
    private var openInput: (() -> Void)?
    private var onHover: ((Bool) -> Void)?
    private var hovered = false
    private var tracking: NSTrackingArea?
    private var startShell: CGRect?
    private var startRadius: CGFloat?
    private var startFace: CGPoint?
    private var startOpacity: Float?
    private var startTranslation: CGFloat?
    private var pressedShell = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init(handle: NativeMokuCapsuleMotionHandle) {
        self.handle = handle
        super.init(frame: .zero)
        wantsLayer = true; clipsToBounds = false
        for view in [shell, chrome, composer, identity] { addSubview(view) }
        composer.layer?.mask = aperture
        handle.view = self
    }
    required init?(coder: NSCoder) { nil }

    private var visibleShell: CGRect {
        shell.layer?.presentation()?.frame
            ?? (shell.layer?.animation(forKey: "moku-bounds") != nil ? startShell : nil) ?? shell.frame
    }
    private var visibleFace: CGPoint {
        identity.layer?.presentation()?.position
            ?? (identity.layer?.animation(forKey: "moku-position") != nil ? startFace : nil) ?? identity.layer!.position
    }
    private var visibleRadius: CGFloat {
        shell.layer?.presentation()?.cornerRadius
            ?? (shell.layer?.animation(forKey: "moku-cornerRadius") != nil ? startRadius : nil)
            ?? shell.layer!.cornerRadius
    }
    private var visibleOpacity: Float {
        composer.layer?.presentation()?.opacity
            ?? (composer.layer?.animation(forKey: "moku-opacity") != nil ? startOpacity : nil) ?? composer.layer!.opacity
    }
    private var visibleTranslation: CGFloat {
        composer.layer?.presentation()?.transform.m42
            ?? (composer.layer?.animation(forKey: "moku-transform.translation.y") != nil ? startTranslation : nil) ?? 0
    }

    func configure(_ next: NativeMokuCapsuleDestination, chrome: AnyView, composer: AnyView,
                   face: AnyView, transaction: Transaction, openInput: @escaping () -> Void,
                   onHover: @escaping (Bool) -> Void) {
        let previous = destination
        let fromShell = visibleShell, fromRadius = visibleRadius, fromFace = visibleFace
        let fromOpacity = visibleOpacity, fromTranslation = visibleTranslation
        destination = next; self.openInput = openInput; self.onHover = onHover
        var discrete = transaction
        discrete.animation = nil
        self.chrome.update(chrome, transaction: discrete)
        self.composer.update(composer, transaction: discrete)
        identity.update(face, transaction: discrete)
        guard previous != next else { return }

        let immediate = previous == nil || next.immediate || window == nil
            || previous?.viewport != next.viewport
        // Note/Settings own their existing SwiftUI shell. At the handoff their
        // compact geometry agrees; keep these hosts mounted through both paths.
        let native = next.nativeShell && previous?.nativeShell == true
        let duration: TimeInterval = next.reading ? NativeReadingPageTiming.duration : 0.42
        let timing = next.reading ? NativeReadingPageTiming.emphasizedOpening
            : CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        let geometryChanged = previous?.shell != next.shell
        let faceChanged = previous?.face != next.face || previous?.faceScale != next.faceScale
        let inkChanged = previous?.composerVisible != next.composerVisible
        let settle = immediate || previous?.nativeShell != next.nativeShell
        let bounds = CGRect(origin: .zero, size: next.viewport)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        self.chrome.frame = bounds; self.composer.frame = bounds
        shell.isHidden = !next.nativeShell
        if geometryChanged || settle {
            shell.configure(frame: next.shell, from: native && !settle ? fromShell : nil,
                fromRadius: fromRadius,
                opaque: next.opaque, hovered: next.hovered, duration: duration, timing: timing)
            startShell = native && !settle ? fromShell : nil
            startRadius = native && !settle ? fromRadius : nil
            // The editor always lays out at its full destination width. Its
            // bottom edge alone follows a centred landing move/height change.
            let delta = immediate ? 0 : fromTranslation + (previous?.shell.maxY ?? next.shell.maxY) - next.shell.maxY
            animate(self.composer.layer!, key: "transform.translation.y", from: delta, to: CGFloat(0),
                duration: duration, timing: timing, immediate: immediate || abs(delta) < 0.01)
            startTranslation = immediate || abs(delta) < 0.01 ? nil : delta
            let newPath = Self.path(next.shell)
            aperture.path = newPath
            aperture.removeAnimation(forKey: "moku-path")
            if !immediate {
                // The mask is in the editor host's translated coordinates.
                // Its translation is compensated below so the visible aperture
                // and shell share the same scene-space outline throughout.
                let path = CABasicAnimation(keyPath: "path")
                path.fromValue = Self.path(fromShell, radius: fromRadius); path.toValue = newPath
                path.duration = duration; path.timingFunction = timing
                aperture.add(path, forKey: "moku-path")
            }
            // Opposite translation prevents moving the clip with the editor.
            animate(aperture, key: "transform.translation.y", from: -delta, to: CGFloat(0),
                duration: duration, timing: timing, immediate: immediate || abs(delta) < 0.01)
        } else if previous?.opaque != next.opaque || previous?.hovered != next.hovered {
            shell.configureMaterial(opaque: next.opaque, hovered: next.hovered)
        }
        if faceChanged || settle {
            let size = CGSize(width: NativeMokuFaceLayout.seat.width * next.faceScale,
                height: NativeMokuFaceLayout.seat.height * next.faceScale)
            identity.frame = CGRect(x: next.face.x - size.width / 2, y: next.face.y - size.height / 2,
                width: size.width, height: size.height)
            let target = identity.layer!.position
            animate(identity.layer!, key: "position", from: NSValue(point: fromFace), to: NSValue(point: target),
                duration: duration, timing: timing, immediate: immediate)
            startFace = immediate ? nil : fromFace
        }
        if inkChanged || settle {
            let opacity: Float = next.composerVisible ? 1 : 0
            self.composer.layer!.opacity = opacity
            animate(self.composer.layer!, key: "opacity", from: fromOpacity, to: opacity,
                duration: next.composerVisible ? duration : 0.12,
                timing: next.composerVisible ? (next.reading ? timing : CAMediaTimingFunction(name: .easeIn))
                    : CAMediaTimingFunction(name: .easeOut), immediate: immediate)
            startOpacity = immediate ? nil : fromOpacity
        }
        CATransaction.commit()
    }

    private func animate(_ layer: CALayer, key: String, from: Any, to: Any,
                         duration: TimeInterval, timing: CAMediaTimingFunction, immediate: Bool) {
        layer.removeAnimation(forKey: "moku-" + key)
        if key == "transform.translation.y" { layer.transform = CATransform3DIdentity }
        guard !immediate else { return }
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from; animation.toValue = to
        animation.duration = duration; animation.timingFunction = timing
        layer.add(animation, forKey: "moku-" + key)
    }

    private static func path(_ rect: CGRect, radius: CGFloat? = nil) -> CGPath {
        let radius = radius ?? min(NativeMokuCapsuleLayout.cornerRadius, rect.width / 2, rect.height / 2)
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    func containsViewportPoint(_ point: CGPoint) -> Bool? {
        guard let destination, destination.nativeShell, window != nil else { return nil }
        // Scene monitors use the outer full-viewport host. AppKit conversion
        // covers destination offsets; compositor travel needs its live delta.
        let local = travelOwner?.convertViewportPoint(point, to: self)
            ?? CGPoint(x: point.x - destination.viewportOffset.x, y: point.y - destination.viewportOffset.y)
        return Self.path(visibleShell, radius: visibleRadius).contains(local)
    }

    func containsCanvasInput(_ point: CGPoint, in window: NativePlatformWindow) -> Bool {
        guard self.window === window, destination?.nativeShell == true else { return false }
        let local = travelOwner?.convertWindowPoint(point, to: self) ?? convert(point, from: nil)
        return Self.path(visibleShell, radius: visibleRadius).contains(local)
    }

    var frameInViewport: CGRect? {
        guard let destination, destination.nativeShell else { return nil }
        return travelOwner?.convertCapsuleRect(visibleShell, from: self)
            ?? visibleShell.offsetBy(dx: destination.viewportOffset.x, dy: destination.viewportOffset.y)
    }

    private var travelOwner: MokuHorizontalTravelView? {
        var ancestor = superview
        while let view = ancestor {
            if let travel = view as? MokuHorizontalTravelView { return travel }
            ancestor = view.superview
        }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited], owner: self)
        tracking = area; addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        guard destination?.nativeShell == true, let window = event.window else { return }
        setHovered(containsCanvasInput(event.locationInWindow, in: window))
    }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    private func setHovered(_ value: Bool) {
        guard hovered != value else { return }
        hovered = value; onHover?(value)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let native = destination?.nativeShell == true
        if native, !Self.path(visibleShell, radius: visibleRadius).contains(local) { return nil }
        // Native event coordinates use model frames. During actual translation
        // absorb presses; during the ordinary reveal the editor never translates
        // and visible text/controls can already acquire focus and selection.
        if destination?.composerVisible == true, visibleOpacity > 0.05, abs(visibleTranslation) < 0.01,
           let hit = composer.hitTest(local), hit !== composer { return hit }
        // Stop and idle voice controls remain in chrome, not in the editor.
        // Their AppKit coordinates agree with the glass only after its morph
        // settles; until then the shell absorbs presses at the visible outline.
        if native, destination?.chromeControlsVisible == true, visibleShell == shell.frame,
           let hit = chrome.hitTest(local), hit !== chrome { return hit }
        // Layer opacity does not retire AppKit hit testing. In the other modes
        // explicitly bypass the transparent editor and passive identity hosts.
        return native ? self : chrome.hitTest(local)
    }
    override func mouseDown(with event: NSEvent) { pressedShell = true }
    override func mouseUp(with event: NSEvent) {
        defer { pressedShell = false }
        guard pressedShell, destination?.composerVisible == false,
              let window = event.window, containsCanvasInput(event.locationInWindow, in: window) else { return }
        openInput?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { settle() }
    }
    private func settle() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shell.settle()
        identity.layer?.removeAllAnimations(); composer.layer?.removeAllAnimations(); aperture.removeAllAnimations()
        startShell = nil; startRadius = nil; startFace = nil; startOpacity = nil; startTranslation = nil
        CATransaction.commit()
    }
    func retire() {
        settle(); destination = nil; openInput = nil; onHover = nil
        if handle.view === self { handle.view = nil }
    }
}

@MainActor private final class MokuCapsuleSeat: NSView {
    private let state = MokuCapsuleContentState()
    private lazy var hosting = NSHostingView(rootView: MokuCapsuleContent(state: state))
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; clipsToBounds = false
        layer?.anchorPoint = .zero
        hosting.sizingOptions = []; hosting.safeAreaRegions = []; hosting.clipsToBounds = false
        addSubview(hosting)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    func update(_ content: AnyView, transaction: Transaction) {
        withTransaction(transaction) { state.content = content }
    }
    override func layout() {
        super.layout()
        if hosting.frame != bounds { hosting.frame = bounds }
    }
}

@MainActor @Observable private final class MokuCapsuleContentState {
    var content = AnyView(EmptyView())
}
private struct MokuCapsuleContent: View {
    let state: MokuCapsuleContentState
    var body: some View {
        state.content.coordinateSpace(name: "native-moku-dock").coordinateSpace(name: "workspace")
    }
}

/// Native clear glass and the capsule's existing warm gradient/stroke. Only
/// these passive material layers resize; glyphs never inherit a scale transform.
@MainActor private final class MokuInputShellView: NSView {
    private let glass = NSGlassEffectView()
    private let tint = CAGradientLayer()
    private let rim = CAGradientLayer()
    private let tintClip = CAShapeLayer()
    private let rimClip = CAShapeLayer()
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; clipsToBounds = false; layer?.anchorPoint = .zero
        glass.style = .clear; glass.cornerRadius = NativeMokuCapsuleLayout.cornerRadius
        glass.appearance = NSAppearance(named: .darkAqua)
        addSubview(glass)
        let strength = 0.85
        tint.colors = [NSColor.black.withAlphaComponent(0.99 * strength).cgColor,
            NSColor(srgbRed: 0.04, green: 0.035, blue: 0.03, alpha: 0.96 * strength).cgColor,
            NSColor(srgbRed: 0.16, green: 0.13, blue: 0.10, alpha: 0.70 * strength).cgColor,
            NSColor(srgbRed: 0.38, green: 0.33, blue: 0.26, alpha: 0.12 * strength).cgColor]
        tint.locations = [0, 0.40, 0.72, 1]
        rim.colors = [NSColor.white.withAlphaComponent(0.04 * strength).cgColor,
            NSColor.white.withAlphaComponent(0.08 * strength).cgColor,
            NSColor(srgbRed: 1, green: 0.92, blue: 0.78, alpha: 0.65 * strength).cgColor]
        rim.locations = [0, 0.55, 1]
        for gradient in [tint, rim] {
            gradient.startPoint = CGPoint(x: 0.5, y: 0); gradient.endPoint = CGPoint(x: 0.5, y: 1)
            layer!.addSublayer(gradient)
        }
        tint.mask = tintClip; rim.mask = rimClip
        rimClip.fillColor = nil; rimClip.strokeColor = NSColor.white.cgColor; rimClip.lineWidth = 0.8
        layer?.shadowColor = NSColor.black.cgColor; layer?.shadowOpacity = 0.13
        layer?.shadowOffset = CGSize(width: 0, height: 6)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    func configureMaterial(opaque: Bool, hovered: Bool) {
        glass.isHidden = opaque; tint.isHidden = opaque; rim.isHidden = opaque
        layer?.backgroundColor = opaque ? NSColor(srgbRed: 0.12, green: 0.11, blue: 0.10, alpha: 1).cgColor : nil
        layer?.cornerRadius = min(NativeMokuCapsuleLayout.cornerRadius, bounds.width / 2, bounds.height / 2)
        layer?.shadowRadius = hovered ? 17 : 13
    }

    func configure(frame target: CGRect, from source: CGRect?, fromRadius: CGFloat, opaque: Bool, hovered: Bool,
                   duration: TimeInterval, timing: CAMediaTimingFunction) {
        let previousSize = source?.size
        settle()
        frame = target
        configureMaterial(opaque: opaque, hovered: hovered)
        let rect = CGRect(origin: .zero, size: target.size)
        let radius = min(NativeMokuCapsuleLayout.cornerRadius, target.width / 2, target.height / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        layer?.shadowPath = path
        glass.frame = rect
        for gradient in [tint, rim] { gradient.frame = rect }
        tintClip.path = path
        rimClip.path = CGPath(roundedRect: rect.insetBy(dx: 0.4, dy: 0.4),
            cornerWidth: max(0, radius - 0.4), cornerHeight: max(0, radius - 0.4), transform: nil)
        guard let source, let previousSize else { return }
        let sourceRect = CGRect(origin: .zero, size: previousSize)
        let sourceRadius = fromRadius
        func animate(_ layer: CALayer, _ key: String, _ from: Any, _ to: Any) {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = from; animation.toValue = to
            animation.duration = duration; animation.timingFunction = timing
            layer.add(animation, forKey: "moku-" + key)
        }
        animate(layer!, "position", NSValue(point: source.origin), NSValue(point: target.origin))
        animate(layer!, "bounds", NSValue(rect: sourceRect), NSValue(rect: rect))
        animate(layer!, "cornerRadius", sourceRadius, radius)
        let oldPath = CGPath(roundedRect: sourceRect, cornerWidth: sourceRadius, cornerHeight: sourceRadius, transform: nil)
        animate(layer!, "shadowPath", oldPath, path)
        for gradient in [tint, rim] {
            animate(gradient, "bounds", NSValue(rect: sourceRect), NSValue(rect: rect))
            animate(gradient, "position", NSValue(point: CGPoint(x: source.width / 2, y: source.height / 2)),
                NSValue(point: CGPoint(x: target.width / 2, y: target.height / 2)))
        }
        animate(tintClip, "path", oldPath, path)
        animate(rimClip, "path", CGPath(roundedRect: sourceRect.insetBy(dx: 0.4, dy: 0.4),
            cornerWidth: max(0, sourceRadius - 0.4), cornerHeight: max(0, sourceRadius - 0.4), transform: nil), rimClip.path!)
        // AppKit propagates the frame animation into the glass effect's private
        // material layers. A transform on the whole SwiftUI tree would stretch
        // the native editor and cannot preserve its selection/IME coordinates.
        glass.frame = sourceRect
        glass.cornerRadius = sourceRadius
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration; context.timingFunction = timing; context.allowsImplicitAnimation = true
            glass.animator().frame = rect
            glass.animator().cornerRadius = radius
        }
    }
    func settle() {
        layer?.removeAllAnimations(); glass.layer?.removeAllAnimations()
        for layer in [tint, rim, tintClip, rimClip] { layer.removeAllAnimations() }
    }
}
