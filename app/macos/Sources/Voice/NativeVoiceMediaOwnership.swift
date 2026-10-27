import Foundation
import MokuseiCore

/// Connection lifetime is independent of device access. One coordinator owns
/// this arbiter; only a connected Moku call may survive a Thread's takeover.
@MainActor
final class NativeVoiceMediaOwnership {
    enum Role { case moku, thread }
    private struct Lease {
        weak var client: NativeVoiceMediaClient?
        let requestID: JSONText
        func matches(_ client: NativeVoiceMediaClient, _ requestID: JSONText) -> Bool {
            self.client === client && self.requestID == requestID
        }
    }
    private var current: Lease?
    private var suspendedMoku: Lease?
    private var threadTeardowns: [JSONText: Task<Void, Never>] = [:]

    func acquire(_ client: NativeVoiceMediaClient, requestID: JSONText) async {
        // Cancellation or a synchronous state observer may already have retired
        // this attempt before its async acquisition begins.
        guard !Task.isCancelled, client.ownsAttempt(requestID) else { return }
        let previous = current
        // Publish the successor before stopping the predecessor. Its synchronous
        // release (or a late stop reply) must not restore Moku over this claim.
        current = Lease(client: client, requestID: requestID)
        if let previous, let predecessor = previous.client,
           !previous.matches(client, requestID), predecessor.ownsAttempt(previous.requestID) {
            if predecessor.role == .moku, client.role == .thread, predecessor.state.phase == .listening {
                suspendedMoku = previous
                predecessor.suspendMedia(requestID: previous.requestID)
            } else {
                await predecessor.beginStop()?.value
            }
        }
        // A collapsed/released Thread has already relinquished devices and may
        // have restored Moku, but the server still admits only one discussion.
        // Join its teardown even when it is no longer the current media owner.
        if client.role == .thread {
            while client.ownsAttempt(requestID), !Task.isCancelled, !threadTeardowns.isEmpty {
                let pending = Array(threadTeardowns.values)
                for task in pending { await task.value }
            }
        }
    }

    func finishedTeardown(_ requestID: JSONText) { threadTeardowns[requestID] = nil }

    func release(_ client: NativeVoiceMediaClient, requestID: JSONText, teardown: Task<Void, Never>? = nil) {
        if client.role == .thread, let teardown { threadTeardowns[requestID] = teardown }
        if suspendedMoku?.matches(client, requestID) == true { suspendedMoku = nil }
        guard current?.matches(client, requestID) == true else { return }
        current = nil
        guard let lease = suspendedMoku, let moku = lease.client else { return }
        suspendedMoku = nil
        current = lease
        // Resume only the retained attempt token. Never start, prepare or
        // reconnect, including when the user explicitly ended that Moku call.
        moku.resumeMedia(requestID: lease.requestID)
    }
}

/// Replays run the production client/arbiter, commands, polling and attempt
/// fences with an injected native media transport, without opening an ADM.
@MainActor
protocol NativeVoiceMediaTransport: AnyObject {
    var onFailure: ((String) -> Void)? { get set }
    var onMessage: ((Data) -> Void)? { get set }
    var onInputAnalysis: ((NativeVoiceInputAnalysis) -> Void)? { get set }
    var channelOpen: Bool { get }
    func offer() async throws -> String
    func connect(answer: String) async throws
    func send(_ data: Data) throws
    func setAudioEnabled(_ enabled: Bool, muted: Bool) throws
    func setAnalysisEnabled(_ enabled: Bool)
    func close()
}
