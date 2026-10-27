import Foundation

struct RuntimeSettingsReadWaiter {
    let id: UUID
    let key: String
    let continuation: CheckedContinuation<Void, Error>
}

extension RuntimeClient {
    /// Cold discovery fans out across defaults, Moku and application profiles.
    /// Backpressure it before HTTP admission, leaving the host's 16 command
    /// slots available for hydration, saves and diagnostics. One read per
    /// Harness also avoids duplicate initialization and lets other Harnesses
    /// progress while a native CLI is slow. activeCommands bounds the backlog.
    func acquireSettingsRead(key: String) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if activeSettingsReads.count < 4 && !activeSettingsReads.contains(key) {
                    activeSettingsReads.insert(key)
                    continuation.resume()
                } else {
                    waitingSettingsReads.append(.init(id: id, key: key, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelSettingsRead(id: id) }
        }
    }

    private func cancelSettingsRead(id: UUID) {
        guard let index = waitingSettingsReads.firstIndex(where: { $0.id == id }) else { return }
        waitingSettingsReads.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    func releaseSettingsRead(key: String) {
        activeSettingsReads.remove(key)
        // FIFO among eligible Harnesses: a second request for a busy Harness
        // must not hold up an unrelated installation or catalog read.
        while activeSettingsReads.count < 4,
              let index = waitingSettingsReads.firstIndex(where: { !activeSettingsReads.contains($0.key) }) {
            let waiter = waitingSettingsReads.remove(at: index)
            activeSettingsReads.insert(waiter.key)
            waiter.continuation.resume()
        }
    }
}
