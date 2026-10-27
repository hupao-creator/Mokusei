import MokuseiPluginUI
import AppKit

public enum MokuCharacterMode: Equatable, Sendable {
    case idle, running, tool, reply
    case namedTool(String)
    case operation(activity: String, phase: String)
    case permission, question, message(String)

    public var layout: MokuLayout {
        switch self { case .permission: .permission; case .question: .question; case .message: .message; default: .mark }
    }
}

/// A prepared additive eye track, expressed in the character's original
/// 640-unit coordinate space. Copies retain the absolute source clock so a
/// cross-surface flight continues the live gesture until its owner cancels it.
public struct MokuEyeMotion: Equatable, Sendable {
    public struct Frame: Equatable, Sendable {
        public var atMilliseconds: Double
        public var offset: CGPoint
        public init(atMilliseconds: Double, offset: CGPoint) {
            self.atMilliseconds = atMilliseconds; self.offset = offset
        }
    }
    public var points: [Frame]
    public var durationMilliseconds: Double
    public var startedAtMilliseconds: Double
    public init(points: [Frame], durationMilliseconds: Double,
                startedAtMilliseconds: Double = ProcessInfo.processInfo.systemUptime * 1000) {
        self.points = points; self.durationMilliseconds = durationMilliseconds
        self.startedAtMilliseconds = startedAtMilliseconds
    }
    public func sample(nowMilliseconds: Double) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let elapsed = nowMilliseconds - startedAtMilliseconds
        let index = points.lastIndex { $0.atMilliseconds <= elapsed } ?? 0
        let from = points[index], to = points[min(index + 1, points.count - 1)]
        let interval = to.atMilliseconds - from.atMilliseconds
        let p = interval > 0 ? min(1, max(0, (elapsed - from.atMilliseconds) / interval)) : 0
        let eased = p * p * (3 - 2 * p)
        return CGPoint(x: from.offset.x + (to.offset.x - from.offset.x) * eased,
            y: from.offset.y + (to.offset.y - from.offset.y) * eased)
    }
    public func isActive(nowMilliseconds: Double) -> Bool {
        !points.isEmpty && nowMilliseconds < startedAtMilliseconds + durationMilliseconds
    }
}

public struct MokuSpring: Sendable {
    public var value: Double
    public var velocity: Double = 0
    public init(_ value: Double, velocity: Double = 0) { self.value = value; self.velocity = velocity }
    @discardableResult public mutating func advance(to target: Double, frameScale: Double, stiffness: Double, damping: Double) -> Double {
        velocity += (target - value) * stiffness * frameScale
        velocity *= pow(damping, frameScale)
        value += velocity * frameScale
        return value
    }
    public func settled(at target: Double, tolerance: Double = 0.001) -> Bool {
        abs(value - target) < tolerance && abs(velocity) < tolerance
    }
}

public struct MokuAnimatedPoint: Sendable {
    public var x, y: MokuSpring
    public var point: CGPoint { CGPoint(x: x.value, y: y.value) }
    public init(_ point: CGPoint) { x = MokuSpring(point.x); y = MokuSpring(point.y) }
}

public struct MokuAnimatedEye: Sendable {
    public var x, y, w, h, radius, rotation, opacity: MokuSpring
    public init(_ eye: MokuEye) {
        x = MokuSpring(eye.x); y = MokuSpring(eye.y); w = MokuSpring(eye.w); h = MokuSpring(eye.h)
        radius = MokuSpring(eye.radius); rotation = MokuSpring(eye.rotation); opacity = MokuSpring(eye.opacity)
    }
    public var eye: MokuEye { .init(x: x.value, y: y.value, w: w.value, h: h.value, radius: radius.value, rotation: rotation.value, opacity: opacity.value) }
    mutating func advance(to source: MokuEye, blink: Double, faceOpacity: Double, scale: Double, gazeX: Double, gazeY: Double) {
        x.advance(to: source.x + gazeX, frameScale: scale, stiffness: 0.12, damping: 0.82)
        y.advance(to: source.y + gazeY, frameScale: scale, stiffness: 0.12, damping: 0.82)
        w.advance(to: source.w, frameScale: scale, stiffness: 0.12, damping: 0.82)
        h.advance(to: source.h * blink, frameScale: scale, stiffness: 0.12, damping: 0.82)
        radius.advance(to: source.radius, frameScale: scale, stiffness: 0.12, damping: 0.82)
        rotation.advance(to: source.rotation, frameScale: scale, stiffness: 0.12, damping: 0.82)
        opacity.advance(to: source.opacity * faceOpacity, frameScale: scale, stiffness: 0.12, damping: 0.82)
    }
    func settled(at eye: MokuEye, faceOpacity: Double) -> Bool {
        x.settled(at: eye.x) && y.settled(at: eye.y) && w.settled(at: eye.w) && h.settled(at: eye.h)
        && radius.settled(at: eye.radius) && rotation.settled(at: eye.rotation) && opacity.settled(at: eye.opacity * faceOpacity)
    }
}

/// Value-semantic animation state: copying this model preserves geometry, spring
/// velocity and all gesture clocks when a character moves between native seats.
public struct MokuCharacterModel: Sendable {
    public private(set) var mode: MokuCharacterMode
    public private(set) var expression: MokuExpression
    public private(set) var shape: MokuShape
    public private(set) var layout: MokuLayout
    public private(set) var body: [MokuAnimatedPoint]
    public private(set) var satellite: [MokuAnimatedPoint]
    public private(set) var leftEye, rightEye: MokuAnimatedEye
    public private(set) var satelliteOpacity: MokuSpring
    public private(set) var orbitOpacity: MokuSpring
    public private(set) var thoughtRadius: MokuSpring
    public private(set) var lastFrameAt: Double
    public private(set) var blinkStarted = -Double.infinity
    public private(set) var nextNaturalBlink: Double
    public private(set) var bounceStarted = -Double.infinity
    public private(set) var nodStarted = -Double.infinity
    public private(set) var nextSweepAt: Double
    public private(set) var returnAt: Double = 0
    public private(set) var gazeX = MokuSpring(0), gazeY = MokuSpring(0)
    private var gazeTargetX: Double = 0, gazeTargetY: Double = 0
    private var bodyTargets: [CGPoint], satelliteTargets: [CGPoint]
    private var thought: Bool, orbit: Bool, eagerBlink: Bool
    private var identity: String
    private var orbitClockOffset = 0.0

    public init(mode: MokuCharacterMode = .idle, now: Double = ProcessInfo.processInfo.systemUptime * 1000, identity: String = "") {
        let description = Self.descriptor(mode)
        self.mode = mode; expression = description.expression; shape = description.shape
        layout = mode.layout; self.identity = identity
        thought = description.thought; orbit = description.orbit; eagerBlink = description.eagerBlink
        bodyTargets = MokuGeometry.buildShape(shape, layout: layout)
        satelliteTargets = MokuGeometry.satellite(visible: shape == .mark && layout == .mark)
        body = bodyTargets.map(MokuAnimatedPoint.init); satellite = satelliteTargets.map(MokuAnimatedPoint.init)
        satelliteOpacity = MokuSpring(shape == .mark && layout == .mark ? 1 : 0)
        orbitOpacity = MokuSpring(orbit ? 1 : 0); thoughtRadius = MokuSpring(thought ? 19 : 0)
        let eyes = MokuGeometry.eyes(expression, layout: layout)
        leftEye = MokuAnimatedEye(eyes.left); rightEye = MokuAnimatedEye(eyes.right)
        if shape == .mark && layout == .mark { leftEye.opacity.value = 0; rightEye.opacity.value = 0 }
        lastFrameAt = now; nextNaturalBlink = now + Self.blinkDelay(eager: eagerBlink, first: true)
        nextSweepAt = now + Double.random(in: 2200..<4800)
        if description.action == "bounce" { bounceStarted = now }
        if description.action == "nod" { nodStarted = now }
    }

    public mutating func update(mode: MokuCharacterMode, identity: String = "", now: Double) {
        let changed = self.mode != mode || self.identity != identity
        let description = Self.descriptor(mode)
        self.mode = mode; self.identity = identity; self.layout = mode.layout
        expression = description.expression; shape = description.shape
        bodyTargets = MokuGeometry.buildShape(shape, layout: layout)
        satelliteTargets = MokuGeometry.satellite(visible: showsSatellite)
        thought = description.thought; orbit = description.orbit
        if eagerBlink != description.eagerBlink {
            eagerBlink = description.eagerBlink; nextNaturalBlink = now + Self.blinkDelay(eager: eagerBlink)
        }
        guard changed else { return }
        if description.action == "bounce" { bounceStarted = now }
        if description.action == "nod" { nodStarted = now }
        if expression != .idle {
            gazeTargetX = 0; gazeTargetY = 0; returnAt = 0
            nextSweepAt = now + Double.random(in: 2200..<4800)
        }
    }

    /// Rebase absolute gesture deadlines after a hidden surface or saved-seat pause.
    public mutating func shiftClock(by delta: Double) {
        guard delta.isFinite && delta > 0 else { return }
        lastFrameAt += delta; nextNaturalBlink += delta; nextSweepAt += delta
        if blinkStarted.isFinite { blinkStarted += delta }
        if bounceStarted.isFinite { bounceStarted += delta }
        if nodStarted.isFinite { nodStarted += delta }
        if returnAt > 0 { returnAt += delta }
        if orbit || orbitOpacity.value > 0.001 { orbitClockOffset += delta }
    }

    public mutating func snapToTargets(now: Double) {
        body = bodyTargets.map(MokuAnimatedPoint.init); satellite = satelliteTargets.map(MokuAnimatedPoint.init)
        satelliteOpacity = MokuSpring(showsSatellite ? 1 : 0)
        orbitOpacity = MokuSpring(orbit ? 1 : 0); thoughtRadius = MokuSpring(thought && shape != .mark ? 19 : 0)
        let eyes = MokuGeometry.eyes(expression, layout: layout)
        leftEye = MokuAnimatedEye(eyes.left); rightEye = MokuAnimatedEye(eyes.right)
        if showsSatellite { leftEye.opacity.value = 0; rightEye.opacity.value = 0 }
        gazeX = MokuSpring(0); gazeY = MokuSpring(0); gazeTargetX = 0; gazeTargetY = 0
        blinkStarted = -.infinity; bounceStarted = -.infinity; nodStarted = -.infinity; lastFrameAt = now
    }

    public mutating func advance(now: Double) {
        let frameScale = min(34, max(0, now - lastFrameAt)) / (1000 / 60)
        lastFrameAt = now
        if now >= nextNaturalBlink && shape != .mark {
            blinkStarted = now; nextNaturalBlink = now + Self.blinkDelay(eager: eagerBlink)
        }
        Self.advancePoints(&body, targets: bodyTargets, scale: frameScale)
        Self.advancePoints(&satellite, targets: satelliteTargets, scale: frameScale)
        satelliteOpacity.advance(to: showsSatellite ? 1 : 0, frameScale: frameScale, stiffness: 0.18, damping: 0.76)
        let progress = (now - blinkStarted) / 320
        let blink = progress >= 0 && progress <= 1 ? 1 - sin(progress * .pi) * 0.91 : 1
        if expression == .idle && now >= nextSweepAt && returnAt <= now {
            gazeTargetX = Double.random(in: -4.5...4.5); gazeTargetY = Double.random(in: -3...3)
            returnAt = now + 320; nextSweepAt = now + 320 + 620
        }
        if expression == .idle && returnAt > 0 && now >= returnAt {
            gazeTargetX = 0; gazeTargetY = 0; returnAt = 0; nextSweepAt = now + Double.random(in: 2200..<4800)
        }
        if expression != .idle { gazeTargetX = 0; gazeTargetY = 0; returnAt = 0 }
        gazeX.advance(to: gazeTargetX, frameScale: frameScale, stiffness: 0.095, damping: 0.84)
        gazeY.advance(to: gazeTargetY, frameScale: frameScale, stiffness: 0.095, damping: 0.84)
        let eyes = MokuGeometry.eyes(expression, layout: layout), faceOpacity: Double = showsSatellite ? 0 : 1
        leftEye.advance(to: eyes.left, blink: blink, faceOpacity: faceOpacity, scale: frameScale, gazeX: gazeX.value, gazeY: gazeY.value)
        rightEye.advance(to: eyes.right, blink: blink, faceOpacity: faceOpacity, scale: frameScale, gazeX: gazeX.value, gazeY: gazeY.value)
        thoughtRadius.advance(to: thought && shape != .mark ? 19 : 0, frameScale: frameScale, stiffness: 0.18, damping: 0.74)
        orbitOpacity.advance(to: orbit ? 1 : 0, frameScale: frameScale, stiffness: 0.1, damping: 0.82)
    }

    /// Returns an absolute millisecond deadline. Settled idle seats have no display
    /// link; only the next blink or gaze wakes them, matching the worker scheduler.
    public func nextWake(now: Double) -> Double {
        if orbit || now - bounceStarted < 1150 || now - nodStarted < 1050 || now - blinkStarted < 320 { return now }
        if !Self.pointsSettled(body, at: bodyTargets) || !Self.pointsSettled(satellite, at: satelliteTargets) { return now }
        if !satelliteOpacity.settled(at: showsSatellite ? 1 : 0) || !orbitOpacity.settled(at: orbit ? 1 : 0)
            || !thoughtRadius.settled(at: thought && shape != .mark ? 19 : 0)
            || !gazeX.settled(at: gazeTargetX) || !gazeY.settled(at: gazeTargetY) { return now }
        var eyes = MokuGeometry.eyes(expression, layout: layout)
        eyes.left.x += gazeTargetX; eyes.left.y += gazeTargetY
        eyes.right.x += gazeTargetX; eyes.right.y += gazeTargetY
        if !leftEye.settled(at: eyes.left, faceOpacity: showsSatellite ? 0 : 1)
            || !rightEye.settled(at: eyes.right, faceOpacity: showsSatellite ? 0 : 1) { return now }
        let blink = shape == .mark ? Double.infinity : nextNaturalBlink
        let gaze = expression == .idle ? (returnAt > now ? returnAt : nextSweepAt) : Double.infinity
        return min(blink, gaze)
    }

    public var viewport: CGRect {
        switch layout {
        case .permission: CGRect(x: 20, y: 110, width: 760, height: 380)
        case .question: CGRect(x: 20, y: 50, width: 760, height: 500)
        case .message: CGRect(x: 20, y: 100, width: 780, height: 400)
        case .mark: CGRect(x: 0, y: 0, width: 640, height: 640)
        }
    }
    public var showsSatellite: Bool { shape == .mark && layout == .mark }

    public func paint(in context: CGContext, now: Double, running: MokuRunningFrame? = nil,
                      launch: MokuLaunchFrame? = nil, launchCapsule: MokuLaunchCapsule? = nil, launchElapsed: Double = 0,
                      eyeOffset: CGPoint = .zero, material: MokuBodyMaterial? = nil) {
        paintOrbits(in: context, now: now)
        context.saveGState()
        if let launch, !launch.running {
            if let launchCapsule {
                let offset = MokuLaunchStory.bodyOffset(launchCapsule, elapsed: launchElapsed)
                context.translateBy(x: offset.x, y: offset.y)
            }
            context.translateBy(x: 320, y: 450 + launch.bodyDrop)
            context.scaleBy(x: launch.bodyX, y: launch.bodyY); context.translateBy(x: -320, y: -450)
        }
        context.concatenate(bodyTransform(now: now))
        MokuBodyMaterial.fill(MokuGeometry.path(body.map(\.point), tension: layout == .permission ? 0 : layout == .mark ? 0.82 : 1),
                              in: context, material: material)
        MokuBodyMaterial.fill(MokuGeometry.path(satellite.map(\.point), tension: 0.72),
                              in: context, opacity: Self.clamp(satelliteOpacity.value), material: material)
        context.saveGState()
        if let running {
            context.translateBy(x: running.eyes.x, y: running.eyes.y)
            context.translateBy(x: 320, y: 250); context.scaleBy(x: running.eyes.scaleX, y: running.eyes.scaleY)
            context.translateBy(x: -320, y: -250)
        } else if eyeOffset != .zero {
            // Prepared coordinator eye tracks use the original 640-unit
            // character space and add to the natural gaze/blink pose. Running
            // choreography retains ownership of its own eye transforms.
            context.translateBy(x: eyeOffset.x, y: eyeOffset.y)
        }
        Self.paintEye(leftEye.eye, in: context); Self.paintEye(rightEye.eye, in: context)
        context.restoreGState()
        if thoughtRadius.value > 0.001 {
            let radius = max(0, thoughtRadius.value)
            context.addEllipse(in: CGRect(x: 477 - radius, y: 178 - radius, width: radius * 2, height: radius * 2))
            context.setFillColor(NativePlatformPalette.color(mode == .tool ? 0x34c759 : 0x249cff).cgColor)
            context.setStrokeColor(MokuGeometry.eyeColor.cgColor); context.setLineWidth(8)
            context.drawPath(using: .fillStroke)
        }
        context.restoreGState()
        if let launchCapsule, launchElapsed < MokuLaunchStory.capsuleDotAt {
            let capsule = MokuLaunchStory.capsule(launchCapsule, elapsed: launchElapsed)
            let shadowTransform = context.ctm
            context.saveGState(); context.setAlpha(capsule.opacity); context.setFillColor(capsule.color.cgColor)
            context.setShadow(offset: CGSize(width: shadowTransform.c * 8 * (1 - capsule.tint), height: shadowTransform.d * 8 * (1 - capsule.tint)),
                              blur: 20 * hypot(shadowTransform.a, shadowTransform.b) * (1 - capsule.tint),
                              color: MokuGeometry.color(red: 16 / 255, green: 17 / 255, blue: 15 / 255, alpha: 0.22 * (1 - capsule.tint)).cgColor)
            context.addPath(CGPath(roundedRect: capsule.rect, cornerWidth: capsule.radius, cornerHeight: capsule.radius, transform: nil))
            context.fillPath(); context.restoreGState()
        }
        for dot in running?.dots ?? [] {
            context.saveGState(); context.setAlpha(dot.opacity); context.setFillColor(dot.color.cgColor)
            let radius = MokuRunningStory.dotRadius * dot.scale
            context.fillEllipse(in: CGRect(x: dot.x - radius, y: dot.y - radius, width: radius * 2, height: radius * 2))
            context.restoreGState()
        }
    }

    public static func paintEye(_ eye: MokuEye, in context: CGContext) {
        context.saveGState(); context.setAlpha(clamp(eye.opacity)); context.setFillColor(MokuGeometry.eyeColor.cgColor)
        context.translateBy(x: 320 + eye.x, y: 300 + eye.y); context.rotate(by: eye.rotation * .pi / 180)
        let w = max(0.2, eye.w), h = max(0.2, eye.h), r = max(0, min(eye.radius, w / 2, h / 2))
        context.addPath(CGPath(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil))
        context.fillPath(); context.restoreGState()
    }

    public func paintedPose(now: Double) -> MokuPaintedPose {
        let transform = bodyTransform(now: now)
        func point(_ point: CGPoint) -> CGPoint { point.applying(transform) }
        func eye(_ source: MokuEye) -> MokuEye {
            let angle = source.rotation * .pi / 180
            let center = point(CGPoint(x: 320 + source.x, y: 300 + source.y))
            let right = point(CGPoint(x: 320 + source.x + cos(angle), y: 300 + source.y + sin(angle)))
            let down = point(CGPoint(x: 320 + source.x - sin(angle), y: 300 + source.y + cos(angle)))
            let sx = hypot(right.x - center.x, right.y - center.y), sy = hypot(down.x - center.x, down.y - center.y)
            return MokuEye(x: center.x - 320, y: center.y - 300, w: source.w * sx, h: source.h * sy,
                radius: source.radius * min(sx, sy), rotation: atan2(right.y - center.y, right.x - center.x) * 180 / .pi, opacity: source.opacity)
        }
        var result = MokuPaintedPose(body: body.map { point($0.point) }, satellite: satellite.map { point($0.point) },
                                    leftEye: eye(leftEye.eye), rightEye: eye(rightEye.eye))
        result.satelliteOpacity = satelliteOpacity.value; result.orbitOpacity = orbitOpacity.value; result.orbitAt = now - orbitClockOffset
        result.thoughtRadius = thoughtRadius.value; result.blinkStarted = blinkStarted; result.nextNaturalBlink = nextNaturalBlink; result.eagerBlink = eagerBlink
        let center = point(CGPoint(x: 320, y: 300)), right = point(CGPoint(x: 321, y: 300))
        result.frame = .init(x: center.x, y: center.y, angle: atan2(right.y - center.y, right.x - center.x) * 180 / .pi)
        let token = point(CGPoint(x: 477, y: 178)), edge = point(CGPoint(x: 477 + thoughtRadius.value, y: 178))
        result.token = .init(x: token.x, y: token.y, radius: hypot(edge.x - token.x, edge.y - token.y), opacity: thoughtRadius.value > 0.001 ? 1 : 0)
        return result
    }

    /// A semantic switch adopts the displayed geometry and its absolute blink
    /// clocks. Gesture transforms are already baked in, so do not apply them twice.
    public mutating func adopt(_ pose: MokuPaintedPose, now: Double) {
        body = pose.body.map(MokuAnimatedPoint.init); satellite = pose.satellite.map(MokuAnimatedPoint.init)
        leftEye = MokuAnimatedEye(pose.leftEye); rightEye = MokuAnimatedEye(pose.rightEye)
        satelliteOpacity = MokuSpring(pose.satelliteOpacity); orbitOpacity = MokuSpring(pose.orbitOpacity)
        thoughtRadius = MokuSpring(pose.thoughtRadius)
        blinkStarted = pose.blinkStarted; nextNaturalBlink = pose.nextNaturalBlink; eagerBlink = pose.eagerBlink
        bounceStarted = -.infinity; nodStarted = -.infinity; lastFrameAt = now
        gazeX = MokuSpring(0); gazeY = MokuSpring(0); gazeTargetX = 0; gazeTargetY = 0; returnAt = 0
    }

    private func bodyTransform(now: Double) -> CGAffineTransform {
        let bounceProgress = Self.clamp((now - bounceStarted) / 1150), nodProgress = Self.clamp((now - nodStarted) / 1050)
        let envelope = bounceProgress < 1 ? 1 - bounceProgress : 0
        let wave = bounceProgress < 1 ? abs(sin(bounceProgress * .pi * 2.35)) : 0
        let squash = 0.08 * sin(bounceProgress * .pi * 4.7) * envelope
        let nod = nodProgress < 1 ? sin(nodProgress * .pi * 4) * 10 * (1 - nodProgress) : 0
        let rotation = nod + (orbit ? ((now - orbitClockOffset) / 20).truncatingRemainder(dividingBy: 360) : 0)
        let pivot = layout == .mark ? CGPoint(x: 320, y: 300) : layout == .message ? CGPoint(x: 405, y: 310) : CGPoint(x: 400, y: 300)
        return CGAffineTransform(translationX: pivot.x, y: pivot.y)
            .translatedBy(x: 0, y: -72 * wave * envelope).rotated(by: rotation * .pi / 180)
            .scaledBy(x: 1 + squash, y: 1 - squash).translatedBy(x: -pivot.x, y: -pivot.y)
    }

    private func paintOrbits(in context: CGContext, now: Double) {
        let now = now - orbitClockOffset
        guard orbitOpacity.value > 0.001 else { return }
        context.saveGState(); context.setAlpha(Self.clamp(orbitOpacity.value))
        context.translateBy(x: 320, y: 314); context.rotate(by: (now / 29).truncatingRemainder(dividingBy: 360) * .pi / 180)
        context.setLineWidth(10); context.setLineCap(.round)
        let colors: [UInt32] = [0xee787e, 0x69cdb6, 0x74aef5, 0xbd7ce4, 0xd9c957]
        for (index, angle) in [8.0, 54, 102, 146, 194].enumerated() {
            context.saveGState(); context.rotate(by: angle * .pi / 180)
            context.setStrokeColor(NativePlatformPalette.color(colors[index]).cgColor)
            context.setLineDash(phase: -((now * (0.14 + Double(index) * 0.018) + Double(index) * 175).truncatingRemainder(dividingBy: 1190)), lengths: [190, 1000])
            context.strokeEllipse(in: CGRect(x: -224, y: -88, width: 448, height: 176)); context.restoreGState()
        }
        context.restoreGState()
    }

    private static func advancePoints(_ points: inout [MokuAnimatedPoint], targets: [CGPoint], scale: Double) {
        for index in points.indices {
            if points[index].x.settled(at: targets[index].x) && points[index].y.settled(at: targets[index].y) {
                points[index] = MokuAnimatedPoint(targets[index]); continue
            }
            points[index].x.advance(to: targets[index].x, frameScale: scale, stiffness: 0.12, damping: 0.82)
            points[index].y.advance(to: targets[index].y, frameScale: scale, stiffness: 0.12, damping: 0.82)
        }
    }
    private static func pointsSettled(_ points: [MokuAnimatedPoint], at targets: [CGPoint]) -> Bool {
        points.indices.allSatisfy { points[$0].x.settled(at: targets[$0].x) && points[$0].y.settled(at: targets[$0].y) }
    }
    private static func blinkDelay(eager: Bool, first: Bool = false) -> Double {
        eager ? Double.random(in: 1400..<2600) : first ? 3600 : Double.random(in: 3400..<6000)
    }
    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
    private struct Descriptor { var expression: MokuExpression = .idle; var shape: MokuShape = .circle; var action = "none"; var thought = false; var orbit = false; var eagerBlink = false }
    private static func descriptor(_ mode: MokuCharacterMode) -> Descriptor {
        switch mode {
        case .permission: return Descriptor(expression: .focus)
        case .question: return Descriptor(expression: .curious)
        case .tool, .namedTool: return Descriptor(thought: true)
        case .operation(let activity, let phase):
            if phase == "failed" || phase == "cancelled" { return Descriptor() }
            if activity == "start" { return Descriptor(expression: .focus) }
            if phase == "completed" { return Descriptor() }
            switch activity {
            case "tool": return Descriptor(thought: true)
            case "thinking": return Descriptor(expression: .curious, thought: true, eagerBlink: true)
            case "list": return Descriptor(expression: .focus, shape: .hex, orbit: true)
            case "send": return Descriptor(expression: .happy, shape: .drop, action: "bounce")
            case "status": return Descriptor(expression: .curious, shape: .hex, thought: true)
            case "interrupt": return Descriptor(shape: .mark, action: "nod")
            case "delete": return Descriptor(expression: .sleepy, shape: .drop)
            default: return Descriptor()
            }
        default: return Descriptor()
        }
    }
}
