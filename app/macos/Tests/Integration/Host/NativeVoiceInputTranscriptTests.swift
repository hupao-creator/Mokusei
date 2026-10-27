import Foundation
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
@testable import MokuseiVoice

@MainActor @Suite(.serializedNative, .serialized) struct NativeVoiceInputTranscriptTests {
    private let session: JSONText = "a2111111-1111-4111-8111-111111111111"

    private func transcript(_ sequence: Int, _ item: JSONText, _ text: JSONText,
                            role: JSONText = "user", final: Bool = false,
                            reply: JSONText? = nil, session: JSONText? = nil) -> JSONValue {
        var fields: [JSONText: JSONValue] = ["sequence": .integer(sequence), "type": .text("transcript"),
            "sessionId": .string(session ?? self.session), "itemId": .string(item), "role": .string(role),
            "text": .string(text), "complete": .bool(final), "createdAt": .number(Double(sequence))]
        if let reply { fields["replyToItemId"] = .string(reply) }
        return .object(fields)
    }

    private func answer(_ sequence: Int, reply: JSONText?, text: JSONText = "Feedback") -> JSONValue {
        var fields: [JSONText: JSONValue] = ["sequence": .integer(sequence), "type": .text("answer"),
            "sessionId": .string(session), "text": .string(text)]
        if let reply { fields["replyToItemId"] = .string(reply) }
        return .object(fields)
    }

    @Test func identifiedFeedbackBeforeASRRemembersRetirementWithoutHidingAnotherInput() throws {
        for mappedTranscript in [false, true] {
            var state = NativeVoiceInputTranscript()
            state.begin(sessionID: session)
            func receive(_ value: JSONValue) throws { state.receive(try NativeVoiceEvent(value)) }
            try receive(answer(1, reply: "empty", text: " \n"))
            try receive(transcript(2, "empty", "Still needed"))
            try receive(mappedTranscript ? transcript(3, "reply-a", "Accepted", role: "assistant", reply: "a")
                                        : answer(3, reply: "a"))
            #expect(state.message?.text == "Still needed")
            try receive(transcript(4, "a", "Late first ASR", final: true))
            #expect(state.message?.text == "Still needed")
            try receive(transcript(5, "b", "Next request"))
            try receive(transcript(6, "a", "Duplicate ASR", final: true))
            #expect(state.message?.text == "Next request")
            state.begin(sessionID: "new-session")
            try receive(transcript(7, "a", "Fresh session", session: "new-session"))
            try receive(answer(8, reply: "a"))
            #expect(state.message?.text == "Fresh session")
        }
    }

    @Test(arguments: ["Completed result", "Moku 的任务已中断，已有文字结果仍保留。", "Moku 的任务失败了，请查看任务中的错误信息。"])
    func terminalFeedbackRetiresOnlyItsInputAndLateFinalCannotReopenIt(text: String) throws {
        var state = NativeVoiceInputTranscript()
        state.begin(sessionID: session)
        func receive(_ value: JSONValue) throws { state.receive(try NativeVoiceEvent(value)) }
        try receive(transcript(1, "a", "Still waiting", final: true))
        try receive(answer(2, reply: "a", text: JSONText(text)))
        #expect(state.message == nil)
        try receive(transcript(3, "b", "Next request"))
        try receive(answer(4, reply: "a", text: JSONText(text)))
        try receive(transcript(5, "a", "Late final", final: true))
        #expect(state.message?.text == "Next request")
    }

    @Test func realPollKeepsLateAcknowledgedASROutOfTheDock() async throws {
        let fixture = MediaFixture(session: session)
        let client = fixture.client()
        client.setOwner("moku", available: true)
        let starting = Task { await client.start() }
        await fixture.waitForPermissionGate()
        fixture.events = [answer(1, reply: "a"), transcript(2, "a", "Late ASR", final: true)]
        await fixture.wait { client.state.caption == "Late ASR" }
        #expect(client.inputTranscript.message == nil)
        fixture.events = [transcript(3, "b", "Next request"), answer(4, reply: "a")]
        await fixture.wait { client.state.caption == "Feedback" }
        #expect(client.inputTranscript.message?.text == "Next request")
        await client.stop()
        fixture.releasePermissionGate()
        await starting.value
        #expect(client.inputTranscript.message == nil)
    }

    @Test func partialFinalFeedbackClearAndInterleavingUseStableIdentities() throws {
        var state = NativeVoiceInputTranscript()
        state.begin(sessionID: session)
        func receive(_ value: JSONValue) throws { state.receive(try NativeVoiceEvent(value)) }
        try receive(transcript(1, "a", " \n"))
        #expect(state.message == nil)
        try receive(transcript(2, "a", "Hello"))
        let id = state.message?.id
        try receive(transcript(3, "a", "Hello world"))
        #expect(state.message?.id == id && state.message?.text == "Hello world")
        try receive(transcript(3, "a", "duplicate sequence"))
        #expect(state.message?.text == "Hello world")
        try receive(transcript(4, "a", "Hello world!", final: true))
        #expect(state.message?.complete == true && state.message?.id == id)
        try receive(transcript(5, "a", "late partial"))
        try receive(answer(6, reply: nil))
        try receive(transcript(7, "assistant", " \n", role: "assistant"))
        #expect(state.message?.text == "Hello world!")
        try receive(transcript(8, "b", "New round"))
        try receive(answer(9, reply: "a"))
        try receive(transcript(10, "a", "Late final", final: true))
        #expect(state.message?.text == "New round")
        try receive(transcript(11, "b", "New final", final: true))
        try receive(answer(12, reply: "b", text: ""))
        #expect(state.message?.text == "New final")
        try receive(transcript(13, "reply-b", "Accepted", role: "assistant", reply: "b"))
        #expect(state.message == nil)
        try receive(transcript(14, "b", "Replayed final", final: true))
        #expect(state.message == nil)
        try receive(transcript(15, "c", "Clear me"))
        try receive(transcript(16, "c", ""))
        #expect(state.message == nil)
        try receive(transcript(17, "c", "Fresh partial"))
        try receive(transcript(100, "old", "Foreign session", session: "old-session"))
        #expect(state.message?.text == "Fresh partial")
        try receive(answer(18, reply: "c"))
        #expect(state.message == nil)
    }

    @Test func flatReplyStartsHideInputOnceAndLateInputFinalCannotReopenIt() throws {
        var state = NativeVoiceInputTranscript()
        state.begin(sessionID: session)
        func receive(_ value: JSONValue) throws { state.receive(try NativeVoiceEvent(value)) }
        try receive(transcript(1, "a", "Research PHP incidents"))
        try receive(transcript(2, "reply-a", " \n", role: "assistant"))
        #expect(state.message != nil)
        try receive(transcript(3, "reply-a", "I will", role: "assistant", session: "old-session"))
        #expect(state.message != nil)
        try receive(transcript(4, "reply-a", "I will", role: "assistant"))
        #expect(state.message == nil) // First partial, before reply completion.
        try receive(transcript(5, "a", "Research recent PHP incidents", final: true))
        #expect(state.message == nil)
        try receive(transcript(6, "b", "Focus on this month"))
        try receive(transcript(7, "reply-a", "I will research that", role: "assistant"))
        try receive(transcript(8, "reply-a", "I will research that.", role: "assistant", final: true))
        #expect(state.message?.text == "Focus on this month")
        try receive(transcript(9, "reply-b", "Understood", role: "assistant"))
        #expect(state.message == nil)
        try receive(transcript(10, "b", "Focus on this month", final: true))
        #expect(state.message == nil)
        try receive(transcript(11, "c", "Another request"))
        try receive(transcript(12, "reply-a", "Duplicate old final", role: "assistant", final: true))
        try receive(transcript(13, "mapped-old", "Old answer", role: "assistant", reply: "a"))
        #expect(state.message?.text == "Another request")
    }

    @Test func realPollRetiresInputOnFirstFlatReplyAndKeepsNextInputDuringStreaming() async throws {
        let fixture = MediaFixture(session: session)
        let client = fixture.client()
        client.setOwner("moku", available: true)
        let starting = Task { await client.start() }
        await fixture.waitForPermissionGate()
        fixture.events = [transcript(1, "a", "Request", final: true)]
        await fixture.wait { client.inputTranscript.message != nil }
        fixture.events = [transcript(2, "reply-a", "Starting", role: "assistant")]
        await fixture.wait { client.inputTranscript.message == nil }
        fixture.events = [transcript(3, "a", "Late final", final: true),
                          transcript(4, "b", "Next request"),
                          transcript(5, "reply-a", "Starting research", role: "assistant", final: true)]
        await fixture.wait { client.state.caption == "Starting research" }
        #expect(client.inputTranscript.message?.text == "Next request")
        await client.stop()
        fixture.releasePermissionGate()
        await starting.value
        #expect(client.inputTranscript.message == nil)
    }

    @Test func realPreparePollAndStopFenceLateEventsWithoutOpeningMicrophone() async throws {
        let fixture = MediaFixture(session: session)
        let client = fixture.client()
        client.setOwner("moku", available: true)
        let starting = Task { await client.start() }
        await fixture.waitForPermissionGate()
        fixture.events = [transcript(1, "a", "Listening"), transcript(2, "a", "Final", final: true)]
        await fixture.wait { client.inputTranscript.message?.text == "Final" }
        #expect(client.inputTranscript.message?.complete == true)
        #expect(client.state.phase == .preparing && fixture.microphoneRequests == 1)
        // Mute/ASR completion do not retire the text, and this preparing gate
        // ensures no NativeWebRTCMedia, device or audio track has been created.
        client.toggleMute()
        #expect(client.inputTranscript.message?.text == "Final")
        fixture.holdNextPoll = true
        await fixture.waitForHeldPoll()
        await client.stop()
        #expect(client.inputTranscript.message == nil)
        fixture.releaseHeldPoll([transcript(90, "a", "Late retired poll", final: true)])
        fixture.releasePermissionGate()
        await starting.value
        #expect(client.state.phase == .closed && fixture.stopRequests == 1)

        fixture.session = "b2222222-2222-4222-8222-222222222222"
        fixture.events = [transcript(1, "a", "Old session"), transcript(2, "fresh", "Reconnected", session: fixture.session)]
        let reconnecting = Task { await client.start() }
        await fixture.waitForPermissionGate()
        await fixture.wait { client.inputTranscript.message?.text == "Reconnected" }
        client.setOwner("replacement-moku", available: true)
        #expect(client.inputTranscript.message == nil)
        await client.stop()
        fixture.releasePermissionGate()
        await reconnecting.value
        #expect(client.inputTranscript.message == nil)
    }

    @Test func errorsCloseAndHydrationRetireTheProjection() async throws {
        for kind in ["error", "closed"] {
            let fixture = MediaFixture(session: session)
            let client = fixture.client()
            client.setOwner("moku", available: true)
            let starting = Task { await client.start() }
            await fixture.waitForPermissionGate()
            fixture.events = [transcript(1, "a", "Before error")]
            await fixture.wait { client.inputTranscript.message != nil }
            fixture.events = [.object(["type": .text(kind), "sequence": .integer(2), "text": .text("ended")])]
            await fixture.wait { client.inputTranscript.message == nil }
            #expect(client.inputTranscript.message == nil)
            await client.stop()
            fixture.releasePermissionGate()
            await starting.value
        }
        var state = NativeVoiceInputTranscript()
        state.begin(sessionID: session)
        state.receive(try NativeVoiceEvent(transcript(1, "a", "old")))
        state.begin(sessionID: "new-session")
        #expect(state.message == nil)
        state.receive(try NativeVoiceEvent(transcript(2, "a", "late old")))
        #expect(state.message == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOKUSEI_VOICE_EVENT_EXPORT"] != nil, "Requires Go Codex voice-event fixtures in MOKUSEI_VOICE_EVENT_EXPORT; see tools/verification/codex"))
    func productionCodexAdapterExportReplaysThroughNativeDecoder() throws {
        let path = try #require(ProcessInfo.processInfo.environment["MOKUSEI_VOICE_EVENT_EXPORT"])
        let data = try JSONValue(data: Data(contentsOf: URL(fileURLWithPath: path)))
        let session = try #require(data["sessionId"]?.voiceText)
        var state = NativeVoiceInputTranscript()
        state.begin(sessionID: session)
        let events = try #require(data["events"]?.arrayValue).map(NativeVoiceEvent.init)
        var userIDs: Set<JSONText> = []
        var mappedFeedback = false
        var flatReplyStarted = false
        for event in events {
            let before = state.message
            state.receive(event)
            if let transcript = event.transcript, transcript.role == .user {
                userIDs.insert(transcript.id)
                #expect(state.message?.id == transcript.id)
                #expect(state.message?.text == transcript.text)
            } else if let transcript = event.transcript, transcript.role == .assistant,
                      event.replyToItemID == nil, !transcript.complete {
                flatReplyStarted = true
                #expect(before != nil && state.message == nil)
            } else if event.replyToItemID != nil, before != nil {
                mappedFeedback = true
                let replyID = event.replyToItemID.map { JSONText(codeUnits: session.codeUnits + [58] + $0.codeUnits) }
                if before?.id == replyID {
                    #expect(state.message == nil)
                } else {
                    #expect(state.message == before) // Late first-turn feedback.
                }
            }
        }
        #expect(userIDs.count == 3 && mappedFeedback && flatReplyStarted)
        #expect(state.message?.text == "new request")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOKUSEI_VOICE_EVENT_EXPORT"] != nil, "Requires Go Codex voice-event fixtures in MOKUSEI_VOICE_EVENT_EXPORT; see tools/verification/codex"))
    func productionCodexLateFinalFeedbackRetiresOnlyItsFrozenInput() throws {
        let path = try #require(ProcessInfo.processInfo.environment["MOKUSEI_VOICE_EVENT_EXPORT"])
        let data = try JSONValue(data: Data(contentsOf: URL(fileURLWithPath: path)))
        let session = try #require(data["sessionId"]?.voiceText)
        for key in ["handoffBeforeFinalEvents", "feedbackBeforeFinalEvents"] {
            let values = try #require(data[key]?.arrayValue)
            let events = try values.map(NativeVoiceEvent.init)
            let original = try #require(events.first?.transcript)
            var state = NativeVoiceInputTranscript()
            state.begin(sessionID: session)
            var mappedFeedback = false
            var newerInput: JSONText?
            for event in events {
                state.receive(event)
                if let transcript = event.transcript, transcript.role == .user {
                    if transcript.id == original.id {
                        #expect(!mappedFeedback && state.message?.id == original.id)
                    } else {
                        newerInput = transcript.id
                        #expect(state.message?.id == newerInput)
                    }
                } else if event.type == "answer" {
                    if event.replyToItemID != nil {
                        mappedFeedback = true
                        #expect(state.message?.id != original.id)
                        #expect(state.message?.id == newerInput)
                    } else {
                        // Actual feedback with no verified ASR identity must
                        // preserve the input until its exact final resolves it.
                        #expect(state.message?.id == original.id)
                    }
                }
            }
            #expect(mappedFeedback && newerInput != nil && state.message?.id == newerInput)
            var late = try #require(values.first?.objectValue)
            late["sequence"] = .integer(try #require(events.last?.sequence) + 1)
            late["complete"] = .bool(true)
            state.receive(try NativeVoiceEvent(.object(late)))
            #expect(state.message?.id == newerInput)
        }
    }
}

/// Uses the production command/poll seam and suspends permission before any
/// device allocation. No test replaces the production event reducer.
@MainActor private final class MediaFixture {
    private let ownership = NativeVoiceMediaOwnership()
    var session: JSONText
    var events: [JSONValue] = []
    var microphoneRequests = 0
    var stopRequests = 0
    private var permission: CheckedContinuation<Void, any Error>?
    var holdNextPoll = false
    private var heldPoll: CheckedContinuation<NativeVoiceResult, any Error>?
    init(session: JSONText) { self.session = session }
    func client() -> NativeVoiceMediaClient {
        NativeVoiceMediaClient(role: .moku, ownership: ownership, requestMicrophone: {
            self.microphoneRequests += 1
            try await withCheckedThrowingContinuation { self.permission = $0 }
        }, command: { request in
            switch request["action"]?.stringValue {
            case "prepare": return try NativeVoiceResult(.object(["sessionId": .string(self.session), "ownershipId": request["requestId"]!]))
            case "poll":
                if self.holdNextPoll {
                    self.holdNextPoll = false
                    return try await withCheckedThrowingContinuation { self.heldPoll = $0 }
                }
                let batch = self.events; self.events = []
                return try NativeVoiceResult(.object(["events": .array(batch)]))
            case "stop": self.stopRequests += 1; return try NativeVoiceResult(.object([:]))
            default: throw CancellationError()
            }
        })
    }
    func waitForPermissionGate() async { await wait { self.permission != nil } }
    func waitForHeldPoll() async { await wait { self.heldPoll != nil } }
    func releaseHeldPoll(_ events: [JSONValue]) {
        do { heldPoll?.resume(returning: try NativeVoiceResult(.object(["events": .array(events)]))) }
        catch { heldPoll?.resume(throwing: error) }
        heldPoll = nil
    }
    func releasePermissionGate() { permission?.resume(throwing: CancellationError()); permission = nil }
    func wait(_ predicate: () -> Bool) async {
        for _ in 0..<300 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for production media state")
    }
}
