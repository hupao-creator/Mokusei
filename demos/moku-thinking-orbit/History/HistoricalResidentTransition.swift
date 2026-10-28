// Restored from b478a1f0e; Electron design provenance and adaptations: ../README.md.
@testable import MokuseiUI
import Foundation

/// Exact numeric choreography of the resident's 550 ms role handoff.
struct HistoricalResidentTransition {
    private(set) var role: HistoricalResidentRole = .idle
    private(set) var enteredAt = 0.0
    private var start = 0.0
    private var duration = 0.0
    private var from = HistoricalResidentPose.target(role: .idle, time: 0, enteredAt: 0, reading: HistoricalReadingTrack(), readingAt: 0)
    private var velocity = HistoricalResidentPose(values: [:])
    private var reading = HistoricalReadingTrack()
    private var readingAt = 0.0
    private var readingPrepared = false
    private var readingCycle = 0
    private var arcSpan = 192.0
    private var arcCenter = -110.0

    mutating func setArc(span: Double, center: Double) { arcSpan = span; arcCenter = center }

    mutating func setReading(span: Double, center: Double, enabled: Bool, time: Double) {
        if readingPrepared && time < readingAt + reading.duration { return }
        readingPrepared = true
        readingAt = max(time, enteredAt)
        // Electron varied whole phrases, never each incoming text fragment.
        reading = HistoricalReadingTrack(span: span, center: center, enabled: enabled, cycle: readingCycle)
        readingCycle += 1
    }

    mutating func settle(role: HistoricalResidentRole, time: Double, elapsed: Double = 0) {
        self.role = role; start = time; duration = 0; enteredAt = time - elapsed
        readingAt = enteredAt; readingPrepared = false; readingCycle = 0
    }

    private func orbit(from: CGPoint, to: CGPoint, amount: Double) -> CGPoint {
        let start = atan2(from.y - 300, from.x - 320), end = atan2(to.y - 300, to.x - 320)
        let turn = atan2(sin(end - start), cos(end - start))
        let angle = start + turn * amount
        let radius = historicalResidentMix(hypot(from.x - 320, from.y - 300), hypot(to.x - 320, to.y - 300), amount)
        return CGPoint(x: 320 + cos(angle) * radius, y: 300 + sin(angle) * radius)
    }

    private func planned(time: Double) -> HistoricalResidentPose {
        var target = HistoricalResidentPose.target(role: role, time: time, enteredAt: enteredAt, reading: reading, readingAt: readingAt)
        target["arcSpan"] = arcSpan; target["arcCenter"] = arcCenter
        if duration == 0 || time >= enteredAt { return target }
        let p = max(0, (time - start) / duration), from = self.from
        var result = target.map { historicalResidentMix(from[$0], target[$0], historicalResidentSmooth(p)) }
        func channel(_ key: String, _ until: Double, _ begin: Double = 0, _ destination: Double? = nil) {
            result[key] = historicalResidentMix(from[key], destination ?? target[key], historicalResidentPhase(p, begin, until))
        }
        let hadArc = from["arcAlpha"] > 0.08
        let hadDots = from["d0a"] + from["d1a"] + from["d2a"] > 0.12
        let hasToken = from["dotAlpha"] > 0.08
        let arc = role == .reasoning ? target : from
        let arcSeeds = [-1.0, 0, 1].map { index in
            let angle = (arc["arcCenter"] + index * arc["arcSpan"] / 3) * .pi / 180
            return CGPoint(x: 320 + cos(angle) * arc["arcRadius"] / 0.35,
                           y: 300 + sin(angle) * arc["arcRadius"] / 0.35)
        }
        var look = CGPoint(x: 320, y: 250)
        for side in ["l", "r"] { for part in ["x", "y", "w", "h", "a"] { channel(side + part, 0.82) } }
        channel("dotAlpha", 0.73, 0.22)
        channel("dotRed", 0.8, 0.32); channel("dotGreen", 0.8, 0.32); channel("dotBlue", 0.8, 0.32)
        channel("dotRadius", 0.86, 0.3); channel("dotStroke", 0.85, 0.3)
        channel("replyAlpha", 0.95, 0.64)
        if role == .reasoning {
            channel("arcAlpha", 0.83, 0.33); channel("arcReveal", 0.94, 0.36)
            channel("arcGather", 0.96, 0.28); channel("arcOffset", 0.9, 0.25)
            channel("arcGroupSpan", 0.6); channel("arcCenter", 0.6); channel("arcRadius", 0.85, 0.2)
            if hasToken && !hadDots && !hadArc {
                let anchor = atan2(from["dotY"] - 300, from["dotX"] - 320) * 180 / .pi
                let radius = hypot(from["dotX"] - 320, from["dotY"] - 300) * 0.35
                result["arcCenter"] = historicalResidentMix(from["arcCenter"], anchor, historicalResidentPhase(p, 0, 0.22))
                    + (target["arcCenter"] - anchor) * historicalResidentPhase(p, 0.32, 0.9)
                result["arcRadius"] = historicalResidentMix(from["arcRadius"], radius, historicalResidentPhase(p, 0, 0.22))
                    + (90 - radius) * historicalResidentPhase(p, 0.32, 0.9)
                result["arcGroupSpan"] = historicalResidentMix(from["arcGroupSpan"], 0, historicalResidentPhase(p, 0, 0.22))
                    + historicalResidentPhase(p, 0.36, 0.92)
            }
            for index in 0...2 {
                let key = "d\(index)", indexValue = Double(index)
                let point = orbit(from: CGPoint(x: from[key + "x"], y: from[key + "y"]), to: arcSeeds[index],
                                  amount: historicalResidentPhase(p, 0.08 + indexValue * 0.025, 0.57 + indexValue * 0.025))
                if hadDots {
                    result[key + "x"] = point.x; result[key + "y"] = point.y
                    result[key + "a"] = from[key + "a"] * (1 - historicalResidentPhase(p, 0.58, 0.9))
                    result[key + "s"] = historicalResidentMix(from[key + "s"], 0.12, historicalResidentPhase(p, 0.48, 0.92))
                }
            }
            channel("toolAlpha", 0.4); channel("toolReveal", 0.38); channel("toolX", 0.45, 0, 258)
            look = hadDots ? CGPoint(x: result["d0x"], y: result["d0y"]) : arcSeeds[0]
        } else {
            channel("arcGather", 0.5)
            channel("arcAlpha", 0.63, 0.22); channel("arcReveal", 0.62, 0.16); channel("arcOffset", 0.62)
            if role == .tool || role == .reply {
                channel("arcGroupSpan", 0.56, 0, 0)
                channel("arcCenter", 0.56, 0, atan2(target["dotY"] - 300, target["dotX"] - 320) * 180 / .pi)
                channel("arcRadius", 0.56, 0, hypot(target["dotX"] - 320, target["dotY"] - 300) * 0.35)
            }
        }
        if role == .running {
            let token = CGPoint(x: from["dotX"], y: from["dotY"])
            for index in 0...2 {
                let key = "d\(index)", indexValue = Double(index)
                let original = CGPoint(x: from[key + "x"], y: from[key + "y"])
                let landing = CGPoint(x: target[key + "x"], y: target[key + "y"])
                let seed = hadArc ? arcSeeds[index] : hasToken ? token : CGPoint(x: 320, y: landing.y + 14)
                let staged = orbit(from: original, to: seed, amount: historicalResidentPhase(p, 0, 0.22))
                let point = orbit(from: staged, to: landing,
                                  amount: historicalResidentPhase(p, 0.46 + indexValue * 0.025, 0.88 + indexValue * 0.045))
                result[key + "x"] = point.x; result[key + "y"] = point.y
                channel(key + "a", 0.6 + indexValue * 0.06, 0.2 + indexValue * 0.035)
                result[key + "s"] = historicalResidentMix(from[key + "s"], 1, historicalResidentSmooth(p)) - 0.45 * historicalResidentPulse(p, 0, 0.22, 0.75)
            }
            if hasToken && !hadArc {
                let point = orbit(from: token, to: CGPoint(x: 320, y: target["d1y"]), amount: historicalResidentPhase(p, 0.34, 0.86))
                result["dotX"] = point.x; result["dotY"] = point.y
                channel("dotAlpha", 0.66, 0.24, 0); channel("dotRadius", 0.68, 0.2, 10)
            }
            channel("toolAlpha", 0.45); channel("toolReveal", 0.4); channel("toolX", 0.45, 0, 258)
            look = CGPoint(x: result["d1x"], y: result["d1y"])
        } else if role != .reasoning && hadDots {
            let destination = role == .idle ? CGPoint(x: 320, y: 518) : CGPoint(x: target["dotX"], y: target["dotY"])
            for index in 0...2 {
                let key = "d\(index)", indexValue = Double(index)
                let point = orbit(from: CGPoint(x: from[key + "x"], y: from[key + "y"]), to: destination,
                                  amount: historicalResidentPhase(p, 0.05 + indexValue * 0.035, 0.65 + indexValue * 0.035))
                result[key + "x"] = point.x; result[key + "y"] = point.y
                channel(key + "a", 0.76 + indexValue * 0.035, 0.38)
                result[key + "s"] = historicalResidentMix(from[key + "s"], 0.12, historicalResidentPhase(p, 0.35, 0.8))
            }
        }
        if role == .tool {
            channel("toolAlpha", 0.78, 0.42); channel("toolReveal", 0.95, 0.47); channel("toolOffset", 0.9, 0.4)
            result["toolX"] = historicalResidentMix(from["toolX"], 258, historicalResidentPhase(p, 0, 0.35))
                + (271 - 258) * historicalResidentPhase(p, 0.42, 0.95)
            look = CGPoint(x: 545, y: 194)
        } else if role != .running && role != .reasoning {
            channel("toolAlpha", 0.45); channel("toolReveal", 0.42); channel("toolX", 0.45, 0, 258)
        }
        if role == .reply { look = CGPoint(x: result["dotX"], y: result["dotY"]) }
        let attention = historicalResidentPulse(p, 0, 0.27, 0.9)
        let glanceX = max(-54, min(54, (look.x - 320) * 0.24))
        let glanceY = max(-38, min(48, (look.y - 255) * 0.2))
        for side in ["l", "r"] {
            result[side + "x"] += glanceX * attention; result[side + "y"] += glanceY * attention
            result[side + "w"] += 1.2 * attention
        }
        let blinkStrength = role == .reply || role == .idle ? 0.7 : 0.42
        result["lid"] = historicalResidentMix(from["lid"], 1, historicalResidentPhase(p, 0, 0.5))
            - blinkStrength * historicalResidentPulse(p, 0.03, 0.17, 0.35)
        let follow = historicalResidentPulse(p, 0.1, 0.45, 1)
        result["angle"] += glanceX / 54 * 2.4 * follow; result["x"] += glanceX / 54 * 3.5 * follow
        result["y"] += (role == .running ? 5 : -3) * follow
        result["sx"] -= 0.014 * follow; result["sy"] += 0.014 * follow
        result["dotRadius"] += 1.5 * historicalResidentPulse(p, 0.5, 0.76, 1)
        return result.map { historicalResidentMix(result[$0], target[$0], historicalResidentPhase(p, 0.88, 1)) }
    }

    func sample(time: Double) -> HistoricalResidentPose {
        let result = planned(time: time)
        if duration == 0 || time >= enteredAt { return result.fittedEyes() }
        let length = duration * 0.36, p = historicalResidentClamp((time - start) / length)
        let tangent = p * p * p - 2 * p * p + p
        return result.map { result[$0] + tangent * length * velocity[$0] }.fittedEyes()
    }

    mutating func redirect(role: HistoricalResidentRole, time: Double, duration: Double = 550) {
        let before = sample(time: time), next = sample(time: time + 0.01)
        from = before; self.role = role; start = time; self.duration = duration; enteredAt = time + duration
        readingAt = enteredAt; readingPrepared = false
        let first = planned(time: time), later = planned(time: time + 0.01)
        velocity = before.map { ((next[$0] - before[$0]) - (later[$0] - first[$0])) / 0.01 }
    }

    func progress(time: Double) -> Double { duration == 0 ? 1 : historicalResidentClamp((time - start) / duration) }
}
