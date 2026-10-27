import SwiftUI

public extension NativeCloudPalette {
    /// Shared visual palette. Harnesses still own where they choose to use it.
    static let blueIndigo = NativeCloudPalette(channels: [
        .init(color: NativePalette.color(0x799dff).swiftUI, seed: 136, energy: 0.42),
        .init(color: NativePalette.color(0x3941ff).swiftUI, seed: 73, energy: 0.31),
        .init(color: NativePalette.color(0xb1a7ff).swiftUI, seed: 211, energy: 0.34)
    ], phase: 1.2)
}

/// Paint above the native material and below the input content. This is the same
/// light field/Metal path as running Thread cards, fitted to a full-width aperture.
public struct NativeVoiceCloud: View {
    public var level: Double
    public var pitchHz: Double?
    public var confidence: Double
    public var capturedAt: TimeInterval
    public var listening: Bool
    public var muted: Bool
    public var visible: Bool
    public var motionEnabled: Bool
    public var palette: NativeCloudPalette
    @Environment(\.colorScheme) private var scheme
    @State private var motion = NativeVoiceCloudMotion()

    public init(level: Double = 0, pitchHz: Double? = nil, confidence: Double = 0,
                capturedAt: TimeInterval = 0, listening: Bool = false, muted: Bool = false,
                visible: Bool = true, motionEnabled: Bool = true, palette: NativeCloudPalette = .blueIndigo) {
        self.level = level; self.pitchHz = pitchHz; self.confidence = confidence; self.capturedAt = capturedAt
        self.listening = listening; self.muted = muted; self.visible = visible; self.palette = palette
        self.motionEnabled = motionEnabled
    }
    private var staticDrawing: Bool { !motionEnabled }
    public var body: some View {
        TimelineView(.animation(minimumInterval: NativeFrameRate.interval, paused: staticDrawing || !visible)) { timeline in
            if visible {
                GeometryReader { geometry in
                    let phase = staticDrawing ? 3.8 : motion.phase
                    let intensity = muted ? 0.35 : staticDrawing ? 0.83 : 0.65 + motion.energy * 0.45
                    NativeCloudMetalField(lights: NativeVoiceCloudField.lights(palette: palette, intensity: intensity,
                        time: phase + palette.phase, motionPhase: phase,
                        energy: staticDrawing ? 0 : motion.energy,
                        shape: staticDrawing ? 0 : motion.shape,
                        size: geometry.size, colorScheme: scheme))
                }
                .onChange(of: timeline.date, initial: true) { _, _ in
                    guard !staticDrawing, visible else { motion.pause(); return }
                    motion.advance(at: ProcessInfo.processInfo.systemUptime, level: level, pitchHz: pitchHz,
                        confidence: confidence, capturedAt: capturedAt, listening: listening, muted: muted)
                }
            }
        }
        .onChange(of: visible) { _, _ in motion.pause() }
        .onChange(of: staticDrawing) { _, _ in motion.pause() }
        .onDisappear { motion.pause() }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

enum NativeVoiceCloudField {
    static func lights(palette: NativeCloudPalette, intensity: Double, time: Double, motionPhase: Double,
                       energy: Double, shape: Double,
                       size: CGSize, colorScheme: ColorScheme) -> NativeCloudLights {
        guard size.width > 0, size.height > 0 else { return .init() }
        var lights = NativeCloudField(palette: palette, intensity: intensity, time: time, seed: 42)
            .lights(in: CGSize(width: 340, height: 180), colorScheme: colorScheme)
        for offset in stride(from: 0, to: lights.geometry.count, by: 5) {
            let channel = Double(offset / 30), lobe = Double((offset / 5) % 6 / 2)
            let angle = motionPhase * 0.9 + channel * 2.094 + lobe * 0.6
            lights.geometry[offset] = lights.geometry[offset] * Float(size.width / 340)
                + Float(size.width * (0.018 + energy * 0.21) * sin(angle))
            lights.geometry[offset + 1] = lights.geometry[offset + 1] * Float(size.height / 180)
                + Float(size.height * (0.03 + shape * 0.36) * cos(angle * 1.15 + channel))
            lights.geometry[offset + 2] *= Float(size.width / 340 * (1 - shape * 0.24 + shape * 0.13 * sin(angle)))
            lights.geometry[offset + 3] *= Float(size.height / 180 * (1 - shape * 0.32 + shape * 0.26 * cos(angle * 1.4)))
        }
        return lights
    }
}
