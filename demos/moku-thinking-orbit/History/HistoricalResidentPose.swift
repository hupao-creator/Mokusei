// Restored from b478a1f0e; Electron design provenance and adaptations: ../README.md.
@testable import MokuseiUI
import AppKit

public enum HistoricalResidentRole: String, CaseIterable, Sendable {
    case idle, running, reasoning, tool, reply
}

/// All appearance channels live together so a redirected transition inherits
/// the displayed geometry and velocity, including partly revealed decorations.
public struct HistoricalResidentPose {
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

    static func target(role: HistoricalResidentRole, time: Double, enteredAt: Double,
                       reading: HistoricalReadingTrack, readingAt: Double) -> Self {
        let elapsed = max(0, time - enteredAt)
        let running = MokuRunningStory.sample(time: elapsed / MokuRunningStory.beatMS, still: false)
        let readingElapsed = max(0, time - readingAt).truncatingRemainder(dividingBy: reading.duration)
        let read = reading.sample(time: readingElapsed)
        let thinking = role == .reasoning, tool = role == .tool, reply = role == .reply
        func eye(left: Bool) -> [Double] {
            let original = left ? MokuGeometry.expressions[.idle]!.left : MokuGeometry.expressions[.idle]!.right
            if thinking {
                let x = (left ? 283.5 : 355.5) - 8 - 320
                let y = (left ? 280.5 : 277.5) - 21 - 320
                let angle = -4.0 * .pi / 180
                return [320 + x * cos(angle) - y * sin(angle) + read.gaze.x,
                        320 + x * sin(angle) + y * cos(angle) + read.gaze.y, 29.7, 69.3, -11]
            }
            let x = 320 + original.x, y = 300 + original.y
            if tool { return [x + 22, 240 + (y - 240) * 0.62 + 28, original.w, original.h * 0.62, 0] }
            return [x + (role == .running ? running.eyes.x : 0),
                    y + (role == .running ? running.eyes.y : 0), original.w,
                    original.h * (role == .running ? running.eyes.scaleY : 1), original.rotation]
        }
        let left = eye(left: true), right = eye(left: false)
        var result = Self(values: [
            "x": thinking ? read.body.x / 0.35 : 0, "y": thinking ? read.body.y / 0.35 : 0,
            "angle": thinking ? read.body.angle : 0, "sx": thinking ? read.body.sx : 1, "sy": thinking ? read.body.sy : 1,
            "lx": left[0], "ly": left[1], "lw": left[2], "lh": left[3], "la": left[4],
            "rx": right[0], "ry": right[1], "rw": right[2], "rh": right[3], "ra": right[4], "lid": 1,
            "dotAlpha": thinking || tool || reply ? 1 : 0,
            "dotRed": reply ? 255 : tool ? 52 : 36, "dotGreen": reply ? 59 : tool ? 199 : 156,
            "dotBlue": reply ? 48 : tool ? 89 : 255,
            "dotX": reply ? (248 - 88) / 0.35 : 477, "dotY": reply ? 180 : 178,
            "dotRadius": reply ? 13 / 0.35 : 22, "dotStroke": reply ? 0 : 8,
            "arcAlpha": thinking ? 1 : 0, "arcOffset": thinking ? 0 : 5,
            "arcReveal": thinking ? 1 : 0, "arcGather": thinking ? 0 : 1,
            "arcCenter": -110, "arcSpan": 192, "arcGroupSpan": 1, "arcRadius": 90,
            "toolAlpha": tool ? 1 : 0, "toolOffset": tool ? 0 : -1.5,
            "toolReveal": tool ? 1 : 0, "toolX": 271, "replyAlpha": reply ? 1 : 0
        ])
        for (index, dot) in running.dots.enumerated() {
            let key = "d\(index)"
            let color = dot.color.usingColorSpace(.sRGB) ?? dot.color
            result[key + "x"] = dot.x; result[key + "y"] = dot.y
            result[key + "a"] = role == .running ? dot.opacity : 0; result[key + "s"] = 1
            result[key + "r"] = Double(color.redComponent) * 255
            result[key + "g"] = Double(color.greenComponent) * 255
            result[key + "b"] = Double(color.blueComponent) * 255
        }
        return result.fittedEyes()
    }
}

func historicalResidentClamp(_ value: Double) -> Double { min(1, max(0, value)) }
func historicalResidentMix(_ a: Double, _ b: Double, _ amount: Double) -> Double { a + (b - a) * amount }
func historicalResidentSmooth(_ value: Double) -> Double {
    let p = historicalResidentClamp(value)
    return p * p * (3 - 2 * p)
}
func historicalResidentPhase(_ p: Double, _ from: Double, _ to: Double) -> Double {
    historicalResidentSmooth((p - from) / (to - from))
}
func historicalResidentPulse(_ p: Double, _ from: Double, _ peak: Double, _ to: Double) -> Double {
    historicalResidentPhase(p, from, peak) * (1 - historicalResidentPhase(p, peak, to))
}
