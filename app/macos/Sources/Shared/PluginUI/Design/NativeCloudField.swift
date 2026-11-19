import SwiftUI

/// CPU-side geometry only. Metal evaluates the radial light field per pixel.
/// Packing keeps the existing point-space geometry and seeded motion unchanged.
struct NativeCloudField {
    let palette: NativeCloudPalette
    let intensity: Double
    let time: Double
    let seed: UInt64

    func lights(in size: CGSize, colorScheme: ColorScheme) -> NativeCloudLights {
        let geometry = geometry(in: size, colorScheme: colorScheme)
        guard !geometry.isEmpty else { return NativeCloudLights() }
        var colors: [Color] = []
        colors.reserveCapacity(palette.channels.count * 6)
        for channel in palette.channels { colors.append(contentsOf: repeatElement(channel.color, count: 6)) }
        return NativeCloudLights(geometry: geometry, colors: colors)
    }

    func geometry(in size: CGSize, colorScheme: ColorScheme) -> [Float] {
        guard intensity > 0, size.width > 0, size.height > 0 else { return [] }
        let exposure = max(0, min(intensity, 2)) * (colorScheme == .dark ? 0.30 : 0.72)
        var geometry: [Float] = []
        geometry.reserveCapacity(palette.channels.count * 6 * 5)
        for channel in palette.channels {
            let motion = NativeCloudMotion(seed: seed &+ UInt64(truncatingIfNeeded: channel.seed))
            let drift = 160 * motion.value(at: time, lane: 0, duration: 6...10)
            let spread = 76 + 10 * motion.value(at: time, lane: 1)
            for lobe in 0..<3 {
                let lane = UInt64(2 + lobe * 4)
                let x = size.width / 2 + drift + Double(lobe - 1) * spread + 24 * motion.value(at: time, lane: lane)
                let y = size.height / 2 + 86 * motion.value(at: time, lane: lane + 1)
                let radiusX = (100 + 18 * motion.value(at: time, lane: lane + 2)) * palette.lobeScale.width
                let radiusY = (88 + 16 * motion.value(at: time, lane: lane + 3)) * palette.lobeScale.height
                let energy = channel.energy * exposure * (lobe == 1 ? 1 : 0.78)
                for (scaleX, scaleY, gain) in [(1.5, 1.7, 0.18), (1.0, 1.0, 1.0)] {
                    geometry.append(Float(x))
                    geometry.append(Float(y))
                    geometry.append(Float(radiusX * scaleX))
                    geometry.append(Float(radiusY * scaleY))
                    geometry.append(Float(energy * gain))
                }
            }
        }
        return geometry
    }
}

struct NativeCloudLights: Equatable {
    var geometry: [Float] = []
    var colors: [Color] = []
    var isEmpty: Bool { geometry.isEmpty }
}

/// Visual values supplied by the owning surface or harness, without semantic lookup.
public struct NativeCloudPalette: Sendable {
    public struct Channel: Sendable {
        public let color: Color
        public let seed: Int
        public let energy: Double
        public init(color: Color, seed: Int, energy: Double) {
            self.color = color; self.seed = seed; self.energy = energy
        }
    }
    public let channels: [Channel]
    public let phase: Double
    public let lobeScale: CGSize
    public init(channels: [Channel], phase: Double = 0, lobeScale: CGSize = CGSize(width: 1, height: 1)) {
        self.channels = channels; self.phase = phase; self.lobeScale = lobeScale
    }
}

/// Random waypoints addressed by time, so drawing never mutates animation state.
/// A retained instance seed gives each surface its own path. Skipping hidden frames
/// costs no catch-up work, and repeated samples stay still.
struct NativeCloudMotion {
    let seed: UInt64

    func value(at time: Double, lane: UInt64, duration: ClosedRange<Double> = 4...8) -> Double {
        let key = Self.mix(seed &+ lane &* 0x9e3779b97f4a7c15)
        let interval = duration.lowerBound + (duration.upperBound - duration.lowerBound) * Self.unit(key)
        // Stagger waypoint arrivals so lobes and their axes never stop together.
        let position = max(0, time) / interval + Self.unit(Self.mix(key))
        let segment = UInt64(position.rounded(.down))
        let progress = position - Double(segment)
        // Quintic easing keeps position, velocity and acceleration continuous.
        let eased = progress * progress * progress * (progress * (progress * 6 - 15) + 10)
        let start = Self.unit(Self.mix(key &+ segment))
        let end = Self.unit(Self.mix(key &+ segment &+ 1))
        return (start + (end - start) * eased) * 2 - 1
    }

    private static func unit(_ value: UInt64) -> Double {
        Double(value >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    private static func mix(_ value: UInt64) -> UInt64 {
        var value = value &+ 0x9e3779b97f4a7c15
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
}

public extension NativeCloudPalette {
    /// Shared visual palette. Harnesses still own where they choose to use it.
    static let blueIndigo = NativeCloudPalette(channels: [
        .init(color: NativePalette.color(0x799dff).swiftUI, seed: 136, energy: 0.42),
        .init(color: NativePalette.color(0x3941ff).swiftUI, seed: 73, energy: 0.31),
        .init(color: NativePalette.color(0xb1a7ff).swiftUI, seed: 211, energy: 0.34)
    ], phase: 1.2)
}
