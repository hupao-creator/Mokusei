import Foundation
import MokuseiCore

/// One admitted detail route can alternate between visible and covered several
/// times. Cumulative durations make delivery retries idempotent at the Runtime.
@MainActor final class NativeThreadVisitTracker {
    typealias Send = (JSONValue) async throws -> Void
    private let send: Send
    private let now: () -> TimeInterval
    private var thread: JSONText?
    private var id = UUID()
    private var foregroundSince: TimeInterval?
    private var elapsed: TimeInterval = 0
    private var completedExecution: JSONText?
    private var searchOpen = false
    private var checkpoint: Task<Void, Never>?
    private var delivery: Task<Void, Never>?

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, send: @escaping Send) {
        self.now = now
        self.send = send
    }

    func update(thread next: JSONText?, visible: Bool, completed: JSONText?, fromSearch: Bool) {
        let timestamp = now()
        if thread != next {
            checkpoint?.cancel(); checkpoint = nil
            if thread != nil { flush(at: timestamp, visible: false) }
            thread = next
            id = UUID()
            elapsed = 0
            foregroundSince = nil
            completedExecution = nil
            searchOpen = fromSearch
            if next != nil {
                completedExecution = completed
                flush(at: timestamp, visible: visible)
            }
        } else if next != nil && ((foregroundSince != nil) != visible || completedExecution != completed) {
            let sawCompletion = visible && foregroundSince != nil && completed != nil && completedExecution != completed
            completedExecution = completed
            flush(at: timestamp, visible: visible, sawCompletion: sawCompletion)
        }
        if visible, thread != nil, checkpoint == nil {
            // Fresh dwell evidence remains available during a long uninterrupted
            // read. Never estimate time while the reader is in the background.
            checkpoint = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    guard let self, self.foregroundSince != nil else { return }
                    self.flush(at: self.now(), visible: true)
                }
            }
        } else if !visible {
            checkpoint?.cancel(); checkpoint = nil
        }
    }

    private func flush(at timestamp: TimeInterval, visible: Bool, sawCompletion: Bool = false) {
        guard let thread else { return }
        if let since = foregroundSince { elapsed += max(0, timestamp - since) }
        foregroundSince = visible ? timestamp : nil
        let payload = JSONValue.object([
            "threadId": .string(thread), "visitId": .text(id.uuidString),
            "elapsed": .number((elapsed * 1000).rounded(.down)), "foreground": .bool(visible),
            "searchOpen": .bool(searchOpen), "completedExecution": .string(completedExecution ?? ""),
            "alreadyVisible": .bool(sawCompletion)
        ])
        let previous = delivery
        let send = self.send
        delivery = Task {
            await previous?.value
            do { try await send(payload) }
            catch { NSLog("Thread visit delivery failed: %@", error.localizedDescription) }
        }
    }

    func finish() async {
        update(thread: nil, visible: false, completed: nil, fromSearch: false)
        await delivery?.value
        delivery = nil
    }
}
