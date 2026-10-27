import Foundation
import Observation
import MokuseiCore
import MokuseiPluginAPI

/// Host-owned voice routes. Sidecards receive a capability for one source
/// thread, never a client or arbitrary target ID. The runtime alone constructs
/// direct Codex or relayed read-only discussion sessions.
@MainActor
public final class NativeVoiceCoordinator {
    public let moku: NativeVoiceMediaClient
    private let mediaOwnership = NativeVoiceMediaOwnership()
    private let client: RuntimeClient
    private let beforeCommand: () async throws -> Void
    private var connected = false
    private var snapshotAuthority: UUID?
    private var mokuOwner: JSONText?
    private var mokuEnabled = false
    private var threads: [JSONText: NativeThreadVoice] = [:]

    public init(client: RuntimeClient, beforeCommand: @escaping () async throws -> Void = {}) {
        self.client = client; self.beforeCommand = beforeCommand
        moku = NativeVoiceMediaClient(role: .moku, ownership: mediaOwnership, beforeStart: beforeCommand) { request in
            let channel = request["action"]?.stringValue == "poll" ? "moku:voice-events" : "moku:voice"
            return try NativeVoiceResult(await client.invoke(channel, args: [request]))
        }
    }

    public func configureMoku(owner: JSONText?, available: Bool) {
        mokuOwner = owner; mokuEnabled = available
        moku.setOwner(owner, available: available && connected && owner != nil)
    }

    public func threadCapability(threadID: JSONText, enabled: Bool, identity: JSONText) -> SidecardVoiceCapability {
        let thread: NativeThreadVoice
        if let existing = threads[threadID] { thread = existing }
        else {
            thread = NativeThreadVoice(threadID: threadID, client: client, ownership: mediaOwnership, beforeCommand: beforeCommand)
            threads[threadID] = thread
        }
        thread.configure(enabled: enabled, connected: connected, identity: identity)
        return thread.capability
    }

    public func releaseThread(_ threadID: JSONText) {
        threads.removeValue(forKey: threadID)?.release()
    }

    public func receive(_ event: RuntimeClientEvent) {
        switch event {
        case .connection(let status):
            connected = status == .connected
            moku.setOwner(mokuOwner, available: connected && mokuEnabled && mokuOwner != nil)
            for thread in threads.values { thread.setConnected(connected) }
        case .snapshot(_, let authority):
            // An observer replay may catch up missed mutations on the same
            // transport. Its retained authority must not interrupt live media.
            guard snapshotAuthority != authority else { return }
            snapshotAuthority = authority
            // A genuinely new hydration may replace ownership/history while
            // preserving IDs or revision numbers, so retire the old media owner.
            _ = moku.beginStop()
            for thread in threads.values { thread.reset() }
        default: break
        }
    }

    public func stopAll() async {
        connected = false
        moku.setOwner(mokuOwner, available: false)
        let all = Array(threads.values)
        for thread in all { thread.release() }
        threads.removeAll()
        await moku.stop()
        for thread in all { await thread.media.stop() }
    }
}

@MainActor
private final class NativeThreadVoice {
    let media: NativeVoiceMediaClient
    private let command: (JSONValue) async throws -> NativeVoiceResult
    private let threadID: JSONText
    private var enabled = false
    private var connected = false
    private var released = false
    private var eligible = false
    private var configuration: JSONText?
    private var revision = 0
    private var supported = false
    private var loading = true
    private var historyError: JSONText = ""
    private var messages: [VoiceTranscriptMessage] = []
    private var refreshTask: Task<Void, Never>?

    lazy var capability = SidecardVoiceCapability(state: snapshot(),
        start: { [weak self] in await self?.start() },
        stop: { [weak self] in await self?.stop() },
        toggleMute: { [weak self] in self?.media.toggleMute() },
        refresh: { [weak self] in await self?.refresh() })

    init(threadID: JSONText, client: RuntimeClient, ownership: NativeVoiceMediaOwnership, beforeCommand: @escaping () async throws -> Void) {
        self.threadID = threadID
        let command: (JSONValue) async throws -> NativeVoiceResult = { request in
            let action = request["action"]?.stringValue
            let channel = action == "poll" || action == "history" ? "thread:voice-events" : "thread:voice"
            return try NativeVoiceResult(await client.invoke(channel,
                args: [.object(["threadId": .string(threadID), "request": request])]))
        }
        self.command = command
        media = NativeVoiceMediaClient(role: .thread, ownership: ownership, beforeStart: beforeCommand, command: command)
        media.onStateChange = { [weak self] in self?.publish() }
        media.onEvent = { [weak self] event in
            guard let self, let message = event.transcript else { return }
            if let index = self.messages.firstIndex(where: { $0.id == message.id }) { self.messages[index] = message }
            else { self.messages.append(message) }
            self.publish()
        }
    }

    private func snapshot() -> SidecardVoiceState {
        let state = media.state
        return SidecardVoiceState(phase: state.phase, supported: supported, available: state.available,
            loading: loading, muted: state.muted, error: state.error.codeUnits.isEmpty ? historyError : state.error, messages: messages)
    }
    private func publish() { capability.publish(snapshot()) }
    private func updateAvailability() {
        media.setOwner(threadID, available: !released && enabled && connected && eligible)
    }
    func configure(enabled: Bool, connected: Bool, identity: JSONText) {
        guard !released else { return }
        let first = configuration == nil
        let changed = configuration != nil && configuration != identity
        self.enabled = enabled; self.connected = connected; configuration = identity
        if changed { eligible = false; revision += 1 }
        updateAvailability()
        if first || changed { scheduleRefresh(afterStop: changed) }
    }
    func setConnected(_ connected: Bool) {
        let changed = self.connected != connected
        self.connected = connected
        if !connected { revision += 1 }
        updateAvailability()
        if changed && connected { scheduleRefresh() }
    }
    func reset() {
        eligible = false; revision += 1
        updateAvailability()
        scheduleRefresh(afterStop: true)
    }
    private func scheduleRefresh(afterStop: Bool = false) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            if afterStop { await self.media.stop() }
            guard !Task.isCancelled, !self.released, self.connected else { return }
            await self.refresh()
        }
    }
    func release() {
        released = true; enabled = false; revision += 1
        refreshTask?.cancel(); refreshTask = nil
        updateAvailability()
    }
    private func refresh() async {
        guard !released, connected else { return }
        revision += 1
        let expected = revision
        loading = true; publish()
        do {
            let result = try await command(.object(["action": .text("history")]))
            guard !released, expected == revision, !Task.isCancelled else { return }
            historyError = ""; eligible = result.available; supported = result.supported
            var fresh = result.messages
            if [.preparing, .connecting, .listening].contains(media.state.phase) {
                for message in messages {
                    if let index = fresh.firstIndex(where: { $0.id == message.id }) { fresh[index] = message }
                    else { fresh.append(message) }
                }
            }
            messages = fresh; loading = false
            updateAvailability(); publish()
        } catch {
            guard !released, expected == revision, !Task.isCancelled else { return }
            loading = false; historyError = JSONText(error.localizedDescription)
            publish()
        }
    }
    private func start() async {
        guard media.state.available, !loading, !released else { return }
        historyError = ""; publish()
        await media.start()
    }
    private func stop() async {
        await media.stop()
        if enabled && connected && !released { await refresh() }
    }
}
