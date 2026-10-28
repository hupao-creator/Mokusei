// Restored from b478a1f0e; Electron design provenance and adaptations: ../README.md.
@testable import MokuseiUI
import CoreGraphics
import Foundation

struct HistoricalReadingBodySample: Sendable {
    let x: Double
    let y: Double
    let angle: Double
    let sx: Double
    let sy: Double
}

/// The resident's existing reading phrase, with its original millisecond clock.
/// The caller repeats the phrase by wrapping time at `duration`.
struct HistoricalReadingTrack: Sendable {
    let duration: Double
    private let gazeSamples: [GazeSample]
    private let bodySamples: [BodySample]

    init(span: Double = 196, center: Double = -110, enabled: Bool = true, cycle: Int = 0) {
        let gaze = Self.readingGaze(span: span, center: center, enabled: enabled, cycle: cycle)
        duration = gaze.duration
        gazeSamples = gaze.samples
        bodySamples = Self.readingBody(samples: gaze.samples, duration: gaze.duration, cycle: cycle)
    }

    func sample(time: Double) -> (gaze: CGPoint, body: HistoricalReadingBodySample) {
        let gazeIndex = Self.index(at: time, in: gazeSamples, timestamp: { $0.at })
        let gazeLeft = gazeSamples[gazeIndex]
        let gazeRight = gazeSamples[min(gazeIndex + 1, gazeSamples.count - 1)]
        let gazeBlend = gazeLeft.at == gazeRight.at ? 0 : (time - gazeLeft.at) / (gazeRight.at - gazeLeft.at)

        let bodyIndex = Self.index(at: time, in: bodySamples, timestamp: { $0.at })
        let bodyLeft = bodySamples[bodyIndex]
        let bodyRight = bodySamples[min(bodyIndex + 1, bodySamples.count - 1)]
        let bodyBlend = bodyLeft.at == bodyRight.at ? 0 : (time - bodyLeft.at) / (bodyRight.at - bodyLeft.at)

        return (
            gaze: CGPoint(
                x: Self.mix(gazeLeft.x, gazeRight.x, gazeBlend),
                y: Self.mix(gazeLeft.y, gazeRight.y, gazeBlend)
            ),
            body: HistoricalReadingBodySample(
                x: Self.mix(bodyLeft.pose.x, bodyRight.pose.x, bodyBlend),
                y: Self.mix(bodyLeft.pose.y, bodyRight.pose.y, bodyBlend),
                angle: Self.mix(bodyLeft.pose.angle, bodyRight.pose.angle, bodyBlend),
                sx: Self.mix(bodyLeft.pose.sx, bodyRight.pose.sx, bodyBlend),
                sy: Self.mix(bodyLeft.pose.sy, bodyRight.pose.sy, bodyBlend)
            )
        )
    }

    private struct GazeSample: Sendable {
        let at: Double
        let x: Double
        let y: Double
    }

    private struct BodySample: Sendable {
        let at: Double
        let pose: HistoricalReadingBodySample
    }

    private static func readingGaze(
        span: Double, center: Double, enabled: Bool, cycle: Int
    ) -> (duration: Double, samples: [GazeSample]) {
        var samples = [GazeSample(at: 0, x: 0, y: 0)]
        var elapsed = 0.0
        var progress = 0.0
        let variation = sin(Double(cycle) * 2.399963)
        let pace = 1 + variation * 0.12

        func point(at progress: Double) -> (x: Double, y: Double) {
            let angle = (center - span / 2 + progress * span) * Double.pi / 180
            return enabled ? (cos(angle) * 78, 30 + sin(angle) * 70) : (0, 0)
        }

        func move(_ duration: Double, sample: (Double) -> (x: Double, y: Double)) {
            let count = Int(ceil(duration / 16))
            for index in 1...count {
                let point = sample(ease(Double(index) / Double(count)))
                samples.append(GazeSample(
                    at: elapsed + duration * Double(index) / Double(count), x: point.x, y: point.y
                ))
            }
            elapsed += duration
        }

        func hold(_ duration: Double) {
            elapsed += duration
            let last = samples[samples.count - 1]
            samples.append(GazeSample(at: elapsed, x: last.x, y: last.y))
        }

        func glance(to: Double, travel: Double, dwell: Double) {
            let from = progress
            let direction = to == from ? 0.0 : (to > from ? 1.0 : -1.0)
            let landing = max(0, min(1, to + direction * 0.009))
            move(travel * pace) { point(at: mix(from, landing, $0)) }
            if landing != to {
                move(95) { point(at: mix(landing, to, $0)) }
            }
            progress = to
            hold(dwell * (1 + 0.16 * sin(Double(cycle) * 1.37 + to * 5)))
        }

        let first = point(at: 0)
        move(310 * pace) { (first.x * $0, first.y * $0) }
        hold(140 + 35 * variation)
        glance(to: 0.23 + 0.025 * variation, travel: 620, dwell: 150)
        glance(to: 0.58 - 0.035 * variation, travel: 820, dwell: 280)
        if cycle % 3 != 1 {
            glance(to: 0.51 - 0.035 * variation, travel: 190, dwell: 130)
        }
        glance(to: 0.83 + 0.02 * variation, travel: 680, dwell: 120)
        glance(to: 1, travel: 520, dwell: 470)
        let last = point(at: 1)
        move(430 * pace) { (last.x * (1 - $0), last.y * (1 - $0)) }
        hold(200 + 55 * variation)

        return (elapsed, samples)
    }

    private static func readingBody(
        samples: [GazeSample], duration: Double, cycle: Int
    ) -> [BodySample] {
        let steps = Int(ceil(duration / 32))
        let smoothing = 1 - exp(-(duration / Double(steps)) / 150)
        var index = 0
        var followX = 0.0
        var followY = 0.0
        var body = [BodySample]()
        body.reserveCapacity(steps + 1)

        for step in 0...steps {
            let offset = Double(step) / Double(steps)
            let at = offset * duration
            let lookAt = max(0, at - 110)
            while index + 1 < samples.count && samples[index + 1].at <= lookAt {
                index += 1
            }
            let from = samples[index]
            let to = samples[min(index + 1, samples.count - 1)]
            let blend = from.at == to.at ? 0 : (lookAt - from.at) / (to.at - from.at)
            followX += (mix(from.x, to.x, blend) - followX) * smoothing
            followY += (mix(from.y, to.y, blend) - followY) * smoothing

            let envelope = pow(sin(Double.pi * offset), 2)
            let breath = sin(offset * Double.pi * 2.5 + Double(cycle) * 0.73) * envelope
            let x = followX / 78 * 3.6 * envelope
            let y = followY / 100 * 2.5 * envelope - breath * 1.8
            let angle = followX / 78 * 3.4 * envelope
            let sx = 1 + breath * 0.016
            // The original resident parses the body's serialized CSS transform.
            // Preserve its three/four-decimal keyframes before interpolation.
            body.append(BodySample(at: at, pose: HistoricalReadingBodySample(
                x: rounded(x, places: 3), y: rounded(y, places: 3),
                angle: rounded(angle, places: 3),
                sx: rounded(sx, places: 4), sy: rounded(1 / sx, places: 4)
            )))
        }
        return body
    }

    private static func index<T>(at time: Double, in samples: [T], timestamp: (T) -> Double) -> Int {
        var lower = 0
        var upper = samples.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if timestamp(samples[middle]) <= time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return max(0, lower - 1)
    }

    private static func mix(_ from: Double, _ to: Double, _ amount: Double) -> Double {
        from + (to - from) * amount
    }

    private static func ease(_ t: Double) -> Double {
        t * t * t * (t * (6 * t - 15) + 10)
    }

    private static func rounded(_ value: Double, places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded(.toNearestOrAwayFromZero) / scale
    }
}
