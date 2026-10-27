import CoreGraphics
import Foundation

public enum MokuResidentRole: String, CaseIterable, Sendable {
    case idle, running, tool, reply
}

/// All appearance channels live together so a redirected transition inherits
/// the displayed geometry and velocity, including partly revealed decorations.
public struct MokuResidentPose {
    var values: [String: Double]
    public subscript(_ channel: String) -> Double {
        get { values[channel, default: 0] }
        set { values[channel] = newValue }
    }

    func map(_ transform: (String) -> Double) -> Self {
        Self(values: Dictionary(uniqueKeysWithValues: values.keys.map { ($0, transform($0)) }))
    }

    func fittedEyes() -> Self {
        var result = self
        let cx = (self["lx"] + self["rx"]) / 2, cy = (self["ly"] + self["ry"]) / 2
        let dx = cx - 320, dy = cy - 250, a = dx * dx + dy * dy
        if a < 0.00001 { return self }
        var amount = 1.0
        for side in ["l", "r"] {
            let angle = self[side + "a"] * .pi / 180
            for x in [-self[side + "w"] / 2, self[side + "w"] / 2] {
                for y in [-self[side + "h"] / 2, self[side + "h"] / 2] {
                    let bx = self[side + "x"] - cx + x * cos(angle) - y * sin(angle)
                    let by = self[side + "y"] - cy - 50 + x * sin(angle) + y * cos(angle)
                    let b = 2 * (bx * dx + by * dy), c = bx * bx + by * by - 154 * 154
                    amount = min(amount, max(0, (-b + sqrt(max(0, b * b - 4 * a * c))) / (2 * a)))
                }
            }
        }
        result["lx"] += dx * (amount - 1); result["rx"] += dx * (amount - 1)
        result["ly"] += dy * (amount - 1); result["ry"] += dy * (amount - 1)
        return result
    }

    static func target(role: MokuResidentRole, time: Double, enteredAt: Double) -> Self {
        let elapsed = max(0, time - enteredAt)
        let running = MokuRunningStory.sample(time: elapsed / MokuRunningStory.beatMS, still: false)
        let tool = role == .tool, reply = role == .reply
        func eye(left: Bool) -> [Double] {
            let original = left ? MokuGeometry.expressions[.idle]!.left : MokuGeometry.expressions[.idle]!.right
            let x = 320 + original.x, y = 300 + original.y
            if tool { return [x + 22, 240 + (y - 240) * 0.62 + 28, original.w, original.h * 0.62, 0] }
            return [x + (role == .running ? running.eyes.x : 0),
                    y + (role == .running ? running.eyes.y : 0), original.w,
                    original.h * (role == .running ? running.eyes.scaleY : 1), original.rotation]
        }
        let left = eye(left: true), right = eye(left: false)
        var result = Self(values: [
            "x": 0, "y": 0, "angle": 0, "sx": 1, "sy": 1,
            "lx": left[0], "ly": left[1], "lw": left[2], "lh": left[3], "la": left[4],
            "rx": right[0], "ry": right[1], "rw": right[2], "rh": right[3], "ra": right[4], "lid": 1,
            "dotAlpha": tool || reply ? 1 : 0,
            "dotRed": reply ? 255 : tool ? 52 : 36, "dotGreen": reply ? 59 : tool ? 199 : 156,
            "dotBlue": reply ? 48 : tool ? 89 : 255,
            "dotX": reply ? (248 - 88) / 0.35 : 477, "dotY": reply ? 180 : 178,
            "dotRadius": reply ? 13 / 0.35 : 22, "dotStroke": reply ? 0 : 8,
            "toolAlpha": tool ? 1 : 0, "toolOffset": tool ? 0 : -1.5,
            "toolReveal": tool ? 1 : 0, "toolX": 271, "replyAlpha": reply ? 1 : 0
        ])
        for (index, dot) in running.dots.enumerated() {
            let key = "d\(index)"
            let color = MokuGeometry.colorComponents(dot.color)
            result[key + "x"] = dot.x; result[key + "y"] = dot.y
            result[key + "a"] = role == .running ? dot.opacity : 0; result[key + "s"] = 1
            result[key + "r"] = color.red * 255
            result[key + "g"] = color.green * 255
            result[key + "b"] = color.blue * 255
        }
        return result.fittedEyes()
    }
}

func mokuResidentClamp(_ value: Double) -> Double { min(1, max(0, value)) }
func mokuResidentMix(_ a: Double, _ b: Double, _ amount: Double) -> Double { a + (b - a) * amount }
func mokuResidentSmooth(_ value: Double) -> Double {
    let p = mokuResidentClamp(value)
    return p * p * (3 - 2 * p)
}
func mokuResidentPhase(_ p: Double, _ from: Double, _ to: Double) -> Double {
    mokuResidentSmooth((p - from) / (to - from))
}
func mokuResidentPulse(_ p: Double, _ from: Double, _ peak: Double, _ to: Double) -> Double {
    mokuResidentPhase(p, from, peak) * (1 - mokuResidentPhase(p, peak, to))
}
