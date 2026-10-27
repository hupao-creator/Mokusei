import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import Foundation
@testable import MokuseiVoice

@Suite(.serializedNative)
struct NativeVoiceCaptureWiringTests {
    @MainActor @Test func productionModuleAttachesCaptureObserverWithoutOpeningAudioDevice() {
        let capture = NativeVoiceCaptureAnalyser()
        let processing = NativeWebRTCMedia.makeCaptureProcessingModule(capture: capture)
        #expect(processing.capturePostProcessingDelegate === capture)
        #expect(processing.renderPreProcessingDelegate == nil)
        processing.capturePostProcessingDelegate = nil
        #expect(processing.capturePostProcessingDelegate == nil)
    }

    @MainActor @Test func availabilityGatesDoNotEraseTheSDKsRetainedRecordingRequests() throws {
        let device = RetainedRequestAudioDevice()
        try NativeVoiceAudioAccess(enabled: true, muted: true).apply(to: device)
        #expect(device.status.state.inputRunning.boolValue && device.status.state.outputRunning.boolValue)
        #expect(!device.inputRunning && device.outputRunning)
        try NativeVoiceAudioAccess(enabled: true, muted: false).apply(to: device)
        #expect(device.inputRunning && device.outputRunning)
        try NativeVoiceAudioAccess(enabled: false, muted: true).apply(to: device)
        #expect(!device.inputRunning && !device.outputRunning)
        #expect(device.status.state.inputRunning.boolValue && device.status.state.outputRunning.boolValue)

        try NativeVoiceAudioAccess(enabled: true, muted: false).apply(to: device)
        device.ignoreAvailability = true
        #expect(throws: NativeVoiceError.self) {
            try NativeVoiceAudioAccess(enabled: false, muted: true).apply(to: device)
        }
        device.ignoreAvailability = false; device.result = -1
        #expect(throws: NativeVoiceError.self) {
            try NativeVoiceAudioAccess(enabled: true, muted: true).apply(to: device)
        }
    }

    @MainActor @Test func nativeEngineReadbackRespectsCoupledOutputAndRestartMute() {
        let device = RetainedRequestAudioDevice()
        var state = device.status.state
        state.outputRunning = false
        var status = NativeVoiceAudioEngineStatus(state: state, availability: device.status.availability)
        #expect(status.inputRunning && status.outputRunning)
        state.inputMuted = true; state.muteMode = .restartEngine
        status = NativeVoiceAudioEngineStatus(state: state, availability: device.status.availability)
        #expect(!status.inputRunning && !status.outputRunning)
        status = NativeVoiceAudioEngineStatus(state: state, availability: device.status.availability, manualRendering: true)
        #expect(status.inputRunning && status.outputRunning)
    }

    @MainActor @Test func productionConnectionRecoveryHasOneDeadlineUntilBothTransportsRecover() async throws {
        let delay = VoiceConnectionDelay()
        defer { delay.releaseAll() }
        var failures: [NativeVoiceConnectionRecovery.Failure] = []
        let recovery = NativeVoiceConnectionRecovery(delay: { await delay.wait() }) { failures.append($0) }
        recovery.update(ice: .connected, peer: .connected)
        recovery.update(ice: .disconnected, peer: .connected)
        try await connectionEventually { delay.waits == 1 }
        #expect(failures.isEmpty)
        // An aggregate peer recovery cannot hide a still-disconnected ICE path.
        recovery.update(ice: .disconnected, peer: .connected)
        recovery.update(ice: .checking, peer: .connecting)
        #expect(delay.waits == 1 && failures.isEmpty)
        recovery.update(ice: .completed, peer: .connected)
        delay.releaseAll()
        try await connectionEventually { delay.completions == 1 }
        #expect(failures.isEmpty)

        recovery.update(ice: .connected, peer: .disconnected)
        try await connectionEventually { delay.waits == 2 }
        recovery.update(ice: .checking, peer: .connecting)
        recovery.update(ice: .disconnected, peer: .disconnected)
        #expect(delay.waits == 2)
        delay.releaseAll()
        try await connectionEventually { failures == [.timeout] }
        recovery.update(ice: .connected, peer: .connected)
        recovery.update(ice: .disconnected, peer: .disconnected)
        #expect(delay.waits == 2 && failures == [.timeout])
    }

    @MainActor @Test(arguments: [0, 1, 2, 3])
    func productionConnectionRecoveryDoesNotDelayTerminalStates(terminal: Int) async throws {
        let delay = VoiceConnectionDelay()
        defer { delay.releaseAll() }
        var failures: [NativeVoiceConnectionRecovery.Failure] = []
        let recovery = NativeVoiceConnectionRecovery(delay: { await delay.wait() }) { failures.append($0) }
        recovery.update(ice: .disconnected, peer: .disconnected)
        try await connectionEventually { delay.waits == 1 }
        switch terminal {
        case 0: recovery.update(ice: .failed, peer: .connected)
        case 1: recovery.update(ice: .closed, peer: .connected)
        case 2: recovery.update(ice: .connected, peer: .failed)
        default: recovery.update(ice: .connected, peer: .closed)
        }
        #expect(failures == [terminal < 2 ? .ice : .peer])
        delay.releaseAll()
        try await connectionEventually { delay.completions == 1 }
        #expect(failures.count == 1)
    }

    @MainActor @Test func closingProductionConnectionCancelsRecoveryAndRejectsLateCallbacks() async throws {
        let delay = VoiceConnectionDelay()
        defer { delay.releaseAll() }
        var failures: [NativeVoiceConnectionRecovery.Failure] = []
        let recovery = NativeVoiceConnectionRecovery(delay: { await delay.wait() }) { failures.append($0) }
        recovery.update(ice: .disconnected, peer: .connected)
        try await connectionEventually { delay.waits == 1 }
        recovery.close()
        recovery.update(ice: .connected, peer: .connected)
        recovery.update(ice: .failed, peer: .failed)
        recovery.update(ice: .disconnected, peer: .disconnected)
        delay.releaseAll()
        try await connectionEventually { delay.completions == 1 }
        #expect(delay.waits == 1 && failures.isEmpty)
    }
}

/// Matches the native SDK contract: closing availability preserves WebRTC's
/// recording/playout requests so reopening the gate can resume the same call.
@MainActor private final class RetainedRequestAudioDevice: NativeVoiceAudioDevice {
    var status = NativeVoiceAudioEngineStatus(
        state: .init(outputEnabled: true, outputRunning: true, inputEnabled: true, inputRunning: true,
                     inputMuted: false, muteMode: .voiceProcessing),
        availability: .init(isInputAvailable: true, isOutputAvailable: true))
    var ignoreAvailability = false
    var result = 0
    var inputRunning: Bool { status.inputRunning }
    var outputRunning: Bool { status.outputRunning }
    func setAvailability(input: Bool, output: Bool) -> Int {
        if result == 0 && !ignoreAvailability {
            status = NativeVoiceAudioEngineStatus(state: status.state,
                availability: .init(isInputAvailable: ObjCBool(input), isOutputAvailable: ObjCBool(output)))
        }
        return result
    }
}

/// Deliberately ignores cancellation so the production generation/cancellation
/// fence must reject a timeout delivered after recovery or explicit close.
@MainActor private final class VoiceConnectionDelay {
    private var pending: [CheckedContinuation<Void, Never>] = []
    private(set) var waits = 0
    private(set) var completions = 0
    func wait() async {
        waits += 1
        await withCheckedContinuation { pending.append($0) }
        completions += 1
    }
    func releaseAll() {
        let current = pending; pending.removeAll()
        for continuation in current { continuation.resume() }
    }
}

@MainActor private func connectionEventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw NativeVoiceError("Connection replay timed out") }
        try await Task.sleep(for: .milliseconds(1))
    }
}
