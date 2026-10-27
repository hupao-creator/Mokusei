import Foundation
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiVoice
@testable import MokuseiPluginUI
@testable import MokuseiUI

@Suite(.serializedNative)
struct NativeVoiceAnalysisTests {
    @Test func pitchTracksFrequencyIndependentlyOfAmplitudeAndRejectsNoise() {
        for rate in [16_000.0, 22_050.0] {
            for hz in [80.0, 110, 220, 440, 570, 650] {
                for amplitude in [0.03, 0.1, 0.4] {
                    let samples: [Float] = (0..<2048).map { i in
                        let phase = 2 * Double.pi * hz * Double(i) / rate
                        return Float(amplitude * (sin(phase) + 0.23 * sin(phase * 2)) + 0.02)
                    }
                    let result = NativeVoicePitchAnalysis.analyse(samples, sampleRate: rate, capturedAt: 1)
                    #expect(abs((result.pitchHz ?? 0) - hz) / hz < 0.02)
                    #expect(result.confidence > 0.82)
                    #expect(result.level > amplitude * 0.5 && result.level < amplitude)
                }
            }
        }
        var seed: UInt32 = 42
        let noise: [Float] = (0..<2048).map { _ in
            seed = seed &* 1664525 &+ 1013904223
            return (Float(seed) / Float(UInt32.max) - 0.5) * 0.4
        }
        #expect(NativeVoicePitchAnalysis.analyse(noise, sampleRate: 16_000, capturedAt: 1).pitchHz == nil)
        for samples in [[Float](repeating: 0, count: 2048), [Float](repeating: 0.2, count: 2048), [.nan]] {
            #expect(NativeVoicePitchAnalysis.analyse(samples, sampleRate: 16_000, capturedAt: 1).pitchHz == nil)
        }
    }

    @Test func captureAdapterConsumesFloatS16AndRetiresQueuedAnalysis() async throws {
        let analyser = NativeVoiceCaptureAnalyser()
        analyser.audioProcessingInitialize(sampleRate: 48_000, channels: 1)
        analyser.setEnabled(true)
        func feed(_ hz: Double) {
            for block in 0..<25 {
                let values: [Float] = (0..<480).map { i in
                    Float(0.1 * 32768 * sin(2 * Double.pi * hz * Double(block * 480 + i) / 48_000))
                }
                values.withUnsafeBufferPointer { analyser.consumeWebRTCPCM($0.baseAddress!, frames: $0.count, capturedAt: Double(block + 1)) }
            }
        }
        feed(220)
        for _ in 0..<500 {
            if analyser.latest.pitchHz != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(abs(try #require(analyser.latest.pitchHz) - 220) < 2)
        #expect((0.06...0.08).contains(analyser.latest.level))
        feed(570)
        analyser.setEnabled(false)
        try await Task.sleep(for: .milliseconds(40))
        #expect(analyser.latest == .init())
        feed(570)
        #expect(analyser.latest == .init())
        analyser.setEnabled(true)
        feed(570)
        for _ in 0..<500 {
            if analyser.latest.pitchHz != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(abs(try #require(analyser.latest.pitchHz) - 570) < 3)
        analyser.audioProcessingRelease()
        #expect(analyser.latest == .init())
    }

    @Test func motionFollowsApprovedLoudnessMappingWithoutRequiringPitch() {
        func run(energy: Double, hz: Double?) -> NativeVoiceCloudMotion {
            var motion = NativeVoiceCloudMotion()
            // Inverse of the approved dB mapping, including default +6 dB sensitivity.
            let level = energy == 0 ? 0 : pow(10, (energy * 40 - 61) / 20)
            for frame in 0...600 {
                let now = 10 + Double(frame) / 60
                motion.advance(at: now, level: level, pitchHz: hz, confidence: hz == nil ? 0 : 0.99,
                    capturedAt: 10 + Double(frame / 3) / 20, listening: true, muted: false)
            }
            return motion
        }
        let tiers = [0.0, 0.2, 0.55, 0.95].map { run(energy: $0, hz: nil) }
        for (motion, speed) in zip(tiers, [0.16, 1.10, 2.39, 3.70]) {
            #expect(abs(motion.speed - speed) < 0.02)
        }
        for (quiet, loud) in zip(tiers, tiers.dropFirst()) {
            #expect(loud.speed > quiet.speed)
            #expect(loud.shape > quiet.shape)
        }
        let low = run(energy: 0.55, hz: 110), high = run(energy: 0.55, hz: 570)
        #expect(abs(low.speed - high.speed) < 0.001)
        #expect(abs(low.speed - tiers[2].speed) < 0.001)
    }

    @Test func motionReleasesOnSilenceStaleMuteAndStoppedListeningAndResumesWithoutJump() {
        func advance(_ motion: inout NativeVoiceCloudMotion, start: Double, frames: Int,
                     level: Double, capturedAt: Double? = nil, listening: Bool = true, muted: Bool = false) {
            for frame in 0...frames {
                let now = start + Double(frame) / 60
                motion.advance(at: now, level: level, pitchHz: nil, confidence: 0,
                    capturedAt: capturedAt ?? now, listening: listening, muted: muted)
            }
        }
        var speaking = NativeVoiceCloudMotion()
        advance(&speaking, start: 10, frames: 180, level: 0.1)
        #expect(speaking.speed > 3)
        for condition in 0..<5 {
            var retired = speaking
            advance(&retired, start: 13, frames: 360, level: condition == 0 ? 0 : 0.8,
                capturedAt: condition == 1 ? 13 : condition == 4 ? 100 : nil,
                listening: condition != 3, muted: condition == 2)
            #expect(abs(retired.speed - 0.16) < 0.001)
            #expect(retired.energy < 0.001 && retired.shape < 0.001)
        }
        speaking.pause()
        let phase = speaking.phase
        speaking.advance(at: 86_400, level: 0.1, pitchHz: nil, confidence: 0,
            capturedAt: 86_400, listening: true, muted: false)
        #expect(speaking.phase == phase)
        for (index, invalid) in [Double.nan, .infinity, -.infinity, -1].enumerated() {
            let now = 86_400.01 + Double(index) / 60
            speaking.advance(at: now, level: invalid, pitchHz: invalid, confidence: invalid,
                capturedAt: now, listening: true, muted: false)
            #expect(speaking.phase.isFinite && speaking.energy.isFinite && speaking.speed.isFinite && speaking.shape.isFinite)
        }
    }

    @Test func syllableAttackAddsMotionAndGeometryChangesAtConstantLightEnergy() {
        var motion = NativeVoiceCloudMotion()
        for frame in 0...60 {
            let now = Double(frame) / 60
            motion.advance(at: now, level: 0.1, pitchHz: nil, confidence: 0,
                capturedAt: now, listening: true, muted: false)
        }
        #expect(motion.speed > 0.16 + 3.7 * pow(motion.energy, 0.85))
        let size = CGSize(width: 560, height: 58)
        func field(energy: Double, shape: Double) -> NativeCloudLights {
            NativeVoiceCloudField.lights(palette: .blueIndigo, intensity: 0.88, time: 4,
                motionPhase: 2.8, energy: energy, shape: shape, size: size, colorScheme: .dark)
        }
        let quiet = field(energy: 0.2, shape: 0.176), loud = field(energy: 0.95, shape: 0.836)
        #expect(quiet.geometry != loud.geometry)
        #expect(quiet.colors == loud.colors)
        for offset in stride(from: 0, to: loud.geometry.count, by: 5) {
            #expect(quiet.geometry[offset + 4] == loud.geometry[offset + 4])
            #expect(quiet.geometry[offset] != loud.geometry[offset])
            #expect(quiet.geometry[offset + 1] != loud.geometry[offset + 1])
            #expect(loud.geometry[offset + 2] > 0 && loud.geometry[offset + 3] > 0)
            #expect(quiet.geometry[offset + 2] != loud.geometry[offset + 2])
            #expect(quiet.geometry[offset + 3] != loud.geometry[offset + 3])
        }
    }

    @Test func productionPCMAmplitudeDrivesMotionAtTheSameFrequency() async throws {
        let analyser = NativeVoiceCaptureAnalyser()
        analyser.audioProcessingInitialize(sampleRate: 48_000, channels: 1)
        defer { analyser.audioProcessingRelease() }
        var speeds: [Double] = []
        for amplitude in [0.003, 0.12] {
            analyser.setEnabled(false); analyser.setEnabled(true)
            for block in 0..<30 {
                let pcm = (0..<480).map { i in Float(32768 * amplitude * sin(2 * .pi * 160 * Double(block * 480 + i) / 48_000)) }
                pcm.withUnsafeBufferPointer { analyser.consumeWebRTCPCM($0.baseAddress!, frames: $0.count, capturedAt: 10) }
            }
            for _ in 0..<500 {
                if analyser.latest.capturedAt == 10 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let sample = analyser.latest
            #expect(sample.capturedAt == 10)
            var motion = NativeVoiceCloudMotion()
            for frame in 0...300 {
                let now = 10 + Double(frame) / 60
                motion.advance(at: now, level: sample.level, pitchHz: sample.pitchHz, confidence: sample.confidence,
                    capturedAt: now, listening: true, muted: false)
            }
            speeds.append(motion.speed)
        }
        #expect(speeds[0] > 0.8)
        #expect(speeds[1] > speeds[0] + 2)
    }
    @Test func delayedWorkerUsesNewestPCMAndCaptureTime() async throws {
        let queue = DispatchQueue(label: "voice-analysis-delayed-worker")
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        let analyser = NativeVoiceCaptureAnalyser(queue: queue)
        analyser.audioProcessingInitialize(sampleRate: 48_000, channels: 1)
        analyser.setEnabled(true)
        func feed(_ hz: Double, startingAt: Int) {
            for block in 0..<30 {
                let values = (0..<480).map { i in Float(3276.8 * sin(2 * .pi * hz * Double(block * 480 + i) / 48_000)) }
                values.withUnsafeBufferPointer {
                    analyser.consumeWebRTCPCM($0.baseAddress!, frames: $0.count, capturedAt: Double(startingAt + block))
                }
            }
        }
        feed(110, startingAt: 1)
        feed(570, startingAt: 101)
        #expect(analyser.latest == .init())
        gate.signal()
        for _ in 0..<500 {
            if analyser.latest.pitchHz != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(abs(try #require(analyser.latest.pitchHz) - 570) < 3)
        #expect(analyser.latest.capturedAt == 130)
        analyser.setEnabled(false)
    }

    @Test func queuedRetiredGenerationCannotBlockFreshCapture() async throws {
        let queue = DispatchQueue(label: "voice-analysis-retired-worker")
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        let analyser = NativeVoiceCaptureAnalyser(queue: queue)
        analyser.audioProcessingInitialize(sampleRate: 48_000, channels: 1)
        func feed() {
            for block in 0..<30 {
                let values = (0..<480).map { i in Float(3276.8 * sin(2 * .pi * 220 * Double(block * 480 + i) / 48_000)) }
                values.withUnsafeBufferPointer { analyser.consumeWebRTCPCM($0.baseAddress!, frames: $0.count, capturedAt: 1) }
            }
        }
        for _ in 0..<8 { analyser.setEnabled(true); feed(); analyser.setEnabled(false) }
        analyser.setEnabled(true)
        gate.signal()
        // A barrier observes completion of the retired job without scheduling
        // or manufacturing a new analysis from the empty successor ring.
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        #expect(analyser.latest == .init())
        feed()
        for _ in 0..<500 {
            if analyser.latest.pitchHz != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(abs(try #require(analyser.latest.pitchHz) - 220) < 2)
        analyser.audioProcessingRelease()
    }

    @MainActor @Test func normalThreadHidesIdleDockAnalysisButAdmitsExplicitInput() {
        let scene = NativeMokuSceneState()
        scene.setWindowVisible(true)
        #expect(scene.dockContentVisible)
        scene.overviewVisible = false
        #expect(!scene.dockContentVisible)
        scene.setInputOpen(true)
        #expect(scene.dockContentVisible)
        scene.setInputOpen(false)
        #expect(!scene.dockContentVisible)
        scene.setDockInteractionVisible(true, question: false)
        #expect(scene.dockContentVisible)
        scene.setSearchActive(true)
        #expect(!scene.dockContentVisible)
        scene.setSearchActive(false)
        scene.setWindowVisible(false)
        #expect(!scene.dockContentVisible)
    }

}
