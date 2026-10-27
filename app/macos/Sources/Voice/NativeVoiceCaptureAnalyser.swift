import Foundation
@preconcurrency import LiveKitWebRTC

/// Read-only observer of the existing WebRTC capture path. No device or engine is
/// created here. Capture callbacks never wait for DSP, dispatch UI work, or write PCM.
final class NativeVoiceCaptureAnalyser: NSObject, LKRTCAudioCustomProcessingDelegate, @unchecked Sendable {
    private struct State {
        var enabled = false
        var sampleRate = 0.0
        var generation: UInt64 = 0
        var ring = [Float](repeating: 0, count: 2048)
        var index = 0
        var count = 0
        var sinceAnalysis = 0
        var decimationIndex = 0
        var decimationSum: Float = 0
        var busy = false
        var capturedAt: TimeInterval = 0
        var latest = NativeVoiceInputAnalysis()

        mutating func reset() {
            generation &+= 1; index = 0; count = 0; sinceAnalysis = 0
            // One global in-flight job survives generation changes until the
            // worker retires it; rapid visibility/mute changes cannot queue PCM.
            decimationIndex = 0; decimationSum = 0; capturedAt = 0; latest = .init()
            for i in ring.indices { ring[i] = 0 }
        }
    }
    private let lock = NSLock()
    private var state = State()
    private let queue: DispatchQueue

    init(queue: DispatchQueue = DispatchQueue(label: "com.mokusei.voice.pitch", qos: .utility)) {
        self.queue = queue
        super.init()
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard state.enabled != enabled else { return }
        state.enabled = enabled; state.reset()
    }
    var latest: NativeVoiceInputAnalysis {
        lock.lock(); defer { lock.unlock() }
        return state.latest
    }
    func audioProcessingInitialize(sampleRate: Int, channels: Int) {
        lock.lock(); defer { lock.unlock() }
        state.sampleRate = channels > 0 ? Double(sampleRate) : 0
        state.reset()
    }
    func audioProcessingRelease() {
        lock.lock(); defer { lock.unlock() }
        state.sampleRate = 0; state.reset()
    }
    func audioProcessingProcess(audioBuffer: LKRTCAudioBuffer) {
        guard audioBuffer.channels > 0 else { return }
        consumeWebRTCPCM(audioBuffer.rawBuffer(forChannel: 0), frames: audioBuffer.frames,
                         capturedAt: ProcessInfo.processInfo.systemUptime)
    }

    /// The APM's raw AudioBuffer uses FloatS16, not normalized AVAudioEngine floats.
    /// Exposed internally so fixed PCM can exercise the exact production adapter.
    func consumeWebRTCPCM(_ input: UnsafePointer<Float>, frames: Int, capturedAt: TimeInterval) {
        guard frames > 0, frames <= 3840, lock.try() else { return }
        guard state.enabled, (8_000...192_000).contains(state.sampleRate) else { lock.unlock(); return }
        let stride = max(1, Int(state.sampleRate / 16_000))
        // Box-average before decimation, retaining the partial group across 10 ms callbacks.
        for i in 0..<frames {
            let sample = input[i].isFinite ? min(1, max(-1, input[i] / 32768)) : 0
            state.decimationSum += sample; state.decimationIndex += 1
            if state.decimationIndex == stride {
                state.ring[state.index] = state.decimationSum / Float(stride)
                state.index = (state.index + 1) % state.ring.count
                state.count = min(state.ring.count, state.count + 1); state.sinceAnalysis += 1
                state.decimationIndex = 0; state.decimationSum = 0
            }
        }
        state.capturedAt = capturedAt
        let rate = state.sampleRate / Double(stride)
        guard state.count == state.ring.count, !state.busy, state.sinceAnalysis >= Int(rate / 20) else { lock.unlock(); return }
        let generation = state.generation
        state.busy = true; state.sinceAnalysis = 0
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.state.enabled, self.state.generation == generation else {
                self.state.busy = false; self.lock.unlock(); return
            }
            // Allocate/copy on the utility worker, never on the capture callback.
            // A delayed worker analyses the newest complete ring and timestamp.
            let samples = Array(self.state.ring[self.state.index...]) + Array(self.state.ring[..<self.state.index])
            let capturedAt = self.state.capturedAt
            self.lock.unlock()
            let result = NativeVoicePitchAnalysis.analyse(samples, sampleRate: rate, capturedAt: capturedAt)
            self.lock.lock(); defer { self.lock.unlock() }
            self.state.busy = false
            guard self.state.enabled, self.state.generation == generation else { return }
            self.state.latest = result
        }
    }
}
