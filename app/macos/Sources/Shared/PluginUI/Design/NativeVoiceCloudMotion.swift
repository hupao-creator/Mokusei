import Foundation

/// Approved Moku mapping: loudness and syllable attacks drive flow and shape.
/// Pitch remains diagnostic; even quiet unvoiced speech must move the cloud.
/// Monotonic capture times distinguish silence/unvoiced audio from stale samples.
public struct NativeVoiceCloudMotion: Sendable {
    public private(set) var phase = 1.2
    public private(set) var speed = 0.16
    public private(set) var energy = 0.0
    public private(set) var shape = 0.0
    private var accent = 0.0
    private var lastTick: TimeInterval?

    public init() {}
    public mutating func pause() { lastTick = nil }

    public mutating func advance(at now: TimeInterval, level: Double, pitchHz: Double?, confidence: Double,
                                 capturedAt: TimeInterval, listening: Bool, muted: Bool) {
        guard now.isFinite else { return }
        let dt = lastTick.map { min(0.05, max(0, now - $0)) } ?? 0
        lastTick = now
        let fresh = listening && !muted && capturedAt.isFinite && now >= capturedAt && now - capturedAt <= 0.30
        // Match the approved preview's default microphone sensitivity (+6 dB),
        // without altering captured audio or provider input.
        let rms = fresh && level.isFinite ? min(1, max(0, level) * pow(10, 6.0 / 20)) : 0
        let targetEnergy = rms > 0 ? min(1, max(0, (20 * log10(rms) + 55) / 40)) : 0
        let before = energy
        energy = ease(energy, targetEnergy, dt: dt, duration: targetEnergy > energy ? 0.085 : 0.38)
        let attack = min(1, max(0, (energy - before) / max(dt, 0.001) * 0.3))
        accent = ease(accent, attack, dt: dt, duration: attack > accent ? 0.07 : 0.4)
        speed = ease(speed, 0.16 + 3.7 * pow(energy, 0.85) + 1.6 * accent, dt: dt, duration: 0.18)
        shape = ease(shape, min(1, max(0, 0.88 * energy + 0.25 * accent)), dt: dt, duration: 0.16)
        phase += dt * speed
    }
    private func ease(_ a: Double, _ b: Double, dt: Double, duration: Double) -> Double {
        a + (b - a) * (1 - exp(-dt / duration))
    }
}
