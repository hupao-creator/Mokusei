import Darwin
import Foundation
import OSLog
import Synchronization

/// Process exit must not depend on either diagnostics writer or the main actor.
/// The caller arms this before stopping collection and starts two async drains.
final class NativeDiagnosticExit: Sendable {
    private struct State { var remaining = 2; var exitRequested = false }
    private let state = Mutex(State())
    private let terminate: @Sendable (_ timedOut: Bool) -> Void
    private let watchdog = DispatchQueue(label: "com.mokusei.diagnostics.exit", qos: .userInitiated)

    init(terminate: @escaping @Sendable (Bool) -> Void) {
        self.terminate = terminate
        watchdog.asyncAfter(deadline: .now() + .milliseconds(750)) { [self] in
            // The writer may be stuck on the very disk we would mark. The log
            // header already treats absence of sessionEnd as a potentially lost
            // tail. Keep the deadline armed even after requesting normal exit:
            // atexit handlers and stdio flushing can also block exit().
            Logger(subsystem: "com.mokusei.desktop", category: "layout").error("Diagnostic exit deadline reached after 750ms; diagnostic tail may be lost; forcing exit without waiting for drain or atexit")
            self.terminate(true)
        }
    }

    func completedDrain() {
        let first = state.withLock { value in
            guard !value.exitRequested else { return false }
            value.remaining -= 1
            guard value.remaining == 0 else { return false }
            value.exitRequested = true; return true
        }
        // Preserve AppKit/Swift actor assumptions in ordinary atexit handlers.
        // This hop is never joined by the watchdog: if the main actor is stuck,
        // the independent deadline still takes the hard-exit path.
        if first { DispatchQueue.main.async { [self] in terminate(false) } }
    }

    static func terminateProcess(timedOut: Bool) -> Never {
        if timedOut { _exit(EXIT_SUCCESS) }
        exit(EXIT_SUCCESS)
    }
}
