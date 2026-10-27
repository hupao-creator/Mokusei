import MokuseiPluginUI
import AppKit

public struct MokuRunningFrame {
    public var stage: String
    public var eyes: Eyes
    public var dots: [Dot]
    public struct Eyes {
        public var x: Double = 0, y: Double = 0, scaleX: Double = 1, scaleY: Double = 1
    }
    public struct Dot {
        public var x, y, opacity: Double
        public var color: NativePlatformColor
        public var scale: Double = 1
    }
}

/// Authored running choreography: relay, lift, one revolution, landing, recovery.
public enum MokuRunningStory {
    public static let beatMS: Double = 2800
    public static let orbitBeats: Double = 3000 / beatMS
    public static let cycleBeats: Double = 1.22 + orbitBeats + 0.45
    public static let dotRadius: Double = 3.5 * 640 / 210
    private static let unit: Double = 640 / 210
    private static let palette: [[Double]] = [[231,128,134],[217,170,90],[128,184,139],
                                              [105,185,191],[127,159,225],[184,138,206]]

    /// Optional orbit targets use the same authored coordinates as the returned frame.
    public static func sample(time: Double, still: Bool = false,
                              restingY: Double? = nil, restingSpacing: Double? = nil,
                              orbitPoint: ((Double) -> CGPoint)? = nil) -> MokuRunningFrame {
        let t = still ? 0 : (time.truncatingRemainder(dividingBy: cycleBeats) + cycleBeats).truncatingRemainder(dividingBy: cycleBeats)
        let landAt = 1.22 + orbitBeats, recoverAt = landAt + 0.23
        let lap = clamp((t - 1.22) / orbitBeats)
        let orbit = pow(lap, 3) * (lap * (lap * 6 - 15) + 10)
        let angle = Double.pi / 2 + Double.pi * 2 * orbit
        let departure = smooth((t - 1) / 0.22)
        let arrival = smooth((t - landAt) / 0.23)
        let recover = smooth((t - recoverAt) / 0.22)
        let orbitWeight = departure * (1 - arrival)
        var eyes = MokuRunningFrame.Eyes()
        if !still {
            let lead = angle + 0.17
            let anticipate = 26 * smooth((t - 0.8) / 0.2)
            eyes.x = 34 * cos(lead) * orbitWeight
            eyes.y = mix(anticipate, 16 + 38 * sin(lead), departure) * (1 - arrival) + 26 * arrival * (1 - recover)
            eyes.scaleY = 1 + 0.055 * sin(.pi * orbit) * orbitWeight
                - (t > recoverAt ? 0.78 * pow(sin(.pi * recover), 8) : 0)
        }
        let dots = (0..<3).map { index -> MokuRunningFrame.Dot in
            let baseX = 320 + Double(index - 1) * (restingSpacing ?? (13 * unit))
            let beat = t * 3 - Double(index)
            let pulse = !still && t < 1 && beat >= 0 && beat < 1 ? pow(sin(.pi * beat), 2) : 0
            let dotAngle = angle + Double(1 - index) * 0.17
            let target = orbitPoint?(dotAngle) ?? CGPoint(x: 320 + 78 * unit * cos(dotAngle),
                                                         y: 300 + 78 * unit * sin(dotAngle))
            return .init(x: mix(baseX, target.x, orbitWeight),
                         y: mix((restingY ?? (464 + 16.5 * unit)) - 3 * unit * pulse, target.y, orbitWeight),
                         opacity: still ? 0.9 : mix(0.65 + 0.35 * pulse, 1, orbitWeight),
                         color: color(t / cycleBeats + Double(index) / 3))
        }
        let stage = still ? "静态预览" : t < 1 ? "三拍接力" : t < 1.22 ? "准备起飞"
            : t < landAt ? "环绕一圈" : t < recoverAt ? "回到底部" : "恢复自然"
        return MokuRunningFrame(stage: stage, eyes: eyes, dots: dots)
    }

    private static func color(_ phase: Double) -> NativePlatformColor {
        let p = (phase.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * Double(palette.count)
        let index = Int(floor(p)), next = (index + 1) % palette.count
        let values = (0..<3).map { mix(palette[index][$0], palette[next][$0], p - Double(index)).rounded() / 255 }
        return MokuGeometry.color(red: values[0], green: values[1], blue: values[2], alpha: 1)
    }
    static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
    static func smooth(_ value: Double) -> Double { let t = clamp(value); return t * t * (3 - 2 * t) }
    static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}

public struct MokuLaunchFrame {
    public var running: Bool
    public var frame: MokuRunningFrame
    public var bodyX: Double = 1, bodyY: Double = 1, bodyDrop: Double = 0
}

public struct MokuLaunchCapsule: Equatable, Sendable {
    /// Rectangle and body offset must already be converted to Moku's view box.
    public var rect: CGRect
    public var bodyOffset: CGPoint
    public var radius: Double
    public init(rect: CGRect, bodyOffset: CGPoint = .zero, radius: Double = 26) {
        self.rect = rect; self.bodyOffset = bodyOffset; self.radius = radius
    }
}

public enum MokuLaunchStory {
    public static let capsuleDotAt: Double = 400
    public static let duration: Double = 720
    public static func sample(elapsed: Double) -> MokuLaunchFrame {
        let running = elapsed >= duration
        var story = MokuRunningStory.sample(time: max(0, elapsed - duration) / MokuRunningStory.beatMS)
        if running { return MokuLaunchFrame(running: true, frame: story) }
        let press = sin(.pi * MokuRunningStory.smooth(elapsed / 220))
        let release = sin(.pi * MokuRunningStory.smooth((elapsed - 220) / 260))
        story.stage = elapsed < capsuleDotAt ? "输入框 → 中间光点" : "左右光点接上"
        story.eyes = .init(x: 0,
            y: 24 * MokuRunningStory.smooth(elapsed / 120) * (1 - MokuRunningStory.smooth((elapsed - 440) / 280)),
            scaleX: 1, scaleY: 1 - 0.1 * press)
        for index in story.dots.indices {
            if index == 1 {
                if elapsed < capsuleDotAt { story.dots[index].opacity = 0 }
            } else {
                let arrival = MokuRunningStory.smooth((elapsed - (index == 0 ? 360 : 440)) / 200)
                story.dots[index].x = 320 + (story.dots[index].x - 320) * arrival
                story.dots[index].y += 8 * (1 - arrival)
                story.dots[index].opacity *= arrival
                story.dots[index].scale = arrival + 0.12 * sin(.pi * arrival)
            }
        }
        return MokuLaunchFrame(running: false, frame: story,
            bodyX: 1 + 0.045 * press - 0.018 * release,
            bodyY: 1 - 0.045 * press + 0.022 * release, bodyDrop: 8 * press - 6 * release)
    }

    public static func capsule(_ source: MokuLaunchCapsule, elapsed: Double) -> (rect: CGRect, radius: Double, opacity: Double, tint: Double, color: NativePlatformColor) {
        let shrink = 1 - pow(1 - MokuRunningStory.clamp(elapsed / 360), 3)
        let travel = MokuRunningStory.smooth(elapsed / capsuleDotAt)
        let tint = MokuRunningStory.smooth((elapsed - 160) / 220)
        let dot = MokuRunningStory.sample(time: 0).dots[1]
        let diameter = MokuRunningStory.dotRadius * 2
        let width = MokuRunningStory.mix(source.rect.width, diameter, shrink)
        let height = MokuRunningStory.mix(source.rect.height, diameter, shrink)
        let rect = CGRect(x: MokuRunningStory.mix(source.rect.midX, dot.x, travel) - width / 2,
                          y: MokuRunningStory.mix(source.rect.midY, dot.y, travel) - height / 2,
                          width: width, height: height)
        let rgb = MokuGeometry.colorComponents(dot.color)
        let color = MokuGeometry.color(red: MokuRunningStory.mix(16, rgb.red * 255, tint).rounded() / 255,
                            green: MokuRunningStory.mix(17, rgb.green * 255, tint).rounded() / 255,
                            blue: MokuRunningStory.mix(15, rgb.blue * 255, tint).rounded() / 255, alpha: 1)
        return (rect, MokuRunningStory.mix(source.radius, MokuRunningStory.dotRadius, shrink),
                MokuRunningStory.mix(1, dot.opacity, tint), tint, color)
    }
    public static func bodyOffset(_ source: MokuLaunchCapsule, elapsed: Double) -> CGPoint {
        let amount = 1 - MokuRunningStory.smooth(elapsed / 240)
        return CGPoint(x: source.bodyOffset.x * amount, y: source.bodyOffset.y * amount)
    }
}
