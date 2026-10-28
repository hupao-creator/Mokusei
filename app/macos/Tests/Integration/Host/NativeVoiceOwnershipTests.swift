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
        let call = replay.call(.moku)
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
        let call = replay.call(.moku)
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
        let call = replay.call(.moku)
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
        let call = replay.call(.moku)
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
        let call = replay.call(.moku)
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
        let call = replay.call(.moku)
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
        let call = replay.call(.moku)
        await call.client.start()
        try call.media.message("input_audio_buffer.speech_started")
        call.backend.reconnect = true
        call.backend.reconnectRetired = true
        try await until { call.backend.prepares == 2 && call.client.state.phase == .listening }
        await call.client.stop()
    }

    @Test func supersededSpeechReadinessCannotBlockNewInput() async throws {
        let replay = VoiceReplay()
        let call = replay.call(.moku)
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
        let call = replay.call(.moku)
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

    @Test func speechReadyWhileSuspendedAcknowledgesAfterMediaReturns() async throws {
        let replay = VoiceReplay()
        let call = replay.call(.moku), thread = replay.call(.thread)
        await call.client.start()
        await thread.client.start()
        #expect(call.client.state.mediaSuspended)
        call.backend.rawPollEvents = [.object(["sequence": .integer(1), "type": .text("speech-ready"), "deliveryId": .text("suspended-ready"), "generation": .integer(0)])]
        let polls = call.backend.polls
        try await until { call.backend.polls >= polls + 2 }
        #expect(call.backend.speechAcks.isEmpty)
        await thread.client.stop()
        try await until { call.backend.speechAcks.count == 1 }
        await call.client.stop()
    }

    @Test func silentToolHandoffDoesNotWaitForFinalAudioBeforeAcknowledgement() async throws {
        let replay = VoiceReplay()
        let call = replay.call(.moku)
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
        let call = replay.call(.moku)
        await call.client.start()
        let previous = call.backend.ownershipID
        let gate = VoiceGate()
        call.backend.prepareGate = gate
        call.backend.reconnect = true
        try await until { call.backend.prepares == 2 }
        await call.client.stop()
        gate.open()
        try await until { call.backend.stops.count >= 3 }
        #expect(call.backend.prepares == 2 && call.backend.starts == 1)
        #expect(call.backend.stops.contains(previous))
        #expect(call.client.state.phase == .closed)
    }

    @Test func failedNativeSettingsReconnectDoesNotRetry() async throws {
        let replay = VoiceReplay()
        let call = replay.call(.moku)
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
        var takeover: JSONValue?
        let client = NativeVoiceMediaClient(role: .moku, ownership: NativeVoiceMediaOwnership(),
            requestMicrophone: { Issue.record("Occupied media must not request the microphone") },
            makeMedia: { Issue.record("Occupied media must not allocate media"); return ReplayMedia() },
            command: { request in
                if request["action"] == .text("prepare") {
                    prepares += 1
                    if prepares == 1 { return await withCheckedContinuation { pending = $0 } }
                    takeover = request["takeover"]
                    return currentResponse
                }
                return try NativeVoiceResult(.object([:]))
            })
        client.setOwner("moku", available: true)
        let first = Task { await client.start() }
        try await until { pending != nil }
        await client.stop()
        await client.start()
        await client.stop()
        #expect(client.state.occupiedOwner == "current device")
        pending?.resume(returning: oldResponse); pending = nil
        await first.value
        #expect(client.state.occupiedOwner == "current device")
        await client.takeOver()
        await client.stop()
        #expect(prepares == 3 && takeover == .string(newOwner))
    }

    @Test func suspendedMokuKeepsItsTranscriptAndMatchingFeedbackStillRetiresIt() async throws {
        let replay = VoiceReplay()
        let moku = replay.call(.moku), thread = replay.call(.thread)
        await moku.client.start()
        let session = moku.backend.sessionID
        moku.backend.rawPollEvents = [.object([
            "sequence": .integer(1), "type": .text("transcript"), "sessionId": .string(session),
            "itemId": .text("moku-input"), "role": .text("user"), "text": .text("Moku request"),
            "complete": .bool(true), "createdAt": .integer(1)
        ])]
        try await until { moku.client.inputTranscript.message != nil }
        let original = moku.client.inputTranscript.message
        await thread.client.start()
        #expect(moku.client.state.mediaSuspended && moku.client.inputTranscript.message == original)
        moku.backend.rawPollEvents.append(.object([
            "sequence": .integer(2), "type": .text("answer"), "sessionId": .string(session),
            "replyToItemId": .text("moku-input"), "text": .text("Corresponding Moku feedback")
        ]))
        try await until { moku.client.inputTranscript.message == nil }
        #expect(moku.client.state.mediaSuspended && !moku.media.closed)
        await thread.client.stop()
        #expect(!moku.client.state.mediaSuspended && moku.client.inputTranscript.message == nil)
        #expect(moku.backend.sessionID == session && moku.backend.prepares == 1 && moku.backend.starts == 1)
        #expect(replay.maximumOwners == 1)
        await moku.client.stop()
    }

    @Test func enteringThreadDoesNotInterruptMokuAndThreadExclusivelyOwnsAudioUntilClosed() async throws {
        let replay = VoiceReplay()
        let moku = replay.call(.moku)
        await moku.client.start()
        let original = moku.backend.sessionID
        let thread = replay.call(.thread) // Entering/configuring only.
        #expect(moku.client.state.phase == .listening)
        #expect(!moku.client.state.mediaSuspended)
        #expect(moku.backend.stops.isEmpty)
        await thread.client.start()
        #expect(moku.client.state.phase == .listening)
        #expect(moku.client.state.mediaSuspended)
        #expect(moku.backend.stops.isEmpty)
        #expect(moku.backend.sessionID == original)
        #expect(!moku.media.closed && moku.media.channelOpen)
        #expect(!moku.media.device.inputRunning && !moku.media.device.outputRunning)
        #expect(thread.media.device.inputRunning && thread.media.device.outputRunning)
        replay.audioFrame()
        #expect(moku.media.captured == 0 && moku.media.played == 0)
        #expect(thread.media.captured == 1 && thread.media.played == 1)

        // A backend response arriving while paused is fenced on Moku's channel,
        // never sent to the Thread; acknowledgments must not form a clear loop.
        try moku.media.message("response.created", response: "moku-response")
        #expect(moku.media.messages.contains { $0["response_id"]?.stringValue == "moku-response" })
        let sent = moku.media.messages.count
        try moku.media.message("output_audio_buffer.cleared")
        #expect(moku.media.messages.count == sent)
        #expect(thread.media.messages.isEmpty)
        #expect(moku.media.messages.contains { $0["type"]?.stringValue == "input_audio_buffer.clear" })
        #expect(moku.media.messages.contains { $0["type"]?.stringValue == "output_audio_buffer.clear" })

        // Polls/heartbeats continue while suspended, beyond an initial poll.
        let pollsBefore = max(1, moku.backend.polls)
        try await until { moku.backend.polls > pollsBefore }
        await thread.client.stop()
        #expect(!moku.client.state.mediaSuspended)
        #expect(moku.media.device.inputRunning && moku.media.device.outputRunning)
        #expect(thread.media.closed)
        #expect(moku.backend.prepares == 1 && moku.backend.starts == 1)
        #expect(moku.backend.stops.isEmpty)
        #expect(moku.backend.sessionID == original)
        replay.audioFrame()
        #expect(moku.media.captured == 1 && moku.media.played == 1)
        #expect(thread.media.captured == 1 && thread.media.played == 1)
        #expect(replay.maximumOwners == 1)
        await moku.client.stop()
    }

    @Test func restorationPreservesMuteAndMuteChangesCannotAcquireSuspendedAudio() async {
        let replay = VoiceReplay()
        let moku = replay.call(.moku), thread = replay.call(.thread)
        await moku.client.start()
        moku.client.toggleMute()
        #expect(!moku.media.device.inputRunning && moku.media.device.outputRunning)
        await thread.client.start()
        #expect(moku.client.state.muted)
        await thread.client.stop()
        #expect(moku.client.state.muted)
        #expect(!moku.media.device.inputRunning && moku.media.device.outputRunning)
        await thread.client.start()
        moku.client.toggleMute() // User changes preference while paused.
        #expect(!moku.client.state.muted)
        #expect(!moku.media.device.inputRunning && !moku.media.device.outputRunning)
        await thread.client.stop()
        #expect(moku.media.device.inputRunning && moku.media.device.outputRunning)
        #expect(replay.maximumOwners == 1)
        await moku.client.stop()
    }

    @Test(arguments: ["before", "prepare", "permission", "offer", "start", "connect"])
    func failedThreadStartRestoresOriginalMokuWithoutNewSession(stage: String) async {
        let replay = VoiceReplay()
        let moku = replay.call(.moku), thread = replay.call(.thread, failure: stage)
        await moku.client.start()
        await thread.client.start()
        await thread.client.stop() // Wait for failed-attempt backend cleanup.
        #expect(thread.client.state.phase == .failed)
        #expect(!moku.client.state.mediaSuspended)
        #expect(moku.media.device.inputRunning && moku.media.device.outputRunning)
        #expect(moku.backend.prepares == 1 && moku.backend.starts == 1 && moku.backend.stops.isEmpty)
        #expect(replay.maximumOwners == 1)
        await moku.client.stop()
    }

    @Test(arguments: [false, true])
    func endedOrDisconnectedMokuIsNeverReopened(disconnect: Bool) async {
        let replay = VoiceReplay()
        let moku = replay.call(.moku), thread = replay.call(.thread)
        await moku.client.start()
        await thread.client.start()
        if disconnect { moku.client.setOwner("moku", available: false) }
        else { _ = moku.client.beginStop() }
        await moku.client.stop()
        await thread.client.stop()
        #expect(moku.media.closed)
        #expect(!moku.media.device.inputRunning && !moku.media.device.outputRunning)
        #expect(moku.backend.prepares == 1 && moku.backend.starts == 1 && moku.backend.stops.count == 1)
    }

    @Test func rapidThreadSwitchWaitsForOldServerStopAndLateReplyCannotRestoreMoku() async throws {
        let replay = VoiceReplay()
        let moku = replay.call(.moku), first = replay.call(.thread), second = replay.call(.thread)
        await moku.client.start()
        await first.client.start()
        let staleFailure = first.media.onFailure
        let staleMessage = first.media.onMessage
        let stop = VoiceGate()
        first.backend.stopGate = stop
        let switching = Task { await second.client.start() }
        try await until { stop.waiting }
        #expect(first.media.closed)
        #expect(moku.client.state.mediaSuspended)
        #expect(!moku.media.device.inputRunning && !second.media.device.inputRunning)
        stop.open()
        await switching.value
        #expect(second.client.state.phase == .listening)
        staleFailure?("late disconnect")
        staleMessage?(try JSONValue.object(["type": .text("response.created"), "response": .object(["id": .text("old")])]).encodedData())
        #expect(moku.client.state.mediaSuspended)
        #expect(second.media.device.inputRunning && second.media.device.outputRunning)
        #expect(second.media.messages.isEmpty)
        replay.ownership.release(second.client, requestID: JSONText(UUID().uuidString))
        #expect(moku.client.state.mediaSuspended) // A stale lease cannot restore.
        // The same synchronous revocation is used by collapse/switch/release.
        _ = second.client.beginStop()
        #expect(!moku.client.state.mediaSuspended)
        #expect(!second.media.device.inputRunning && moku.media.device.inputRunning)
        await second.client.stop()
        #expect(replay.maximumOwners == 1)
        await moku.client.stop()
    }

    @Test func cancelledPrepareReturnsLateSessionOnlyToCleanupAndCannotTouchNewAttempt() async throws {
        let replay = VoiceReplay()
        let moku = replay.call(.moku), thread = replay.call(.thread)
        await moku.client.start()
        let prepare = VoiceGate()
        thread.backend.prepareGate = prepare
        let old = Task { await thread.client.start() }
        try await until { prepare.waiting }
        old.cancel()
        await thread.client.stop()
        #expect(!moku.client.state.mediaSuspended)
        thread.backend.prepareGate = nil
        await thread.client.start()
        let fresh = thread.backend.sessionID
        #expect(moku.client.state.mediaSuspended)
        prepare.open()
        await old.value
        #expect(thread.client.state.phase == .listening)
        #expect(thread.backend.stops.allSatisfy { $0 != fresh })
        #expect(thread.backend.prepares == 2)
        #expect(moku.client.state.mediaSuspended)
        #expect(replay.maximumOwners == 1)
        await thread.client.stop()
        await moku.client.stop()
    }

    @Test func cancelledMiddleClaimCannotBypassTeardownOfAlreadyCollapsedThread() async throws {
        let replay = VoiceReplay()
        let moku = replay.call(.moku), first = replay.call(.thread), second = replay.call(.thread)
        await moku.client.start()
        await first.client.start()
        let stop = VoiceGate()
        first.backend.stopGate = stop
        _ = first.client.beginStop() // UI collapse/release happens before start.
        #expect(!moku.client.state.mediaSuspended && moku.media.device.inputRunning)
        try await until { stop.waiting }
        let next = Task { await second.client.start() }
        try await until { moku.client.state.mediaSuspended }
        #expect(second.backend.prepares == 0 && second.media.offers == 0)
        next.cancel()
        await second.client.stop()
        #expect(!moku.client.state.mediaSuspended)
        let third = replay.call(.thread)
        let final = Task { await third.client.start() }
        try await until { moku.client.state.mediaSuspended }
        #expect(third.backend.prepares == 0 && third.media.offers == 0)
        stop.open()
        await next.value
        await final.value
        #expect(third.client.state.phase == .listening)
        #expect(moku.client.state.mediaSuspended)
        #expect(replay.maximumOwners == 1)
        await third.client.stop()
        await moku.client.stop()
    }

    @Test func retiredClaimCannotSuspendMokuAfterSynchronousClose() async {
        let replay = VoiceReplay()
        let moku = replay.call(.moku), thread = replay.call(.thread)
        await moku.client.start()
        thread.client.onStateChange = {
            if thread.client.state.phase == .preparing {
                thread.client.onStateChange = nil
                _ = thread.client.beginStop()
            }
        }
        await thread.client.start()
        await thread.client.stop()
        #expect(!moku.client.state.mediaSuspended)
        #expect(moku.media.device.inputRunning && moku.media.device.outputRunning)
        #expect(moku.backend.stops.isEmpty)
        #expect(thread.backend.prepares == 0 && thread.media.offers == 0)
        await moku.client.stop()
    }

    @Test func cancellationDuringPermissionRestoresMokuFromCancelledTask() async throws {
        let replay = VoiceReplay()
        let moku = replay.call(.moku), thread = replay.call(.thread)
        await moku.client.start()
        let permission = VoiceGate()
        thread.permissionGate = permission
        let starting = Task { await thread.client.start() }
        try await until { permission.waiting }
        starting.cancel()
        permission.open()
        await starting.value
        await thread.client.stop()
        #expect(!moku.client.state.mediaSuspended)
        #expect(moku.media.device.inputRunning && moku.media.device.outputRunning)
        #expect(moku.backend.prepares == 1 && moku.backend.stops.isEmpty)
        #expect(thread.media.offers == 0)
        await moku.client.stop()
    }

    @Test func lateStartAnswerAndPollCannotAffectReplacementAttempt() async throws {
        let replay = VoiceReplay()
        let moku = replay.call(.moku), thread = replay.call(.thread)
        await moku.client.start()
        let start = VoiceGate(), poll = VoiceGate()
        thread.backend.startGate = start
        thread.backend.pollGate = poll
        let old = Task { await thread.client.start() }
        try await until { start.waiting && poll.waiting }
        let oldFailure = thread.media.onFailure
        let oldAnalysis = thread.media.onInputAnalysis
        await thread.client.stop()
        #expect(!moku.client.state.mediaSuspended)
        thread.backend.startGate = nil; thread.backend.pollGate = nil
        thread.backend.pollEvents = []
        await thread.client.start()
        thread.backend.delayedPollEvents = [try NativeVoiceEvent(.object(["sequence": .integer(1), "type": .text("closed")]))]
        // Keep the retired attempt alive in its suspended start/poll, so this
        // exercises identity fencing rather than only weak-reference expiry.
        oldFailure?("late failure")
        oldAnalysis?(.init(level: 0.9, capturedAt: 1))
        #expect(thread.client.inputLevel == 0)
        start.open(); poll.open()
        await old.value
        for _ in 0..<10 { await Task.yield() }
        #expect(thread.client.state.phase == .listening)
        #expect(moku.client.state.mediaSuspended)
        #expect(replay.maximumOwners == 1)
        thread.backend.pollEvents = []
        await thread.client.stop()
        await moku.client.stop()
    }

    @Test func pausedMokuTransportFailureOrClosedEventCancelsRestore() async throws {
        for serverClosed in [false, true] {
            let replay = VoiceReplay()
            let moku = replay.call(.moku), thread = replay.call(.thread)
            await moku.client.start()
            await thread.client.start()
            if serverClosed {
                moku.backend.pollEvents = [try NativeVoiceEvent(.object(["sequence": .integer(1), "type": .text("closed")]))]
                try await until { moku.media.closed }
            } else { moku.media.onFailure?("connection lost while suspended") }
            await moku.client.stop()
            await thread.client.stop()
            #expect(moku.media.closed && !moku.media.device.inputRunning && !moku.media.device.outputRunning)
            #expect(moku.backend.prepares == 1 && moku.backend.starts == 1)
        }
    }

    @Test func threadClosedEventRestoresMokuAndAudioGateFailureFailsClosed() async throws {
        let replay = VoiceReplay()
        let moku = replay.call(.moku), thread = replay.call(.thread)
        await moku.client.start()
        await thread.client.start()
        thread.backend.pollEvents = [try NativeVoiceEvent(.object(["sequence": .integer(1), "type": .text("closed")]))]
        try await until { thread.media.closed }
        #expect(!moku.client.state.mediaSuspended && moku.media.device.inputRunning)
        await thread.client.stop()
        moku.media.device.rejectChange = true
        let next = replay.call(.thread)
        await next.client.start()
        #expect(moku.media.closed) // Failed suspension cannot leave hidden capture.
        #expect(next.media.device.inputRunning)
        await next.client.stop()
        await moku.client.stop()
        #expect(moku.backend.prepares == 1)
        #expect(replay.maximumOwners == 1)
    }

    @Test func failedResumeDoesNotRecreateSessionAndPreparingMokuIsRetiredBeforeThreadCapture() async throws {
        let replay = VoiceReplay()
        let moku = replay.call(.moku), thread = replay.call(.thread)
        await moku.client.start()
        await thread.client.start()
        moku.media.device.rejectChange = true
        await thread.client.stop()
        await moku.client.stop()
        #expect(moku.media.closed && moku.backend.prepares == 1)
        let pendingMoku = replay.call(.moku), next = replay.call(.thread)
        let permission = VoiceGate()
        pendingMoku.permissionGate = permission
        let pending = Task { await pendingMoku.client.start() }
        try await until { permission.waiting }
        await next.client.start()
        permission.open()
        await pending.value
        #expect(pendingMoku.media.offers == 0)
        #expect(next.media.device.inputRunning)
        #expect(replay.maximumOwners == 1)
        await next.client.stop()
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
    var calls: [ReplayCall] = []
    var maximumOwners = 0
    func call(_ role: NativeVoiceMediaOwnership.Role, failure: String = "") -> ReplayCall {
        let call = ReplayCall(role: role, ownership: ownership, failure: failure)
        call.media.device.changed = { [weak self] in self?.checkExclusive() }
        calls.append(call)
        return call
    }
    func checkExclusive() {
        let capturing = calls.filter { $0.media.device.inputRunning }.count
        let playing = calls.filter { $0.media.device.outputRunning }.count
        maximumOwners = max(maximumOwners, capturing, playing)
        #expect(capturing <= 1 && playing <= 1)
        if calls.contains(where: { $0.role == .thread && ($0.media.device.inputRunning || $0.media.device.outputRunning) }) {
            #expect(calls.filter { $0.role == .moku }.allSatisfy { !$0.media.device.inputRunning && !$0.media.device.outputRunning })
        }
    }
    func audioFrame() {
        for call in calls {
            if call.media.device.inputRunning { call.media.captured += 1 }
            if call.media.device.outputRunning { call.media.played += 1 }
        }
    }
}

@MainActor
private final class ReplayCall {
    let role: NativeVoiceMediaOwnership.Role
    let media = ReplayMedia()
    let backend = ReplayVoiceBackend()
    var permissionGate: VoiceGate?
    var permissionRequests = 0
    var client: NativeVoiceMediaClient!
    init(role: NativeVoiceMediaOwnership.Role, ownership: NativeVoiceMediaOwnership, failure: String) {
        self.role = role
        media.failure = failure; backend.failure = failure
        client = NativeVoiceMediaClient(role: role, ownership: ownership,
            requestMicrophone: { [unowned self] in
                permissionRequests += 1
                if let permissionGate { await permissionGate.wait() }
                if failure == "permission" { throw NativeVoiceError("permission denied") }
            }, makeMedia: { [media] in media },
            beforeStart: { if failure == "before" { throw NativeVoiceError("not ready") } },
            command: { [backend] in try await backend.command($0) })
        client.setOwner(role == .moku ? "moku" : JSONText(UUID().uuidString), available: true)
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
    var stops: [JSONText] = []
    var failure = ""
    var prepareGate: VoiceGate?, startGate: VoiceGate?, stopGate: VoiceGate?, pollGate: VoiceGate?
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
            return try NativeVoiceResult(.object(["sessionId": .string(id), "ownershipId": request["requestId"]!]))
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
            stops.append(request["sessionId"]!.voiceText!)
            if let stopGate { await stopGate.wait() }
        default: Issue.record("Unexpected command")
        }
        return try NativeVoiceResult(.object([:]))
    }
}

@MainActor
private final class ReplayAudioDevice: NativeVoiceAudioDevice {
    var inputRunning = false, outputRunning = false
    var rejectChange = false, ignoreChange = false
    var changed: (() -> Void)?
    func setAvailability(input: Bool, output: Bool) -> Int {
        if rejectChange { return -1 }
        if !ignoreChange { inputRunning = input; outputRunning = output }
        changed?()
        return 0
    }
    func close() { inputRunning = false; outputRunning = false; changed?() }
}

@MainActor
private final class ReplayMedia: NativeVoiceMediaTransport {
    var onFailure: ((String) -> Void)?
    var onMessage: ((Data) -> Void)?
    var onInputAnalysis: ((NativeVoiceInputAnalysis) -> Void)?
    let device = ReplayAudioDevice()
    var failure = "", offers = 0, captured = 0, played = 0
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
