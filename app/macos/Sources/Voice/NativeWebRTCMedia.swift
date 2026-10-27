import AVFoundation
import CoreAudio
import Foundation
import MokuseiCore
@preconcurrency import LiveKitWebRTC

/// One factory per call owns the native AudioEngine ADM, microphone and speaker.
/// No AV capture session, browser or hidden media window exists alongside it.
@MainActor
final class NativeWebRTCMedia: NSObject, NativeVoiceMediaTransport {
    private static let initializedSSL = LKRTCInitializeSSL()
    private var factory: LKRTCPeerConnectionFactory?
    private var peer: LKRTCPeerConnection?
    private var track: LKRTCAudioTrack?
    private var channel: LKRTCDataChannel?
    private var closed = false
    private var healthTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var captureAnalyser: NativeVoiceCaptureAnalyser?
    private var audioProcessing: LKRTCDefaultAudioProcessingModule?
    private var analysisRequested = false
    private var access = NativeVoiceAudioAccess(enabled: true, muted: false)
    private var pending: [UUID: () -> Void] = [:]
    private let timingContext = NativePerformance.context
    private lazy var connectionRecovery = NativeVoiceConnectionRecovery { [weak self] failure in
        guard let self else { return }
        switch failure {
        case .ice: self.reportFailure("语音媒体连接已断开", source: .ice)
        case .peer: self.reportFailure("语音媒体连接已断开", source: .peer)
        case .timeout: self.reportFailure("语音媒体连接未能恢复，请点按开始重试", source: .recoveryDeadline)
        }
    }
    var onFailure: ((String) -> Void)?
    var onMessage: ((Data) -> Void)?
    var onInputAnalysis: ((NativeVoiceInputAnalysis) -> Void)?

    static func requestMicrophone() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw NativeVoiceError("未获得麦克风权限，请在系统设置中允许 Mokusei 使用麦克风")
            }
        case .denied, .restricted:
            throw NativeVoiceError("未获得麦克风权限，请在系统设置中允许 Mokusei 使用麦克风")
        @unknown default: throw NativeVoiceError("无法确认麦克风权限")
        }
    }

    func offer() async throws -> String {
        try checkOpen()
        guard Self.initializedSSL else { throw NativeVoiceError("无法初始化语音加密传输") }
        guard Self.deviceAvailable(input: true) else { throw NativeVoiceError("没有可用的麦克风") }
        guard Self.deviceAvailable(input: false) else { throw NativeVoiceError("没有可用的音频输出设备") }
        let initialization = NativePerformance.begin(.voiceFactory)
        defer { initialization?.end(.failed) }
        let capture = NativeVoiceCaptureAnalyser()
        captureAnalyser = capture
        let processing = Self.makeCaptureProcessingModule(capture: capture)
        audioProcessing = processing
        let factory = LKRTCPeerConnectionFactory(audioDeviceModuleType: .audioEngine,
            bypassVoiceProcessing: false, encoderFactory: nil, decoderFactory: nil, audioProcessingModule: processing)
        self.factory = factory
        try access.apply(to: factory.audioDeviceModule)
        let configuration = LKRTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        // The established app-server route receives a complete SDP offer. Do not
        // invent STUN/TURN endpoints or send provider credentials to the client.
        guard let peer = factory.peerConnection(with: configuration,
            constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self) else {
            throw NativeVoiceError("无法创建语音媒体连接")
        }
        self.peer = peer
        let source = factory.audioSource(with: LKRTCMediaConstraints(mandatoryConstraints: nil,
            optionalConstraints: ["googEchoCancellation": "true", "googNoiseSuppression": "true", "googAutoGainControl": "true"]))
        let track = factory.audioTrack(with: source, trackId: "mokusei-microphone")
        self.track = track
        track.isEnabled = access.capture
        guard peer.add(track, streamIds: ["mokusei-voice"]) != nil else { throw NativeVoiceError("无法连接麦克风轨道") }
        let channelConfiguration = LKRTCDataChannelConfiguration()
        channelConfiguration.isOrdered = true
        guard let channel = peer.dataChannel(forLabel: "oai-events", configuration: channelConfiguration) else {
            throw NativeVoiceError("无法创建语音数据通道")
        }
        self.channel = channel
        channel.delegate = self
        initialization?.end()
        let localSDP = NativePerformance.begin(.voiceLocalSDP)
        defer { localSDP?.end(.failed) }
        let offer: String = try await operation("无法生成语音 SDP") { completion in
            peer.offer(for: LKRTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true"], optionalConstraints: nil)) { sdp, error in
                if let sdp { completion(.success(sdp.sdp)) }
                else { completion(.failure(NativeVoiceError(error?.localizedDescription ?? "无法生成语音 SDP"))) }
            }
        }
        try checkOpen()
        let _: Bool = try await operation("设置语音 SDP 超时") { completion in
            peer.setLocalDescription(LKRTCSessionDescription(type: .offer, sdp: offer)) { error in
                if let error { completion(.failure(NativeVoiceError(error.localizedDescription))) }
                else { completion(.success(true)) }
            }
        }
        localSDP?.end()
        try await measure(.voiceICE) { try await waitUntil("ICE 收集超时") { peer.iceGatheringState == .complete } }
        guard let sdp = peer.localDescription?.sdp, !sdp.isEmpty, sdp.utf16.count <= 128_000 else {
            throw NativeVoiceError("无法生成有效的语音 SDP")
        }
        return sdp
    }

    /// LiveKitWebRTC 150.7871.02's adapter initializer ignores its delegate
    /// argument. Use the setter, which also initializes an already-built APM's
    /// observer. Keeping this wiring separate permits a regression without ADM.
    static func makeCaptureProcessingModule(capture: NativeVoiceCaptureAnalyser) -> LKRTCDefaultAudioProcessingModule {
        let processing = LKRTCDefaultAudioProcessingModule(config: nil,
            capturePostProcessingDelegate: nil, renderPreProcessingDelegate: nil)
        processing.capturePostProcessingDelegate = capture
        return processing
    }

    func connect(answer: String) async throws {
        try checkOpen()
        guard let peer, let channel else { throw NativeVoiceError("语音媒体尚未准备好") }
        let _: Bool = try await operation("设置语音应答超时") { completion in
            peer.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: answer)) { error in
                if let error { completion(.failure(NativeVoiceError(error.localizedDescription))) }
                else { completion(.success(true)) }
            }
        }
        try await measure(.voicePeerReady) { try await waitUntil("语音媒体连接超时") { peer.connectionState == .connected && channel.readyState == .open } }
        // WebRTC starts the ADM as audio is negotiated. Explicitly checking its
        // state catches native capture/playback initialization failures that do
        // not otherwise cause an ICE or data-channel failure.
        try await measure(.voiceAudioReady) { try await waitUntil("无法启动麦克风或音频播放") { [weak self] in
            guard let adm = self?.factory?.audioDeviceModule else { return false }
            return adm.isRecording && adm.isPlaying && adm.isEngineRunning
        } }
        updateAnalysis()
        healthTask = Task { [weak self] in
            var diagnosticTick = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, !self.closed, let adm = self.factory?.audioDeviceModule else { return }
                // A suspended connection still monitors ICE/data-channel health,
                // but deliberately has neither microphone nor speaker running.
                if (!self.access.capture && adm.inputRunning) || (!self.access.playback && adm.outputRunning) {
                    self.reportFailure("语音设备越过了媒体所有权限制", source: .audioOwnership); return
                }
                guard self.access.enabled else { continue }
                if self.access.capture && (!Self.deviceAvailable(input: true) || !adm.inputRunning) {
                    self.reportFailure("麦克风已断开", source: .microphone); return
                }
                if !Self.deviceAvailable(input: false) || !adm.outputRunning || !adm.isEngineRunning {
                    self.reportFailure("音频播放设备已断开", source: .playback); return
                }
                diagnosticTick += 1
                if NativePerformance.mode == .detailed && diagnosticTick % 4 == 0 { self.recordMediaHealth() }
            }
        }
    }

    /// Opt-in numeric transport evidence. No PCM, transcripts, addresses or
    /// provider identifiers are recorded. This also distinguishes a live socket
    /// from actual WebRTC audio continuing while the application is backgrounded.
    private func recordMediaHealth() {
        guard let peer, let adm = factory?.audioDeviceModule, !closed else { return }
        let sample: [String: Double] = ["recording": adm.isRecording ? 1 : 0,
            "playing": adm.isPlaying ? 1 : 0, "engine": adm.isEngineRunning ? 1 : 0,
            "inputAvailable": adm.engineAvailability.isInputAvailable.boolValue ? 1 : 0,
            "outputAvailable": adm.engineAvailability.isOutputAvailable.boolValue ? 1 : 0,
            "inputEffective": adm.inputRunning ? 1 : 0, "outputEffective": adm.outputRunning ? 1 : 0,
            "capture": access.capture ? 1 : 0, "connected": peer.connectionState == .connected ? 1 : 0]
        let initial = sample, context = NativePerformance.context
        peer.statistics { @Sendable report in
            var sample = initial
            for statistic in report.statistics.values {
                guard statistic.values["kind"] as? String == "audio" else { continue }
                if statistic.type == "outbound-rtp" {
                    sample["sentPackets", default: 0] += (statistic.values["packetsSent"] as? NSNumber)?.doubleValue ?? 0
                    sample["sentBytes", default: 0] += (statistic.values["bytesSent"] as? NSNumber)?.doubleValue ?? 0
                } else if statistic.type == "inbound-rtp" {
                    sample["receivedPackets", default: 0] += (statistic.values["packetsReceived"] as? NSNumber)?.doubleValue ?? 0
                    sample["receivedAudioEnergy", default: 0] += (statistic.values["totalAudioEnergy"] as? NSNumber)?.doubleValue ?? 0
                } else if statistic.type == "media-source" {
                    sample["microphoneAudioEnergy", default: 0] += (statistic.values["totalAudioEnergy"] as? NSNumber)?.doubleValue ?? 0
                }
            }
            NativePerformance.event(.voiceMediaHealth, context: context, values: sample)
        }
    }

    var channelOpen: Bool { !closed && channel?.readyState == .open }
    func send(_ data: Data) throws {
        // These synchronous operations may restore Moku from a cancelled Thread
        // task. That task's cancellation must not retire Moku's valid peer.
        guard !closed else { throw NativeVoiceError("语音媒体已关闭") }
        guard let channel, channel.readyState == .open,
              channel.sendData(LKRTCDataBuffer(data: data, isBinary: false)) else {
            throw NativeVoiceError("语音数据通道已断开")
        }
    }
    func setAudioEnabled(_ enabled: Bool, muted: Bool) throws {
        guard !closed else { throw NativeVoiceError("语音媒体已关闭") }
        access = NativeVoiceAudioAccess(enabled: enabled, muted: muted)
        // Close the RTP source first. The ADM gate also prevents hidden capture
        // and automatic restart when remote tracks or device routes change.
        track?.isEnabled = false
        updateAnalysis()
        if let adm = factory?.audioDeviceModule { try access.apply(to: adm) }
        track?.isEnabled = access.capture
    }
    func setAnalysisEnabled(_ enabled: Bool) {
        guard analysisRequested != enabled else { return }
        analysisRequested = enabled; updateAnalysis()
    }
    private func updateAnalysis() {
        analysisTask?.cancel(); analysisTask = nil
        let enabled = analysisRequested && access.capture && !closed
        captureAnalyser?.setEnabled(enabled)
        guard enabled else { onInputAnalysis?(.init()); return }
        // Poll one latest scalar result, never queue unbounded MainActor work
        // from the audio callback. A stalled renderer cannot backlog PCM jobs.
        analysisTask = Task { [weak self] in
            var last = NativeVoiceInputAnalysis()
            while !Task.isCancelled {
                guard let self, !self.closed, let capture = self.captureAnalyser else { return }
                let sample = capture.latest
                if sample != last { self.onInputAnalysis?(sample); last = sample }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
    }

    /// Release capture and playback synchronously before awaiting backend stop.
    func close() {
        guard !closed else { return }
        recordConnectionState(closing: true)
        closed = true
        connectionRecovery.close()
        onFailure = nil; onMessage = nil; onInputAnalysis = nil
        analysisTask?.cancel(); analysisTask = nil
        captureAnalyser?.setEnabled(false)
        audioProcessing?.capturePostProcessingDelegate = nil
        healthTask?.cancel(); healthTask = nil
        let cancellations = Array(pending.values); pending.removeAll()
        for cancel in cancellations { cancel() }
        channel?.delegate = nil; channel?.close(); channel = nil
        track?.isEnabled = false; track = nil
        peer?.delegate = nil; peer?.close(); peer = nil
        if let adm = factory?.audioDeviceModule {
            _ = adm.setAvailability(input: false, output: false)
            _ = adm.stopRecording(); _ = adm.stopPlayout()
        }
        factory = nil
        audioProcessing = nil; captureAnalyser = nil
    }

    private func checkOpen() throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
    }
    private func waitUntil(_ message: String, ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while true {
            try checkOpen()
            if ready() { return }
            guard ContinuousClock.now < deadline else { throw NativeVoiceError(message) }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    private func operation<T: Sendable>(_ message: String,
        start: (@escaping @Sendable (Result<T, NativeVoiceError>) -> Void) -> Void) async throws -> T {
        try checkOpen()
        let id = UUID()
        defer { pending[id] = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = NativeVoiceContinuation(continuation)
            pending[id] = { gate.finish(.failure(CancellationError())) }
            gate.timeout = Task {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                gate.finish(.failure(NativeVoiceError(message)))
            }
            start { result in Task { @MainActor in gate.finish(result.mapError { $0 as Error }) } }
        }
    }

    private static func deviceAvailable(input: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return false }
        address.mSelector = kAudioDevicePropertyDeviceIsAlive
        var alive: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive) == noErr && alive != 0
    }


    private enum FailureSource: Int {
        case ice = 1, peer, channel, recoveryDeadline, audioOwnership, microphone, playback, audioSession
    }

    private func reportFailure(_ message: String, source: FailureSource) {
        guard !closed else { return }
        recordConnectionState(failure: source)
        onFailure?(message)
    }

    /// Numeric SDK states distinguish transient disconnection from terminal ICE,
    /// peer or channel failure even when the periodic health loop has stopped.
    private func recordConnectionState(failure: FailureSource? = nil, closing: Bool = false) {
        guard NativePerformance.mode == .detailed else { return }
        var values: [String: Double] = [
            "mediaStateChange": 1,
            "iceState": Double(peer?.iceConnectionState.rawValue ?? -1),
            "peerState": Double(peer?.connectionState.rawValue ?? -1),
            "channelState": Double(channel?.readyState.rawValue ?? -1),
            "transportClosing": closing ? 1 : 0
        ]
        if let failure { values["mediaFailureSource"] = Double(failure.rawValue) }
        NativePerformance.event(.voiceMediaHealth, context: timingContext, values: values)
    }

    nonisolated private func connectionChanged(_ peerConnection: LKRTCPeerConnection) {
        Task { @MainActor [weak self] in
            guard let self, !self.closed, self.peer === peerConnection else { return }
            self.recordConnectionState()
            // Read the current pair together, rather than replaying a stale
            // disconnected callback after the signaling queue has recovered.
            self.connectionRecovery.update(ice: peerConnection.iceConnectionState,
                                           peer: peerConnection.connectionState)
        }
    }
}

@MainActor
private final class NativeVoiceContinuation<T: Sendable> {
    private var continuation: CheckedContinuation<T, Error>?
    var timeout: Task<Void, Never>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    func finish(_ result: Result<T, Error>) {
        guard let continuation else { return }
        self.continuation = nil; timeout?.cancel(); timeout = nil
        continuation.resume(with: result)
    }
}

extension NativeWebRTCMedia: LKRTCPeerConnectionDelegate, LKRTCDataChannelDelegate {
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        connectionChanged(peerConnection)
    }
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
        connectionChanged(peerConnection)
    }
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}
    nonisolated func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        Task { @MainActor [weak self] in
            guard let self, !self.closed, self.channel === dataChannel else { return }
            self.recordConnectionState()
            if dataChannel.readyState == .closed || dataChannel.readyState == .closing {
                self.reportFailure("语音通道已关闭", source: .channel)
            }
        }
    }
    nonisolated func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        guard !buffer.isBinary else { return }
        let data = buffer.data
        guard data.count <= 1_048_576 else { return }
        Task { @MainActor [weak self] in guard let self, !self.closed else { return }; self.onMessage?(data) }
    }
}
