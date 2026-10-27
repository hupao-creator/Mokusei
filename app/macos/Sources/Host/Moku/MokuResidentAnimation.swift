import CoreGraphics
import Foundation

/// One logical clock owns the resident face and decorations.
/// Copying this struct captures the entire state for cross-surface handoffs.
@MainActor public struct MokuResidentAnimation {
    private var transition = MokuResidentTransition()
    private var content = MokuResidentContent()
    private var clock = 0.0
    private var lastWall: Double
    private var nextBlink = 3400.0
    private var blinkAt = -Double.infinity
    private var scope = ""
    private var role: MokuResidentRole
    private var toolName = ""
    private var launching = false
    private var decorationOpacity = 1.0
    private var suspension: Suspension?
    private var resumption: Resumption?
    public private(set) var displayedPose: MokuResidentPose
    public private(set) var blinkFactor = 1.0
    public var handoffProgress: Double {
        resumption.map { mokuResidentSmooth((clock - $0.at) / 550) } ?? 1
    }

    private struct Suspension {
        var elapsed: Double
        var lastWall: Double
        var decorationFrom: Double
    }
    private struct Resumption {
        var at: Double
        var decorationFrom: Double
    }

    public init(role: MokuResidentRole = .idle, now: Double) {
        self.role = role; lastWall = now
        var initial = MokuResidentTransition()
        initial.settle(role: role, time: 0)
        transition = initial
        displayedPose = initial.sample(time: 0)
    }

    public mutating func update(role: MokuResidentRole, scope: String, toolName: String = "",
                                now: Double, active: Bool = true) {
        if !active { lastWall = now }
        if scope != self.scope {
            content = MokuResidentContent()
            transition.settle(role: role, time: clock)
        }
        if role != transition.role {
            transition.redirect(role: role, time: clock, duration: 550)
        }
        self.role = role; self.scope = scope; self.toolName = toolName
    }

    /// Pause resident time while a dedicated program owns Moku. Decorations
    /// fade on a separate clock so background activity cannot advance decorations.
    public mutating func suspend(now: Double) {
        lastWall = now
        suspension = Suspension(elapsed: 0, lastWall: now, decorationFrom: decorationOpacity)
        resumption = nil
    }

    /// The scene owner blends its captured body/token into displayedPose using
    /// the same 550 ms curve while this state restores the resident decorations.
    public mutating func resume(now: Double) {
        lastWall = now; suspension = nil
        resumption = Resumption(at: clock, decorationFrom: decorationOpacity)
    }

    public mutating func paintSuspended(in context: CGContext, now: Double, active: Bool = true) {
        guard var value = suspension else { return }
        value.elapsed += active ? max(0, min(64, now - value.lastWall)) : 0
        value.lastWall = now
        suspension = value
        decorationOpacity = value.decorationFrom * (1 - mokuResidentSmooth(value.elapsed / 550))
        if decorationOpacity > 0.001 {
            MokuResidentPainter.paint(in: context, pose: displayedPose, content: content, blink: blinkFactor,
                                      body: false, token: false, decorationOpacity: decorationOpacity)
        }
    }

    public mutating func launchFrame(now: Double, elapsed: Double, finished: Bool) {
        if !finished {
            lastWall = now; launching = true
            resumption = nil; decorationOpacity = 1
            return
        }
        if launching {
            lastWall = now
            transition.settle(role: .running, time: clock, elapsed: elapsed)
            launching = false
        }
    }

    public func nextWake(now: Double) -> Double {
        if resumption != nil || transition.progress(time: clock) < 1 || transition.role == .running
            || clock - blinkAt < 320 { return now }
        return now + max(0, nextBlink - clock)
    }

    public mutating func advance(now: Double, active: Bool = true) {
        // Visibility suspension also freezes a decoration fade already in
        // progress, including when a captured state is restored later.
        if !active { suspension?.lastWall = now }
        let quiet = resumption == nil && transition.progress(time: clock) == 1
            && (transition.role == .idle || transition.role == .tool || transition.role == .reply)
        let dt = active && suspension == nil && !launching ? max(0, min(quiet ? 4200 : 64, now - lastWall)) : 0
        lastWall = now; clock += dt
        if role == .tool { content.toolName = toolName }
        if clock >= nextBlink {
            blinkAt = clock; nextBlink = clock + 4200
        }
        displayedPose = transition.sample(time: clock)
        let progress = (clock - blinkAt) / 320
        blinkFactor = progress < 0 || progress > 1 ? 1 : 1 - sin(progress * .pi) * 0.91
        if let value = resumption {
            let amount = mokuResidentSmooth((clock - value.at) / 550)
            decorationOpacity = mokuResidentMix(value.decorationFrom, 1, amount)
            if amount == 1 { resumption = nil }
        }
        if displayedPose["toolAlpha"] < 0.001 && role != .tool { content.toolName = "" }
    }

    /// Paint in the original 640 × 640, downward-positive coordinate system.
    public func paint(in context: CGContext, body: Bool = true, token: Bool = true, decorationOpacity: Double = 1,
                      material: MokuBodyMaterial? = nil) {
        MokuResidentPainter.paint(in: context, pose: displayedPose, content: content, blink: blinkFactor,
                                  body: body, token: token, decorationOpacity: self.decorationOpacity * decorationOpacity,
                                  material: material)
    }

    public func paintedPose() -> MokuPaintedPose {
        let p = displayedPose
        func point(_ x: Double, _ y: Double) -> CGPoint {
            let turned = MokuGeometry.rotate(x: (x - 320) * p["sx"], y: (y - 300) * p["sy"], angle: p["angle"] * .pi / 180)
            return CGPoint(x: turned.x + 320 + p["x"], y: turned.y + 300 + p["y"])
        }
        func eye(_ side: String) -> MokuEye {
            let center = point(p[side + "x"], p[side + "y"])
            let w = max(1, p[side + "w"]), h = max(2, p[side + "h"] * blinkFactor * mokuResidentClamp(p["lid"]))
            return MokuEye(x: center.x - 320, y: center.y - 300, w: w * p["sx"], h: h * p["sy"],
                           radius: min(w, h) / 2, rotation: p[side + "a"] + p["angle"], opacity: 1)
        }
        var result = MokuPaintedPose(body: MokuGeometry.buildShape(.circle, layout: .mark).map { point($0.x, $0.y) },
                                     satellite: MokuGeometry.satellite(visible: false), leftEye: eye("l"), rightEye: eye("r"))
        result.blinkStarted = lastWall + blinkAt - clock
        result.nextNaturalBlink = lastWall + nextBlink - clock
        result.frame = .init(x: 320 + p["x"], y: 300 + p["y"], angle: p["angle"])
        result.thoughtRadius = p["dotRadius"] * p["dotAlpha"]
        result.token = .init(x: p["dotX"] + p["x"], y: p["dotY"] + p["y"],
                             radius: max(1, p["dotRadius"]) * (0.8 + mokuResidentClamp(p["dotAlpha"]) * 0.2),
                             opacity: mokuResidentClamp(p["dotAlpha"]), red: p["dotRed"], green: p["dotGreen"],
                             blue: p["dotBlue"], stroke: p["dotStroke"], reply: p["replyAlpha"])
        return result
    }
}
