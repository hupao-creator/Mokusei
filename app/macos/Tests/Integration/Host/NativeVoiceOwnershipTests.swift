import Foundation
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
@testable import MokuseiVoice

@MainActor
@Suite(.serializedNative)
struct NativeVoiceOwnershipTests {
    @Test func nativeSettingsReconnectRetainsCallIntentAndMute() async throws {
        let replay = VoiceReplay()
        let call = replay.call()
        await call.client.start()
        let previous = call.backend.ownershipID
        call.client.toggleMute()
        call.backend.reconnect = true
        try await until { call.backend.starts == 2 && call.client.state.phase == .listening }
        #expect(call.backend.reconnectFrom == .string(previous))
        #expect(call.backend.prepares == 2 && call.media.offers == 2)
        #expect(call.client.state.muted && !call.media.device.inputRunning)
        #expect(call.backend.stops.isEmpty)
        await call.client.stop()
    }

    @Test func nativeSettingsReconnectWaitsForCapturedSpeech() async throws {
        let replay = VoiceReplay()
        let call = replay.call()
        await call.client.start()
        try call.media.message("input_audio_buffer.speech_started")
        let polls = call.backend.polls
        call.backend.reconnect = true
        try await until { call.backend.polls >= polls + 2 }
        #expect(call.backend.prepares == 1)
        try call.media.message("input_audio_buffer.speech_stopped")
        call.backend.reconnectRetired = true
        call.backend.rawPollEvents = [
            .object(["sequence": .integer(1), "type": .text("input"), "generation": .integer(1)]),
            .object(["sequence": .integer(2), "type": .text("closed")])
        ]
        try await until { call.backend.starts == 2 && call.client.state.phase == .listening }
        #expect(call.backend.prepares == 2)
        await call.client.stop()
    }

    @Test func nativeReconnectDoesNotCutBufferedAudioOrNewSpeechForLateAnswers() async throws {
        let replay = VoiceReplay()
        let call = replay.call()
        await call.client.start()
        try call.media.message("response.created", response: "old-answer")
        try call.media.message("response.done", response: "old-answer")
        call.backend.reconnect = true
        let polls = call.backend.polls
        try await until { call.backend.polls >= polls + 2 }
        #expect(call.backend.prepares == 1)
        try call.media.message("input_audio_buffer.speech_started")
        try call.media.message("output_audio_buffer.stopped", response: "old-answer")
        call.backend.rawPollEvents = [.object(["sequence": .integer(1), "type": .text("answer"), "text": .text("late old answer")])]
        let following = call.backend.polls
        try await until { call.backend.polls >= following + 2 }
        #expect(call.backend.prepares == 1)
        try call.media.message("input_audio_buffer.speech_stopped")
        try call.media.message("response.created", response: "current-user-answer")
        try call.media.doneWithoutAudio("current-user-answer")
        try await until { call.backend.prepares == 2 && call.client.state.phase == .listening }
        await call.client.stop()
    }

    @Test func nativeReconnectWaitsForAcknowledgedDeliveryAndItsResponse() async throws {
        let replay = VoiceReplay()
        let call = replay.call()
        await call.client.start()
        call.backend.rawPollEvents = [.object(["sequence": .integer(1), "type": .text("speech-ready"), "deliveryId": .text("pending-delivery"), "generation": .integer(0)])]
        call.backend.reconnect = true
        try await until { call.backend.speechAcks.count == 1 }
        #expect(call.backend.prepares == 1)
        // A delayed stop for another response cannot retire this delivery.
        try call.media.message("output_audio_buffer.stopped", response: "older-answer")
        let polls = call.backend.polls
        try await until { call.backend.polls >= polls + 2 }
        #expect(call.backend.prepares == 1 && call.backend.speechAcks.count == 1)
        try call.media.message("response.created", response: "queued-answer")
        try call.media.message("response.done", response: "queued-answer")
        #expect(call.backend.prepares == 1)
        try call.media.message("output_audio_buffer.started", response: "queued-answer")
        try call.media.message("output_audio_buffer.stopped", response: "queued-answer")
        try await until { call.backend.prepares == 2 && call.client.state.phase == .listening }
        await call.client.stop()
    }

    @Test func lateSpeechEventCannotResurrectDrainedDelivery() async throws {
        let replay = VoiceReplay()
        let call = replay.call()
        await call.client.start()
        call.backend.rawPollEvents = [.object(["sequence": .integer(1), "type": .text("speech-ready"), "deliveryId": .text("drained-delivery"), "generation": .integer(0)])]
        try await until { call.backend.speechAcks.count == 1 }
        try call.media.message("response.created", response: "short-answer")
        try call.media.message("response.done", response: "short-answer")
        try call.media.message("output_audio_buffer.stopped", response: "short-answer")
        // The sideband confirmation can arrive after the ordered media drain.
        call.backend.rawPollEvents.append(.object(["sequence": .integer(2), "type": .text("speech"), "deliveryId": .text("drained-delivery"), "generation": .integer(0)]))
        call.backend.reconnect = true
        try await until { call.backend.prepares == 2 && call.client.state.phase == .listening }
        #expect(call.backend.speechAcks.count == 1)
        await call.client.stop()
    }

    @Test func directRealtimeAnswerWithoutHandoffReleasesIdleReconnect() async throws {
        let replay = VoiceReplay()
        let call = replay.call()
        await call.client.start()
        try call.media.message("input_audio_buffer.speech_started")
        try call.media.message("input_audio_buffer.speech_stopped")
        call.backend.reconnect = true
        let polls = call.backend.polls
        try await until { call.backend.polls >= polls + 2 }
        #expect(call.backend.prepares == 1)
        try call.media.message("response.created", response: "direct-greeting")
        try call.media.doneWithoutAudio("direct-greeting")
        try await until { call.backend.prepares == 2 && call.client.state.phase == .listening }
        await call.client.stop()
    }

    @Test func retiredNativePeerReconnectDoesNotWaitForSpeechStopped() async throws {
        let replay = VoiceReplay()
        let call = replay.call()
        await call.client.start()
        try call.media.message("input_audio_buffer.speech_started")
        call.backend.reconnect = true
        call.backend.reconnectRetired = true
        try await until { call.backend.prepares == 2 && call.client.state.phase == .listening }
        await call.client.stop()
    }

    @Test func supersededSpeechReadinessCannotBlockNewInput() async throws {
        let replay = VoiceReplay()
        let call = replay.call()
        await call.client.start()
        call.backend.rawPollEvents = [
            .object(["sequence": .integer(1), "type": .text("input"), "generation": .integer(2)]),
            .object(["sequence": .integer(2), "type": .text("speech-ready"), "deliveryId": .text("stale-delivery"), "generation": .integer(1)])
        ]
        call.backend.reconnect = true
        try await until { call.backend.prepares == 2 && call.client.state.phase == .listening }
        #expect(call.backend.speechAcks.isEmpty)
        await call.client.stop()
    }

    @Test func speechReadyBeforeConnectionWaitsThenAcknowledges() async throws {
        let replay = VoiceReplay()
        let call = replay.call()
        let gate = VoiceGate()
        call.backend.startGate = gate
        let start = Task { await call.client.start() }
        try await until { call.backend.starts == 1 }
        call.backend.rawPollEvents = [.object(["sequence": .integer(1), "type": .text("speech-ready"), "deliveryId": .text("early-ready"), "generation": .integer(0)])]
        let polls = call.backend.polls
        try await until { call.backend.polls >= polls + 2 }
        #expect(call.backend.speechAcks.isEmpty)
        gate.open()
        await start.value
        try await until { call.backend.speechAcks.count == 1 }
        await call.client.stop()
    }

    @Test func silentToolHandoffDoesNotWaitForFinalAudioBeforeAcknowledgement() async throws {
        let replay = VoiceReplay()
        let call = replay.call()
        await call.client.start()
        try call.media.message("input_audio_buffer.speech_started")
        try call.media.message("response.created", response: "tool-handoff")
        try call.media.message("input_audio_buffer.speech_stopped")
        call.backend.rawPollEvents = [.object(["sequence": .integer(1), "type": .text("speech-ready"), "deliveryId": .text("final-delivery"), "generation": .integer(1)])]
        let polls = call.backend.polls
        try await until { call.backend.polls >= polls + 2 }
        #expect(call.backend.speechAcks.isEmpty)
        try call.media.doneWithToolHandoff("tool-handoff")
        try await until { call.backend.speechAcks.count == 1 }
        try call.media.message("response.created", response: "final-audio")
        try call.media.message("response.done", response: "final-audio")
        try call.media.message("output_audio_buffer.stopped", response: "final-audio")
        call.backend.reconnect = true
        try await until { call.backend.prepares == 2 && call.client.state.phase == .listening }
        await call.client.stop()
    }

    @Test func explicitStopFencesPendingNativeSettingsReconnect() async throws {
        let replay = VoiceReplay()
        let call = replay.call()
        await call.client.start()
        let previous = call.backend.ownershipID
        let gate = VoiceGate()
        call.backend.prepareGate = gate
        call.backend.reconnect = true
        try await until { call.backend.prepares == 2 }
        let replacementOwner = call.backend.ownershipID, replacementSession = call.backend.sessionID
        let stopping = try #require(call.client.beginStop())
        try await until { call.backend.stops.count == 1 }
        #expect(call.backend.stops == [replacementOwner])
        #expect(call.backend.stopRequests[0]["ownershipId"] == .string(replacementOwner))
        #expect(call.client.state.phase == .stopping && call.client.hasPendingStop)
        await call.client.start()
        #expect(call.backend.prepares == 2 && call.backend.starts == 1)
        gate.open()
        await stopping.value
        #expect(call.backend.stops == [replacementOwner, replacementSession, previous])
        #expect(call.backend.stopRequests.map { $0["ownershipId"] } == [
            .string(replacementOwner), .string(replacementOwner), .string(previous)
        ])
        #expect(call.backend.prepares == 2 && call.backend.starts == 1)
        #expect(call.backend.stops.contains(previous))
        #expect(call.client.state.phase == .closed && !call.client.hasPendingStop)
    }

    @Test func failedNativeSettingsReconnectDoesNotRetry() async throws {
        let replay = VoiceReplay()
        let call = replay.call()
        await call.client.start()
        call.backend.failure = "prepare"
        call.backend.reconnect = true
        try await until { call.client.state.phase == .failed }
        #expect(call.backend.prepares == 2 && call.backend.starts == 1)
        #expect(!call.client.state.error.codeUnits.isEmpty)
        await call.client.stop()
    }

    @Test func retiredPreparationCannotReplaceCurrentTakeoverIdentity() async throws {
        let oldOwner = JSONText(UUID().uuidString), newOwner = JSONText(UUID().uuidString)
        let oldResponse = try NativeVoiceResult(.object(["occupiedOwner": .object([
            "deviceId": .text("old device"), "ownershipId": .string(oldOwner)])]))
        let currentResponse = try NativeVoiceResult(.object(["occupiedOwner": .object([
            "deviceId": .text("current device"), "ownershipId": .string(newOwner)])]))
        var pending: CheckedContinuation<NativeVoiceResult, Never>?
        defer { pending?.resume(returning: oldResponse); pending = nil }
        var prepares = 0
        var firstOwnership: JSONValue?
        var stopRequests: [JSONValue] = []
        var takeover: JSONValue?
        let client = NativeVoiceMediaClient(role: .moku, ownership: NativeVoiceMediaOwnership(),
            requestMicrophone: { Issue.record("Occupied media must not request the microphone") },
            makeMedia: { Issue.record("Occupied media must not allocate media"); return ReplayMedia() },
            command: { request in
                if request["action"] == .text("prepare") {
                    prepares += 1
                    if prepares == 1 {
                        firstOwnership = request["requestId"]
                        return await withCheckedContinuation { pending = $0 }
                    }
                    takeover = request["takeover"]
                    return currentResponse
                }
                if request["action"] == .text("stop") { stopRequests.append(request) }
                return try NativeVoiceResult(.object([:]))
            })
        client.setOwner("moku", available: true)
        let first = Task { await client.start() }
        try await until { pending != nil }
        let retiredOwnership = try #require(firstOwnership)
        let stopping = try #require(client.beginStop())
        try await until { stopRequests.count == 1 }
        #expect(stopRequests[0]["sessionId"] == retiredOwnership && stopRequests[0]["ownershipId"] == retiredOwnership)
        #expect(client.state.phase == .stopping && client.hasPendingStop)
        await client.start()
        #expect(prepares == 1 && client.state.occupiedOwner == nil)
        pending?.resume(returning: oldResponse); pending = nil
        await first.value
        await stopping.value
        #expect(stopRequests.count == 2 && stopRequests.allSatisfy {
            $0["sessionId"] == retiredOwnership && $0["ownershipId"] == retiredOwnership
        })
        #expect(client.state.phase == .closed && !client.hasPendingStop && client.state.occupiedOwner == nil)
        await client.start()
        await client.stop()
        #expect(client.state.occupiedOwner == "current device")
        await client.takeOver()
        await client.stop()
        #expect(prepares == 3 && takeover == .string(newOwner))
    }

    @Test func muteChangesOnlyInputAvailabilityOfTheCurrentMokuCall() async {
        let replay = VoiceReplay()
        let moku = replay.call()
        await moku.client.start()
        let session = moku.backend.sessionID
        #expect(moku.media.device.inputRunning && moku.media.device.outputRunning)
        moku.client.toggleMute()
        #expect(moku.client.state.muted)
        #expect(!moku.media.device.inputRunning && moku.media.device.outputRunning)
        moku.client.toggleMute()
        #expect(!moku.client.state.muted)
        #expect(moku.media.device.inputRunning && moku.media.device.outputRunning)
        #expect(moku.backend.sessionID == session && moku.backend.prepares == 1 && moku.backend.starts == 1)
        #expect(moku.backend.stops.isEmpty)
        await moku.client.stop()
    }

    @Test(arguments: ["before", "prepare", "permission", "offer", "start", "connect"])
    func failedMokuStartClosesItsMediaWithoutRetrying(stage: String) async {
        let replay = VoiceReplay()
        let moku = replay.call(failure: stage)
        await moku.client.start()
        await moku.client.stop() // Wait for failed-attempt backend cleanup.
        #expect(moku.client.state.phase == .failed && !moku.client.hasPendingStop)
        #expect(!moku.media.device.inputRunning && !moku.media.device.outputRunning)
        #expect(moku.backend.prepares == (stage == "before" ? 0 : 1))
        #expect(moku.backend.starts == (["start", "connect"].contains(stage) ? 1 : 0))
        #expect(moku.media.offers == (["offer", "start", "connect"].contains(stage) ? 1 : 0))
        if moku.media.offers > 0 { #expect(moku.media.closed) }
    }

    @Test(arguments: [false, true])
    func endedOrDisconnectedMokuIsNeverReopened(disconnect: Bool) async {
        let replay = VoiceReplay()
        let moku = replay.call()
        await moku.client.start()
        #expect(moku.client.state.phase == .listening)
        let originalSession = moku.backend.sessionID, originalOwner = moku.backend.ownershipID
        if disconnect { moku.client.setOwner("moku", available: false) }
        else { _ = moku.client.beginStop() }
        await moku.client.stop()
        #expect(moku.media.closed)
        #expect(!moku.media.device.inputRunning && !moku.media.device.outputRunning)
        #expect(moku.backend.prepares == 1 && moku.backend.starts == 1)
        #expect(moku.backend.stops == [originalSession, originalSession])
        #expect(moku.backend.stopRequests.map { $0["ownershipId"] } == [.string(originalOwner), .string(originalOwner)])
    }

    @Test func cancelledPrepareReturnsLateSessionOnlyToCleanupAndCannotTouchNewAttempt() async throws {
        let replay = VoiceReplay()
        let moku = replay.call()
        let prepare = VoiceGate()
        moku.backend.prepareGate = prepare
        let old = Task { await moku.client.start() }
        try await until { prepare.waiting }
        let retiredSession = moku.backend.sessionID, retiredOwner = moku.backend.ownershipID
        old.cancel()
        let stopping = try #require(moku.client.beginStop())
        await moku.client.start()
        #expect(moku.backend.prepares == 1 && moku.media.offers == 0 && moku.client.state.phase == .stopping)
        try await until { moku.backend.stops.count == 1 }
        #expect(moku.backend.stops == [retiredOwner])
        #expect(moku.backend.stopRequests[0]["ownershipId"] == .string(retiredOwner))
        prepare.open()
        await old.value
        await stopping.value
        #expect(moku.backend.stops == [retiredOwner, retiredSession])
        #expect(moku.backend.stopRequests.map { $0["ownershipId"] } == [.string(retiredOwner), .string(retiredOwner)])
        #expect(moku.client.state.phase == .closed && moku.permissionRequests == 0 && moku.media.offers == 0)
        moku.backend.prepareGate = nil
        await moku.client.start()
        let fresh = moku.backend.sessionID
        #expect(moku.client.state.phase == .listening)
        #expect(moku.backend.stops.allSatisfy { $0 != fresh })
        #expect(moku.backend.prepares == 2)
        #expect(moku.media.device.inputRunning && moku.media.device.outputRunning)
        await moku.client.stop()
    }

    @Test func synchronouslyClosedMokuCannotPrepareOrAcquireMedia() async {
        let replay = VoiceReplay()
        let moku = replay.call()
        moku.client.onStateChange = {
            if moku.client.state.phase == .preparing {
                moku.client.onStateChange = nil
                _ = moku.client.beginStop()
            }
        }
        await moku.client.start()
        await moku.client.stop()
        #expect(moku.client.state.phase == .closed && !moku.client.hasPendingStop)
        #expect(!moku.media.device.inputRunning && !moku.media.device.outputRunning)
        #expect(moku.backend.prepares == 0 && moku.permissionRequests == 0 && moku.media.offers == 0)
    }

    @Test func cancellationDuringPermissionCannotAcquireMokuMedia() async throws {
        let replay = VoiceReplay()
        let moku = replay.call()
        let permission = VoiceGate()
        moku.permissionGate = permission
        let starting = Task { await moku.client.start() }
        try await until { permission.waiting }
        starting.cancel()
        permission.open()
        await starting.value
        await moku.client.stop()
        #expect(!moku.media.device.inputRunning && !moku.media.device.outputRunning)
        #expect(moku.backend.prepares == 1 && moku.backend.starts == 0)
        #expect(moku.permissionRequests == 1 && moku.media.offers == 0)
        #expect(moku.backend.stops == [moku.backend.sessionID, moku.backend.sessionID])
        #expect(moku.backend.stopRequests.allSatisfy { $0["ownershipId"] == .string(moku.backend.ownershipID) })
        #expect(!moku.client.hasPendingStop)
    }

    @Test func lateStartAnswerAndPollCannotAffectReplacementAttempt() async throws {
        let replay = VoiceReplay()
        let moku = replay.call()
        let start = VoiceGate(), poll = VoiceGate()
        moku.backend.startGate = start
        moku.backend.pollGate = poll
        let old = Task { await moku.client.start() }
        try await until { start.waiting && poll.waiting }
        let oldFailure = moku.media.onFailure
        let oldMessage = moku.media.onMessage
        let oldAnalysis = moku.media.onInputAnalysis
        await moku.client.stop()
        moku.backend.startGate = nil; moku.backend.pollGate = nil
        moku.backend.pollEvents = []
        await moku.client.start()
        let fresh = moku.backend.sessionID
        moku.backend.delayedPollEvents = [try NativeVoiceEvent(.object(["sequence": .integer(1), "type": .text("closed")]))]
        // Keep the retired attempt alive in its suspended start/poll, so this
        // exercises identity fencing rather than only weak-reference expiry.
        oldFailure?("late failure")
        oldMessage?(try JSONValue.object(["type": .text("response.created"), "response": .object(["id": .text("old")])]).encodedData())
        oldAnalysis?(.init(level: 0.9, capturedAt: 1))
        #expect(moku.client.inputLevel == 0 && moku.media.messages.isEmpty)
        start.open(); poll.open()
        await old.value
        for _ in 0..<10 { await Task.yield() }
        #expect(moku.client.state.phase == .listening)
        #expect(moku.media.device.inputRunning && moku.media.device.outputRunning)
        #expect(moku.backend.prepares == 2 && moku.backend.starts == 2)
        #expect(moku.backend.stops.allSatisfy { $0 != fresh })
        moku.backend.pollEvents = []
        await moku.client.stop()
    }

    @Test func mokuTransportFailureOrClosedEventClosesMediaWithoutRestarting() async throws {
        for serverClosed in [false, true] {
            let replay = VoiceReplay()
            let moku = replay.call()
            await moku.client.start()
            #expect(moku.client.state.phase == .listening)
            if serverClosed {
                moku.backend.pollEvents = [try NativeVoiceEvent(.object(["sequence": .integer(1), "type": .text("closed")]))]
                try await until { moku.media.closed }
            } else { moku.media.onFailure?("connection lost") }
            await moku.client.stop()
            #expect(moku.media.closed && !moku.media.device.inputRunning && !moku.media.device.outputRunning)
            #expect(moku.backend.prepares == 1 && moku.backend.starts == 1)
        }
    }

    @Test func muteAudioGateFailureClosesMokuMedia() async {
        let replay = VoiceReplay()
        let moku = replay.call()
        await moku.client.start()
        #expect(moku.client.state.phase == .listening && moku.media.device.inputRunning)
        moku.media.device.rejectChange = true
        moku.client.toggleMute()
        #expect(moku.media.closed) // A failed mute must not leave capture running.
        #expect(!moku.media.device.inputRunning && !moku.media.device.outputRunning)
        await moku.client.stop()
        #expect(moku.client.state.phase == .failed && !moku.client.hasPendingStop)
        #expect(moku.backend.prepares == 1 && moku.backend.starts == 1)
    }

    @Test func leavingOverviewDuringPermissionRetiresMokuWithoutReopeningOnReturn() async throws {
        let replay = VoiceReplay()
        let moku = replay.call()
        let owner = UUID()
        moku.client.setOverviewVoiceRoute(owner: owner, active: true, allowed: true)
        let permission = VoiceGate()
        moku.permissionGate = permission
        let pending = Task { await moku.client.start() }
        try await until { permission.waiting }
        moku.client.setOverviewVoiceRoute(owner: owner, active: true, allowed: false)
        #expect(moku.client.state.phase == .stopping && moku.client.hasPendingStop)
        #expect(!moku.media.device.inputRunning && !moku.media.device.outputRunning)
        permission.open()
        await pending.value
        await moku.client.stop()
        await moku.client.start()
        #expect(moku.backend.prepares == 1 && moku.permissionRequests == 1 && moku.media.offers == 0)
        #expect(moku.backend.stops == [moku.backend.sessionID, moku.backend.sessionID])
        moku.client.setOverviewVoiceRoute(owner: owner, active: true, allowed: true)
        #expect(moku.client.state.phase == .closed && !moku.client.hasPendingStop)
        #expect(moku.backend.prepares == 1 && moku.backend.starts == 0 && moku.media.offers == 0)
    }

    @Test func audioAvailabilityGateRejectsErrorsAndUnexpectedRunningHardware() throws {
        let device = ReplayAudioDevice()
        try NativeVoiceAudioAccess(enabled: true, muted: false).apply(to: device)
        #expect(device.inputRunning && device.outputRunning)
        try NativeVoiceAudioAccess(enabled: true, muted: true).apply(to: device)
        #expect(!device.inputRunning && device.outputRunning)
        try NativeVoiceAudioAccess(enabled: false, muted: false).apply(to: device)
        #expect(!device.inputRunning && !device.outputRunning)
        device.ignoreChange = true; device.inputRunning = true
        #expect(throws: NativeVoiceError.self) { try NativeVoiceAudioAccess(enabled: false, muted: false).apply(to: device) }
        device.ignoreChange = false; device.rejectChange = true
        #expect(throws: NativeVoiceError.self) { try NativeVoiceAudioAccess(enabled: false, muted: false).apply(to: device) }
    }
}

@MainActor
private func until(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw NativeVoiceError("Replay timed out") }
        try await Task.sleep(for: .milliseconds(1))
    }
}

@MainActor
private final class VoiceGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { let old = continuation; continuation = nil; old?.resume() }
}

@MainActor
private final class VoiceReplay {
    let ownership = NativeVoiceMediaOwnership()
    func call(failure: String = "") -> ReplayCall {
        ReplayCall(ownership: ownership, failure: failure)
    }
}

@MainActor
private final class ReplayCall {
    let media = ReplayMedia()
    let backend = ReplayVoiceBackend()
    var permissionGate: VoiceGate?
    var permissionRequests = 0
    var client: NativeVoiceMediaClient!
    init(ownership: NativeVoiceMediaOwnership, failure: String) {
        media.failure = failure; backend.failure = failure
        client = NativeVoiceMediaClient(role: .moku, ownership: ownership,
            requestMicrophone: { [unowned self] in
                permissionRequests += 1
                if let permissionGate { await permissionGate.wait() }
                if failure == "permission" { throw NativeVoiceError("permission denied") }
            }, makeMedia: { [media] in media },
            beforeStart: { if failure == "before" { throw NativeVoiceError("not ready") } },
            command: { [backend] in try await backend.command($0) })
        client.setOwner("moku", available: true)
    }
}

@MainActor
private final class ReplayVoiceBackend {
    var sessionID: JSONText = JSONText(UUID().uuidString)
    var prepares = 0, starts = 0, polls = 0
    var reconnect = false
    var reconnectRetired = false
    var speechAcks: [JSONValue] = []
    var reconnectFrom: JSONValue?
    var ownershipID: JSONText = ""
    var stopRequests: [JSONValue] = []
    var stops: [JSONText] { stopRequests.compactMap { $0["sessionId"]?.voiceText } }
    var failure = ""
    var prepareGate: VoiceGate?, startGate: VoiceGate?, pollGate: VoiceGate?
    var pollEvents: [NativeVoiceEvent] = []
    var delayedPollEvents: [NativeVoiceEvent] = []
    var rawPollEvents: [JSONValue] = []
    func command(_ request: JSONValue) async throws -> NativeVoiceResult {
        switch request["action"]?.stringValue {
        case "prepare":
            prepares += 1
            ownershipID = request["requestId"]!.voiceText!
            reconnectFrom = request["reconnectFrom"]
            if reconnectFrom != nil { reconnect = false; reconnectRetired = false; rawPollEvents = [] }
            let id = JSONText(UUID().uuidString); sessionID = id
            if let prepareGate { await prepareGate.wait() }
            if failure == "prepare" { throw NativeVoiceError("prepare failed") }
            var result: [JSONText: JSONValue] = ["sessionId": .string(id), "ownershipId": request["requestId"]!]
            if let revision = request["sourceRevision"] {
                result["superThreadId"] = try #require(request["superThreadId"])
                result["sourceRevision"] = revision
            }
            return try NativeVoiceResult(.object(result))
        case "start":
            starts += 1
            if let startGate { await startGate.wait() }
            if failure == "start" { throw NativeVoiceError("start failed") }
            return try NativeVoiceResult(.object(["sdp": .text("fixture answer")]))
        case "poll":
            polls += 1
            let response: [NativeVoiceEvent]
            if let pollGate {
                await pollGate.wait()
                response = delayedPollEvents
            } else { response = pollEvents }
            let events = response.map { event in JSONValue.object(["sequence": .integer(event.sequence), "type": .text(event.type)]) }
            return try NativeVoiceResult(.object(["events": .array(events + rawPollEvents), "reconnect": .bool(reconnect), "reconnectRetired": .bool(reconnectRetired)]))
        case "ack-speech": speechAcks.append(request)
        case "stop":
            stopRequests.append(request)
        default: Issue.record("Unexpected command")
        }
        return try NativeVoiceResult(.object([:]))
    }
}

@MainActor
private final class ReplayAudioDevice: NativeVoiceAudioDevice {
    var inputRunning = false, outputRunning = false
    var rejectChange = false, ignoreChange = false
    func setAvailability(input: Bool, output: Bool) -> Int {
        if rejectChange { return -1 }
        if !ignoreChange { inputRunning = input; outputRunning = output }
        return 0
    }
    func close() { inputRunning = false; outputRunning = false }
}

@MainActor
private final class ReplayMedia: NativeVoiceMediaTransport {
    var onFailure: ((String) -> Void)?
    var onMessage: ((Data) -> Void)?
    var onInputAnalysis: ((NativeVoiceInputAnalysis) -> Void)?
    let device = ReplayAudioDevice()
    var failure = "", offers = 0
    var closed = false
    var channelOpen: Bool { !closed && offers > 0 }
    var messages: [JSONValue] = []
    func offer() async throws -> String {
        offers += 1; closed = false
        if failure == "offer" { throw NativeVoiceError("offer failed") }
        try NativeVoiceAudioAccess(enabled: true, muted: false).apply(to: device)
        return "fixture offer"
    }
    func connect(answer: String) async throws {
        if failure == "connect" { throw NativeVoiceError("connect failed") }
    }
    func send(_ data: Data) throws { messages.append(try JSONValue(data: data)) }
    func setAudioEnabled(_ enabled: Bool, muted: Bool) throws {
        try NativeVoiceAudioAccess(enabled: enabled, muted: muted).apply(to: device)
    }
    func setAnalysisEnabled(_ enabled: Bool) {}
    func close() { closed = true; device.close(); onFailure = nil; onMessage = nil; onInputAnalysis = nil }
    func doneWithToolHandoff(_ id: String) throws {
        onMessage?(try JSONValue.object(["type": .text("response.done"), "response": .object([
            "id": .text(id), "status": .text("completed"), "output": .array([.object(["type": .text("function_call"), "name": .text("handoff"), "arguments": .text("{}")])])
        ])]).encodedData())
    }
    func doneWithoutAudio(_ id: String) throws {
        onMessage?(try JSONValue.object(["type": .text("response.done"), "response": .object([
            "id": .text(id), "status": .text("completed"), "output": .array([.object(["type": .text("message"), "content": .array([.object(["type": .text("text"), "text": .text("hello")])])])])
        ])]).encodedData())
    }
    func message(_ type: String, response: String? = nil) throws {
        var event: [JSONText: JSONValue] = ["type": .text(type)]
        if let response {
            if type.hasPrefix("output_audio_buffer.") { event["response_id"] = .text(response) }
            else { event["response"] = .object(["id": .text(response)]) }
        }
        onMessage?(try JSONValue.object(event).encodedData())
    }
}
