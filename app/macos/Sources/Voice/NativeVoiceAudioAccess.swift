import Foundation
import MokuseiCore
@preconcurrency import LiveKitWebRTC

/// Availability is a persistent hardware gate, above WebRTC's recording and
/// playout requests. In particular, stopRecording alone can be undone by a peer.
@MainActor
protocol NativeVoiceAudioDevice: AnyObject {
    var inputRunning: Bool { get }
    var outputRunning: Bool { get }
    func setAvailability(input: Bool, output: Bool) -> Int
}

extension LKRTCAudioDeviceModule: NativeVoiceAudioDevice {
    private var effectiveState: NativeVoiceAudioEngineStatus {
        NativeVoiceAudioEngineStatus(state: engineState, availability: engineAvailability,
                                    manualRendering: isManualRenderingMode)
    }
    var inputRunning: Bool { effectiveState.inputRunning }
    var outputRunning: Bool { effectiveState.outputRunning }
    func setAvailability(input: Bool, output: Bool) -> Int {
        let result = setEngineAvailability(LKRTCAudioEngineAvailability(isInputAvailable: ObjCBool(input), isOutputAvailable: ObjCBool(output)))
        if NativePerformance.mode == .detailed {
            let status = effectiveState
            NativePerformance.event(.voiceMediaHealth, values: ["audioAvailabilityResult": Double(result),
                "requestedInputAvailable": input ? 1 : 0, "requestedOutputAvailable": output ? 1 : 0,
                "inputAvailable": status.availability.isInputAvailable.boolValue ? 1 : 0,
                "outputAvailable": status.availability.isOutputAvailable.boolValue ? 1 : 0,
                "inputRequested": status.state.inputRunning.boolValue ? 1 : 0,
                "outputRequested": status.state.outputRunning.boolValue ? 1 : 0,
                "inputEffective": status.inputRunning ? 1 : 0, "outputEffective": status.outputRunning ? 1 : 0])
        }
        return result
    }
}

/// The SDK's engineState and isRecording/isPlaying expose WebRTC's retained
/// requests, not the effective availability-gated state. Match AudioEngine's
/// IsInputRunning/IsOutputRunning rules so a successfully closed gate does not
/// falsely fail the call while keeping the request ready for explicit resume.
struct NativeVoiceAudioEngineStatus {
    let state: LKRTCAudioEngineState
    let availability: LKRTCAudioEngineAvailability
    var manualRendering = false

    var inputRunning: Bool {
        guard availability.isInputAvailable.boolValue else { return false }
        if manualRendering { return state.inputRunning.boolValue || state.outputRunning.boolValue }
        return state.inputRunning.boolValue && !(state.muteMode == .restartEngine && state.inputMuted.boolValue)
    }
    var outputRunning: Bool {
        guard availability.isOutputAvailable.boolValue else { return false }
        return state.outputRunning.boolValue || (manualRendering ? state.inputRunning.boolValue : inputRunning)
    }
}

struct NativeVoiceAudioAccess: Equatable {
    var enabled: Bool
    var muted: Bool
    var capture: Bool { enabled && !muted }
    var playback: Bool { enabled }

    @MainActor
    func apply(to device: any NativeVoiceAudioDevice) throws {
        guard device.setAvailability(input: capture, output: playback) == 0,
              capture || !device.inputRunning,
              playback || !device.outputRunning else {
            // The caller closes the peer on failure before granting a successor
            // device access; never claim a successful pause after an ADM error.
            throw NativeVoiceError("无法切换语音设备所有权")
        }
    }
}
