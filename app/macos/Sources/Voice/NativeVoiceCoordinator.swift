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
            thread = NativeThreadVoice(threadID: threadID, client: client)
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
    }
}

/// Historical transcripts remain readable; this object owns no media client,
/// microphone, start route or task execution capability.
@MainActor
private final class NativeThreadVoice {
    private let threadID: JSONText
    private let client: RuntimeClient
    private var connected = false
    private var released = false
    private var revision = 0
    private var configuration: JSONText?
    private var loading = true
    private var historyError: JSONText = ""
    private var messages: [VoiceTranscriptMessage] = []
    private var refreshTask: Task<Void, Never>?

    lazy var capability = SidecardVoiceCapability(state: snapshot(),
        start: { throw NativeVoiceError("线程内语音已移除，请在 Overview 使用全局 Moku 语音。") },
        stop: {}, toggleMute: {}, refresh: { [weak self] in await self?.refresh() })

    init(threadID: JSONText, client: RuntimeClient) {
        self.threadID = threadID; self.client = client
    }
    private func snapshot() -> SidecardVoiceState {
        .init(phase: .closed, supported: false, available: false, loading: loading,
            muted: false, error: historyError, messages: messages)
    }
    func configure(enabled: Bool, connected: Bool, identity: JSONText) {
        guard !released else { return }
        let changed = configuration != identity || self.connected != connected
        configuration = identity; self.connected = connected
        if changed { scheduleRefresh() }
    }
    func setConnected(_ connected: Bool) {
        guard self.connected != connected else { return }
        self.connected = connected; scheduleRefresh()
    }
    func reset() { scheduleRefresh() }
    func release() {
        released = true; revision += 1
        refreshTask?.cancel(); refreshTask = nil
    }
    private func scheduleRefresh() {
        revision += 1; refreshTask?.cancel()
        guard connected, !released else { return }
        refreshTask = Task { [weak self] in await self?.refresh() }
    }
    private func refresh() async {
        guard connected, !released else { return }
        revision += 1
        let expected = revision
        loading = true; capability.publish(snapshot())
        do {
            let result = try NativeVoiceResult(await client.invoke("thread:voice-events", args: [
                .object(["threadId": .string(threadID), "request": .object(["action": .text("history")])])]))
            guard !Task.isCancelled, !released, revision == expected else { return }
            messages = result.messages; historyError = ""
        } catch {
            guard !Task.isCancelled, !released, revision == expected else { return }
            historyError = JSONText(error.localizedDescription)
        }
        loading = false; capability.publish(snapshot())
    }
}
