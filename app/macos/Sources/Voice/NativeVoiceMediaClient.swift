import Foundation
import Observation
import MokuseiCore

/// Native counterpart of the shared Moku/thread desktop media client. A call
/// owns media independently of admitted Moku work, which stays backend-owned.
@MainActor @Observable
public final class NativeVoiceMediaClient {
    public private(set) var state = NativeVoiceMediaState() { didSet { onStateChange?() } }
    // Kept outside the semantic state: metering must not republish sidecard history.
    public private(set) var inputAnalysis = NativeVoiceInputAnalysis()
    public private(set) var inputTranscript = NativeVoiceInputTranscript()
    public var inputLevel: Double { inputAnalysis.level }
    @ObservationIgnored private var visualizers: Set<UUID> = []
    @ObservationIgnored private let command: (JSONValue) async throws -> NativeVoiceResult
    @ObservationIgnored let role: NativeVoiceMediaOwnership.Role
    @ObservationIgnored private let ownership: NativeVoiceMediaOwnership
    @ObservationIgnored private let requestMicrophone: () async throws -> Void
    @ObservationIgnored private let makeMedia: () -> any NativeVoiceMediaTransport
    @ObservationIgnored private let beforeStart: () async throws -> Void
    @ObservationIgnored private var owner: JSONText?
    @ObservationIgnored private var attempt: Attempt?
    @ObservationIgnored private var stopping: Task<Void, Never>?
    @ObservationIgnored private var pendingTakeover: JSONText?
    @ObservationIgnored var onEvent: ((NativeVoiceEvent) -> Void)?
    @ObservationIgnored var onStateChange: (() -> Void)?

    @MainActor
    private final class Attempt {
        let requestID = JSONText(UUID().uuidString.lowercased())
        let timingContext = NativePerformance.nextID()
        var sessionID: JSONText?
        var media: (any NativeVoiceMediaTransport)?
        var poll: Task<Void, Never>?
        var after = 0
        var playback = NativeVoicePlayback()
        var startupOutcome: NativePerformance.Outcome = .cancelled
        let takeover: JSONText?
        let reconnectFrom: JSONText?
        var inputPending = false
        var speechActive = false
        var inputGeneration = -1
        var inputResponseID: JSONText?
        var speechReceipts: [SpeechReceipt] = []
        var reconnectPending = false
        var reconnectRetired = false
        let muted: Bool
        init(takeover: JSONText?, reconnectFrom: JSONText? = nil, muted: Bool = false) {
            self.takeover = takeover; self.reconnectFrom = reconnectFrom; self.muted = muted
        }
    }

    @MainActor
    private final class SpeechReceipt {
        let deliveryID: JSONText
        let generation: Int
        var confirmed = false
        var responseID: JSONText?
        init(deliveryID: JSONText, generation: Int) { self.deliveryID = deliveryID; self.generation = generation }
    }

    init(role: NativeVoiceMediaOwnership.Role,
         ownership: NativeVoiceMediaOwnership,
         requestMicrophone: @escaping () async throws -> Void = { try await NativeWebRTCMedia.requestMicrophone() },
         makeMedia: @escaping () -> any NativeVoiceMediaTransport = { NativeWebRTCMedia() },
         beforeStart: @escaping () async throws -> Void = {},
         command: @escaping (JSONValue) async throws -> NativeVoiceResult) {
        self.role = role; self.ownership = ownership
        self.requestMicrophone = requestMicrophone; self.makeMedia = makeMedia
        self.beforeStart = beforeStart; self.command = command
    }

    func setOwner(_ owner: JSONText?, available: Bool) {
        if self.owner != owner || !available {
            _ = beginStop()
            pendingTakeover = nil; state.occupiedOwner = nil
        }
        self.owner = owner
        state.available = available
    }

    /// Call only from an explicit start action. Capability preparation precedes
    /// the permission prompt and every native microphone/audio allocation.
    public func start() async { await start(takeover: nil) }

    /// Only the visible takeover action may present the generation that the
    /// server reported as occupied. A stale confirmation cannot replace a newer
    /// device's session.
    public func takeOver() async {
        guard let pendingTakeover else { return }
        await start(takeover: pendingTakeover)
    }

    private func start(takeover: JSONText?) async {
        guard !Task.isCancelled, state.available, attempt == nil, stopping == nil,
              state.phase == .closed || state.phase == .failed else { return }
        let attempt = Attempt(takeover: takeover)
        install(attempt)
        await runStartup(attempt)
    }

    private func install(_ attempt: Attempt) {
        self.attempt = attempt
        pendingTakeover = nil; state.occupiedOwner = nil
        inputTranscript = .init()
        state.mediaSuspended = false
        state.phase = .preparing; state.error = ""; state.caption = ""; state.muted = attempt.muted
    }

    private func runStartup(_ attempt: Attempt) async {
        guard self.attempt === attempt else { return }
        let startup = NativePerformance.begin(.voiceStartup, context: attempt.timingContext)
        await withTaskCancellationHandler {
            let acquisition = NativePerformance.begin(.voiceOwnership, context: attempt.timingContext)
            await ownership.acquire(self, requestID: attempt.requestID)
            acquisition?.end(self.attempt === attempt ? .completed : .cancelled)
            await NativePerformance.$context.withValue(attempt.timingContext) { await connect(attempt) }
        } onCancel: {
            Task { @MainActor [weak self, weak attempt] in
                guard let self, let attempt, self.attempt === attempt else { return }
                _ = self.beginStop()
            }
        }
        startup?.end(attempt.startupOutcome)
    }

    private func connect(_ attempt: Attempt) async {
        do {
            try check(attempt)
            try await measure(.voiceBeforeStart) { try await beforeStart() }
            try check(attempt)
            var preparation: [JSONText: JSONValue] = ["action": .text("prepare"), "requestId": .string(attempt.requestID)]
            if let takeover = attempt.takeover { preparation["takeover"] = .string(takeover) }
            if let reconnectFrom = attempt.reconnectFrom { preparation["reconnectFrom"] = .string(reconnectFrom) }
            let prepared = try await measure(.voicePrepare) { try await command(.object(preparation)) }
            if let occupied = prepared.occupiedOwner {
                try check(attempt)
                pendingTakeover = occupied.ownershipID; state.occupiedOwner = occupied.deviceID
                throw NativeVoiceError("另一台设备正在使用 Moku 语音。确认接管后才能替换该通话。")
            }
            guard let sessionID = prepared.sessionID else { throw NativeVoiceError("语音准备没有返回会话") }
            guard prepared.ownershipID == attempt.requestID else { throw NativeVoiceError("语音准备返回的所有权已失效") }
            attempt.sessionID = sessionID
            guard self.attempt === attempt else {
                _ = try? await command(.object(["action": .text("stop"), "sessionId": .string(sessionID), "ownershipId": .string(attempt.requestID)]))
                return
            }
            inputTranscript.begin(sessionID: sessionID)
            startPolling(attempt)
            try check(attempt)
            try await measure(.voiceMicrophonePermission) { try await requestMicrophone() }
            try check(attempt)
            let media = makeMedia()
            attempt.media = media
            media.onFailure = { [weak self, weak attempt] message in
                guard let self, let attempt else { return }
                self.fail(attempt, NativeVoiceError(message))
            }
            media.onMessage = { [weak self, weak attempt] data in
                guard let self, let attempt, self.attempt === attempt else { return }
                attempt.playback.receive(data)
                let event = try? JSONValue(data: data)
                let type = event?["type"]?.stringValue
                if type == "input_audio_buffer.speech_started" {
                    attempt.inputPending = true; attempt.speechActive = true; attempt.inputResponseID = nil
                }
                if type == "input_audio_buffer.speech_stopped" { attempt.speechActive = false }
                if type == "input_audio_buffer.cleared" { attempt.inputPending = false; attempt.speechActive = false }
                if type == "response.created", let id = event?["response"]?["id"]?.voiceText {
                    if let speech = attempt.speechReceipts.first(where: { $0.confirmed && $0.responseID == nil }) { speech.responseID = id }
                    else if attempt.inputPending && attempt.inputResponseID == nil { attempt.inputResponseID = id }
                }
                if type == "response.done", let response = event?["response"], let id = response["id"]?.voiceText {
                    if attempt.inputResponseID == id { attempt.inputPending = false; attempt.inputResponseID = nil }
                    let failed = response["status"]?.stringValue == "failed" || response["status"]?.stringValue == "cancelled"
                    let noAudio = response["output"]?.arrayValue.map { output in
                        !output.contains { item in (item["content"]?.arrayValue ?? []).contains { ["audio", "output_audio"].contains($0["type"]?.stringValue ?? "") } }
                    } ?? false
                    if failed || noAudio {
                        attempt.playback.completeWithoutAudio(id)
                        attempt.speechReceipts.removeAll { $0.responseID == id }
                    }
                }
                if (type == "output_audio_buffer.stopped" || type == "output_audio_buffer.cleared"), let id = event?["response_id"]?.voiceText {
                    attempt.speechReceipts.removeAll { $0.responseID == id }
                }
                self.confirmSpeechIfReady(attempt)
                if self.state.mediaSuspended && (type == "response.created" || type == "output_audio_buffer.started") {
                    do { try self.clearMediaBuffers(attempt) }
                    catch { self.fail(attempt, error) }
                }
            }
            media.onInputAnalysis = { [weak self, weak attempt] analysis in
                guard let self, let attempt, self.attempt === attempt,
                      self.state.phase == .listening, !self.state.muted, !self.state.mediaSuspended else { return }
                self.inputAnalysis = analysis
            }
            state.phase = .connecting
            let sdp = try await measure(.voiceOffer) { try await media.offer() }
            try check(attempt)
            if attempt.muted { try media.setAudioEnabled(true, muted: true) }
            let answer = try await measure(.voiceRemoteSDP) { try await command(.object(["action": .text("start"), "sessionId": .string(sessionID), "ownershipId": .string(attempt.requestID), "sdp": .text(sdp)])) }
            try check(attempt)
            guard let sdp = answer.sdp, !sdp.isEmpty else { throw NativeVoiceError("语音服务没有返回 SDP") }
            try await measure(.voiceConnect) { try await media.connect(answer: sdp) }
            try check(attempt)
            state.phase = .listening
            confirmSpeechIfReady(attempt)
            attempt.startupOutcome = .completed
            media.setAnalysisEnabled(!visualizers.isEmpty)
        } catch {
            if self.attempt === attempt { fail(attempt, error) }
        }
    }

    private func check(_ attempt: Attempt) throws {
        try Task.checkCancellation()
        guard self.attempt === attempt else { throw CancellationError() }
    }

    private func startPolling(_ attempt: Attempt) {
        guard let sessionID = attempt.sessionID else { return }
        attempt.poll = Task { [weak self, weak attempt] in
            while !Task.isCancelled {
                guard let self, let attempt, self.attempt === attempt else { return }
                do {
                    let result = try await self.command(.object(["action": .text("poll"),
                        "sessionId": .string(sessionID), "ownershipId": .string(attempt.requestID), "after": .integer(attempt.after)]))
                    guard self.attempt === attempt, !Task.isCancelled else { return }
                    if NativePerformance.mode == .detailed {
                        NativePerformance.event(.voiceMediaHealth, context: attempt.timingContext,
                            values: ["pollSucceeded": 1, "pollAfter": Double(attempt.after),
                                     "pollEvents": Double(result.events.count)])
                    }
                    if let error = result.reconnectError { throw NativeVoiceError(error) }
                    attempt.reconnectPending = result.reconnect
                    attempt.reconnectRetired = result.reconnectRetired
                    for event in result.events where event.sequence > attempt.after {
                        attempt.after = event.sequence
                        self.receive(event, attempt: attempt)
                        guard self.attempt === attempt else { return }
                    }
                    if self.reconnectIfReady(attempt) { return }
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    if !Task.isCancelled {
                        if self.attempt === attempt, NativePerformance.mode == .detailed {
                            NativePerformance.event(.voiceMediaHealth, context: attempt.timingContext,
                                values: ["pollFailed": 1, "pollAfter": Double(attempt.after)])
                        }
                        self.fail(attempt, error)
                    }
                    return
                }
            }
        }
    }

    private func receive(_ event: NativeVoiceEvent, attempt: Attempt) {
        guard self.attempt === attempt else { return }
        if NativePerformance.mode == .detailed {
            // Fixed categories only: never persist event text or session IDs.
            let category: Double = switch event.type {
            case "closed": 1
            case "error": 2
            case "speech-error": 3
            case "transcript": 4
            case "answer": 5
            default: 0
            }
            NativePerformance.event(.voiceMediaHealth, context: attempt.timingContext,
                values: ["hostEventClass": category, "hostEventSequence": Double(event.sequence)])
        }
        if event.type == "input", let generation = event.generation {
            attempt.inputGeneration = max(attempt.inputGeneration, generation)
            attempt.speechReceipts.removeAll { $0.generation < generation }
        }
        if event.type == "speech-ready", let delivery = event.deliveryID, let generation = event.generation,
           generation >= attempt.inputGeneration, !attempt.speechReceipts.contains(where: { $0.deliveryID == delivery }) {
            attempt.speechReceipts.append(SpeechReceipt(deliveryID: delivery, generation: generation))
        }
        if event.type == "speech-error", let delivery = event.deliveryID { attempt.speechReceipts.removeAll { $0.deliveryID == delivery } }
        // A settings reconnect intentionally retires the old peer. Its closed
        // event must not convert the retained call intent into an explicit Stop.
        if attempt.reconnectPending && event.type == "closed" { return }
        inputTranscript.receive(event)
        onEvent?(event)
        guard self.attempt === attempt else { return }
        switch event.type {
        case "closed": _ = beginStop()
        case "error": fail(attempt, NativeVoiceError(event.text?.string ?? "语音失败"))
        case "speech-error": state.error = event.text ?? "播报未确认，文字结果仍保留"
        case "transcript", "answer": state.caption = event.text ?? ""
        default: break
        }
        confirmSpeechIfReady(attempt)
    }

    private func confirmSpeechIfReady(_ attempt: Attempt) {
        guard self.attempt === attempt, state.phase == .listening, !state.mediaSuspended,
              !attempt.inputPending, !attempt.speechActive,
              attempt.playback.responseID == nil, attempt.playback.bufferedResponseID == nil, attempt.playback.playbackID == nil,
              let speech = attempt.speechReceipts.first, !speech.confirmed, let sessionID = attempt.sessionID else { return }
        speech.confirmed = true
        Task { [weak self, weak attempt, weak speech] in
            guard let self, let attempt, let speech, self.attempt === attempt,
                  attempt.speechReceipts.contains(where: { $0 === speech }) else { return }
            do {
                _ = try await self.command(.object(["action": .text("ack-speech"), "sessionId": .string(sessionID), "ownershipId": .string(attempt.requestID),
                    "deliveryId": .string(speech.deliveryID), "generation": .integer(speech.generation)]))
            } catch { self.fail(attempt, error) }
        }
    }

    private func reconnectIfReady(_ previous: Attempt) -> Bool {
        guard role == .moku, attempt === previous, previous.reconnectPending,
              state.phase == .listening, !state.mediaSuspended, state.available else { return false }
        if !previous.reconnectRetired {
            guard !previous.inputPending, !previous.speechActive, previous.speechReceipts.isEmpty,
                  previous.playback.responseID == nil, previous.playback.bufferedResponseID == nil,
                  previous.playback.playbackID == nil else { return false }
        }
        let next = Attempt(takeover: nil, reconnectFrom: previous.requestID, muted: state.muted)
        previous.poll?.cancel(); previous.poll = nil
        previous.media?.close(); previous.media = nil
        ownership.release(self, requestID: previous.requestID)
        install(next)
        // This is one continuation of the user's active call, fenced by its
        // replacement attempt. Failure remains visible; there is no retry loop.
        Task { [weak self, weak next] in
            guard let self, let next else { return }
            await self.runStartup(next)
        }
        return true
    }

    /// Called synchronously at the actual Moku submit action, before dispatch.
    /// An audio failure must never discard the user's text. No late poll/caption
    /// can clear the playback of a newer request.
    public func fenceTypedInput(_ request: JSONValue) -> JSONValue {
        guard let attempt, let sessionID = attempt.sessionID,
              var fields = request.objectValue else { return request }
        if let media = attempt.media, media.channelOpen {
            do { for message in attempt.playback.interrupt() { try media.send(message.encodedData()) } }
            catch { fail(attempt, error) }
        }
        fields["voiceInput"] = .object(["sessionId": .string(sessionID), "ownershipId": .string(attempt.requestID), "inputId": .text(UUID().uuidString.lowercased())])
        return .object(fields)
    }

    public func toggleMute() {
        guard state.phase == .listening, let media = attempt?.media else { return }
        state.muted.toggle()
        inputAnalysis = .init()
        do { try media.setAudioEnabled(!state.mediaSuspended, muted: state.muted) }
        catch { if let attempt { fail(attempt, error) } }
    }

    func ownsAttempt(_ requestID: JSONText) -> Bool { attempt?.requestID == requestID }

    func suspendMedia(requestID: JSONText) {
        guard state.phase == .listening, let attempt, attempt.requestID == requestID,
              let media = attempt.media else { return }
        state.mediaSuspended = true
        inputAnalysis = .init()
        do {
            // Revoke actual device access before any asynchronous command or
            // successor allocation; a disabled RTP track alone still captures.
            try media.setAudioEnabled(false, muted: state.muted)
            try clearMediaBuffers(attempt)
        } catch { fail(attempt, error) }
    }

    func resumeMedia(requestID: JSONText) {
        guard state.mediaSuspended, let attempt, attempt.requestID == requestID,
              let media = attempt.media else { return }
        if attempt.reconnectPending && attempt.reconnectRetired {
            state.mediaSuspended = false
            _ = reconnectIfReady(attempt)
            return
        }
        do {
            // Drop speech/input accumulated around the handoff before enabling
            // the original peer. No server session is ever recreated here.
            try clearMediaBuffers(attempt)
            try media.setAudioEnabled(true, muted: state.muted)
            state.mediaSuspended = false
            confirmSpeechIfReady(attempt)
        } catch { fail(attempt, error) }
    }

    private func clearMediaBuffers(_ attempt: Attempt) throws {
        guard let media = attempt.media, media.channelOpen else { throw NativeVoiceError("语音数据通道已断开") }
        var messages = attempt.playback.interrupt()
        attempt.speechReceipts.removeAll { $0.confirmed }
        if !messages.contains(where: { $0["type"]?.stringValue == "output_audio_buffer.clear" }) {
            messages.append(.object(["type": .text("output_audio_buffer.clear")]))
        }
        messages.append(.object(["type": .text("input_audio_buffer.clear")]))
        for message in messages { try media.send(message.encodedData()) }
    }

    /// Each mounted Moku surface owns its demand; hiding one cannot retire a
    /// different visible surface. This affects observation, never call ownership.
    public func setVisualizationVisible(_ visible: Bool, owner: UUID) {
        if visible { visualizers.insert(owner) } else { visualizers.remove(owner) }
        let enabled = !visualizers.isEmpty
        attempt?.media?.setAnalysisEnabled(enabled)
        if !enabled { inputAnalysis = .init() }
    }

    private func fail(_ attempt: Attempt, _ error: Error) {
        guard self.attempt === attempt else { return }
        if attempt.startupOutcome != .completed { attempt.startupOutcome = error is CancellationError ? .cancelled : .failed }
        state.error = JSONText(error.localizedDescription)
        _ = beginStop(failed: true)
    }

    /// The first half is synchronous: retiring an owner immediately releases its
    /// microphone, speaker, peer, channel and heartbeat, even while stop awaits.
    @discardableResult
    func beginStop(failed: Bool = false) -> Task<Void, Never>? {
        inputTranscript = .init()
        if let stopping { return stopping }
        guard let attempt else { return nil }
        self.attempt = nil
        inputAnalysis = .init()
        attempt.poll?.cancel(); attempt.poll = nil
        attempt.media?.close(); attempt.media = nil
        state.phase = .stopping; state.muted = false; state.mediaSuspended = false
        let task = Task { [self] in
            do {
                _ = try await command(.object(["action": .text("stop"),
                    "sessionId": .string(attempt.sessionID ?? attempt.requestID), "ownershipId": .string(attempt.requestID)]))
                if let reconnectFrom = attempt.reconnectFrom, attempt.sessionID == nil {
                    _ = try await command(.object(["action": .text("stop"), "sessionId": .string(reconnectFrom), "ownershipId": .string(reconnectFrom)]))
                }
                state.phase = failed ? .failed : .closed
            } catch {
                state.phase = .failed
                if !failed || state.error.codeUnits.isEmpty { state.error = JSONText(error.localizedDescription) }
            }
            stopping = nil
            ownership.finishedTeardown(attempt.requestID)
        }
        stopping = task
        ownership.release(self, requestID: attempt.requestID, teardown: task)
        return task
    }

    public func stop() async { await beginStop()?.value }
}
