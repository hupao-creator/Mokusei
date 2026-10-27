import MokuseiPluginUI
import AppKit

/// The pixels of a character after its body transform. Handoffs morph one face
/// in its local coordinate frame, avoiding a cross-fade or a collapsed rotation.
public struct MokuPaintedPose: Sendable {
    public var body: [CGPoint]
    public var satellite: [CGPoint]
    public var leftEye, rightEye: MokuEye
    public var satelliteOpacity: Double = 0
    public var orbitOpacity: Double = 0
    public var orbitAt: Double = 0
    public var thoughtRadius: Double = 0
    public var frame = Frame()
    public var token = Token()
    public var blinkStarted: Double = -.infinity
    public var nextNaturalBlink: Double = .infinity
    public var eagerBlink = false
    public struct Frame: Sendable {
        public var x: Double = 320, y: Double = 300, angle: Double = 0
        public init(x: Double = 320, y: Double = 300, angle: Double = 0) { self.x = x; self.y = y; self.angle = angle }
    }
    public struct Token: Sendable {
        public var x: Double = 477, y: Double = 178, radius: Double = 0, opacity: Double = 0
        public var red: Double = 36, green: Double = 156, blue: Double = 255, stroke: Double = 8, reply: Double = 0
        public init(x: Double = 477, y: Double = 178, radius: Double = 0, opacity: Double = 0,
                    red: Double = 36, green: Double = 156, blue: Double = 255, stroke: Double = 8, reply: Double = 0) {
            self.x = x; self.y = y; self.radius = radius; self.opacity = opacity
            self.red = red; self.green = green; self.blue = blue; self.stroke = stroke; self.reply = reply
        }
    }
    public init(body: [CGPoint], satellite: [CGPoint], leftEye: MokuEye, rightEye: MokuEye) {
        self.body = body; self.satellite = satellite; self.leftEye = leftEye; self.rightEye = rightEye
    }

    public func blended(to target: MokuPaintedPose, amount p: Double) -> MokuPaintedPose {
        if p <= 0 { return self }; if p >= 1 { return target }
        let a = frame, b = target.frame
        let frame = Frame(x: mix(a.x, b.x, p), y: mix(a.y, b.y, p), angle: turn(a.angle, b.angle, p))
        func point(_ from: CGPoint, _ to: CGPoint) -> CGPoint {
            let start = MokuGeometry.rotate(x: from.x - a.x, y: from.y - a.y, angle: -a.angle * .pi / 180)
            let end = MokuGeometry.rotate(x: to.x - b.x, y: to.y - b.y, angle: -b.angle * .pi / 180)
            let turned = MokuGeometry.rotate(x: mix(start.x, end.x, p), y: mix(start.y, end.y, p), angle: frame.angle * .pi / 180)
            return CGPoint(x: turned.x + frame.x, y: turned.y + frame.y)
        }
        func eye(_ from: MokuEye, _ to: MokuEye) -> MokuEye {
            let center = point(CGPoint(x: from.x + 320, y: from.y + 300), CGPoint(x: to.x + 320, y: to.y + 300))
            return MokuEye(x: center.x - 320, y: center.y - 300,
                w: mix(from.w, to.w, p), h: mix(from.h, to.h, p), radius: mix(from.radius, to.radius, p),
                rotation: frame.angle + turn(from.rotation - a.angle, to.rotation - b.angle, p), opacity: mix(from.opacity, to.opacity, p))
        }
        var result = target
        result.frame = frame; result.body = zip(body, target.body).map { point($0.0, $0.1) }
        result.satellite = zip(satellite, target.satellite).map { point($0.0, $0.1) }
        result.leftEye = eye(leftEye, target.leftEye); result.rightEye = eye(rightEye, target.rightEye)
        result.satelliteOpacity = mix(satelliteOpacity, target.satelliteOpacity, p)
        result.orbitOpacity = mix(orbitOpacity, target.orbitOpacity, p); result.orbitAt = orbitAt
        result.thoughtRadius = mix(thoughtRadius, target.thoughtRadius, p)
        result.token = Token(x: mix(token.x, target.token.x, p), y: mix(token.y, target.token.y, p),
            radius: mix(token.radius, target.token.radius, p), opacity: mix(token.opacity, target.token.opacity, p),
            red: mix(token.red, target.token.red, p), green: mix(token.green, target.token.green, p), blue: mix(token.blue, target.token.blue, p),
            stroke: mix(token.stroke, target.token.stroke, p), reply: mix(token.reply, target.token.reply, p))
        return result
    }

    public func paint(in context: CGContext, material: MokuBodyMaterial? = nil) {
        context.saveGState()
        if orbitOpacity > 0.001 {
            context.saveGState(); context.setAlpha(orbitOpacity)
            context.translateBy(x: 320, y: 314); context.rotate(by: (orbitAt / 29).truncatingRemainder(dividingBy: 360) * .pi / 180)
            context.setLineWidth(10); context.setLineCap(.round)
            let colors: [UInt32] = [0xee787e, 0x69cdb6, 0x74aef5, 0xbd7ce4, 0xd9c957]
            for (index, angle) in [8.0, 54, 102, 146, 194].enumerated() {
                context.saveGState(); context.rotate(by: angle * .pi / 180)
                context.setStrokeColor(NativePlatformPalette.color(colors[index]).cgColor)
                context.setLineDash(phase: -(orbitAt * (0.14 + Double(index) * 0.018) + Double(index) * 175).truncatingRemainder(dividingBy: 1190), lengths: [190, 1000])
                context.strokeEllipse(in: CGRect(x: -224, y: -88, width: 448, height: 176)); context.restoreGState()
            }
            context.restoreGState()
        }
        MokuBodyMaterial.fill(MokuGeometry.path(body), in: context, material: material)
        MokuBodyMaterial.fill(MokuGeometry.path(satellite, tension: 0.72),
                              in: context, opacity: satelliteOpacity, material: material)
        MokuCharacterModel.paintEye(leftEye, in: context); MokuCharacterModel.paintEye(rightEye, in: context)
        if token.radius > 0.001 && token.opacity > 0.001 {
            context.setAlpha(token.opacity)
            context.addEllipse(in: CGRect(x: token.x - token.radius, y: token.y - token.radius, width: token.radius * 2, height: token.radius * 2))
            context.setFillColor(MokuGeometry.color(red: token.red / 255, green: token.green / 255, blue: token.blue / 255, alpha: 1).cgColor)
            if token.stroke > 0.1 { context.setStrokeColor(MokuGeometry.eyeColor.cgColor); context.setLineWidth(token.stroke); context.drawPath(using: .fillStroke) }
            else { context.fillPath() }
            if token.reply > 0.001 {
                context.setAlpha(token.opacity * token.reply)
                let text = NSAttributedString(string: "1", attributes: [.font: NativePlatformFont.systemFont(ofSize: 48.57), .foregroundColor: NativePlatformColor.white])
                let size = text.size()
                mokuDrawText(text, at: CGPoint(x: token.x - 1.43 - size.width / 2,
                    y: token.y - 2.86 - size.height / 2), in: context)
            }
        }
        context.restoreGState()
    }
    private func mix(_ a: Double, _ b: Double, _ p: Double) -> Double { a + (b - a) * p }
    private func turn(_ a: Double, _ b: Double, _ p: Double) -> Double {
        a + atan2(sin((b - a) * .pi / 180), cos((b - a) * .pi / 180)) * 180 / .pi * p
    }
}
