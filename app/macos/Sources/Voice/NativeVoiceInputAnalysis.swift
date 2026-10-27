import Accelerate
import Foundation

/// Scalars only. PCM stays inside the capture analyser and never enters runtime state.
public struct NativeVoiceInputAnalysis: Equatable, Sendable {
    public var level: Double
    public var pitchHz: Double?
    public var confidence: Double
    public var capturedAt: TimeInterval

    public init(level: Double = 0, pitchHz: Double? = nil, confidence: Double = 0,
                capturedAt: TimeInterval = 0) {
        self.level = level; self.pitchHz = pitchHz; self.confidence = confidence; self.capturedAt = capturedAt
    }
}

/// YIN cumulative normalized difference estimates periodicity independently of RMS.
/// Input is normalized mono PCM, already downsampled by the capture adapter.
enum NativeVoicePitchAnalysis {
    static func analyse(_ input: [Float], sampleRate: Double, capturedAt: TimeInterval) -> NativeVoiceInputAnalysis {
        guard (8_000...48_000).contains(sampleRate), input.count >= 512,
              input.allSatisfy(\.isFinite) else { return .init(capturedAt: capturedAt) }
        let count = input.count
        var samples = input.map(Double.init)
        let mean = samples.reduce(0, +) / Double(count)
        var energy = 0.0
        for i in samples.indices { samples[i] -= mean; energy += samples[i] * samples[i] }
        let rms = sqrt(energy / Double(count))
        var result = NativeVoiceInputAnalysis(level: min(1, rms), capturedAt: capturedAt)
        guard rms >= 0.006 else { return result }
        let minTau = max(2, Int(sampleRate / 800))
        let maxTau = min(Int(sampleRate / 65), count / 2)
        guard maxTau > minTau else { return result }
        var difference = [Double](repeating: 1, count: maxTau + 1)
        var cumulative = 0.0
        samples.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress!
            for tau in 1...maxTau {
                var value = 0.0
                vDSP_distancesqD(base, 1, base + tau, 1, &value, vDSP_Length(count - maxTau))
                cumulative += value
                difference[tau] = cumulative > 0 ? value * Double(tau) / cumulative : 1
            }
        }
        var tau = minTau
        while tau < maxTau {
            if difference[tau] < 0.13 {
                while tau + 1 < maxTau, difference[tau + 1] < difference[tau] { tau += 1 }
                break
            }
            tau += 1
        }
        guard tau < maxTau, difference[tau] <= 0.18 else { return result }
        let a = difference[tau - 1], b = difference[tau], c = difference[tau + 1]
        let denominator = 2 * (2 * b - c - a)
        let refined = Double(tau) + (abs(denominator) > 1e-9 ? (c - a) / denominator : 0)
        let hz = sampleRate / refined
        if (65...800).contains(hz) { result.pitchHz = hz; result.confidence = 1 - b }
        return result
    }
}
