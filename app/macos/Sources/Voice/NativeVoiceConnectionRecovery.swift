import Foundation
@preconcurrency import LiveKitWebRTC

/// A disconnected ICE transport can recover without a new offer or microphone
/// acquisition. One bounded deadline covers the whole interruption, including
/// checking/connecting and repeated disconnected callbacks.
@MainActor
final class NativeVoiceConnectionRecovery {
    enum Failure: Equatable { case ice, peer, timeout }
    private let delay: @MainActor @Sendable () async throws -> Void
    private var onFailure: ((Failure) -> Void)?
    private var deadline: (id: UUID, task: Task<Void, Never>)?
    private var stopped = false

    init(delay: @escaping @MainActor @Sendable () async throws -> Void = {
        try await Task.sleep(for: .seconds(10))
    }, onFailure: @escaping (Failure) -> Void) {
        self.delay = delay; self.onFailure = onFailure
    }

    func update(ice: LKRTCIceConnectionState, peer: LKRTCPeerConnectionState) {
        guard !stopped else { return }
        if ice == .failed || ice == .closed { fail(.ice); return }
        if peer == .failed || peer == .closed { fail(.peer); return }
        if (ice == .connected || ice == .completed) && peer == .connected {
            deadline?.task.cancel(); deadline = nil
            return
        }
        guard deadline == nil, ice == .disconnected || peer == .disconnected else { return }
        let id = UUID(), delay = delay
        let task = Task { [weak self] in
            do { try await delay() } catch { return }
            guard !Task.isCancelled, let self, !self.stopped, self.deadline?.id == id else { return }
            self.deadline = nil
            self.fail(.timeout)
        }
        deadline = (id, task)
    }

    func close() {
        stopped = true
        deadline?.task.cancel(); deadline = nil
        onFailure = nil
    }

    private func fail(_ failure: Failure) {
        let callback = onFailure
        close()
        callback?(failure)
    }
}
