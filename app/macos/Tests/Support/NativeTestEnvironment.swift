import AppKit
import Dispatch
import Testing

/// Drive polls from AppKit's queue and expose timer versus task-resumption delay.
/// This is observation scheduling, never a virtual animation clock.
@MainActor public enum NativeReplayObservation {
    public struct Wakeup: Sendable {
        public let scheduledAt: Double
        public let firedAt: Double
        public let resumedAt: Double
    }

    public static func waitForNextPoll() async throws -> Wakeup {
        let delay = ObservationDelay()
        let firedAt = try await delay.wait()
        try Task.checkCancellation()
        return Wakeup(scheduledAt: delay.scheduledAt, firedAt: firedAt,
                      resumedAt: ProcessInfo.processInfo.systemUptime)
    }

    @MainActor private final class ObservationDelay {
        let scheduledAt = ProcessInfo.processInfo.systemUptime
        private var continuation: CheckedContinuation<Double, Error>?
        private var timer: DispatchSourceTimer?

        func wait() async throws -> Double {
            try Task.checkCancellation()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                    // Cancellation may arrive before the timer is registered.
                    // Its main-queue completion then observes the registered
                    // continuation; the post-wake check also covers a fire race.
                    let timer = DispatchSource.makeTimerSource(queue: .main)
                    self.timer = timer
                    timer.setEventHandler { [weak self] in
                        MainActor.assumeIsolated { self?.finish(error: nil) }
                    }
                    timer.schedule(deadline: .now() + .milliseconds(10), leeway: .nanoseconds(0))
                    timer.resume()
                }
            } onCancel: {
                DispatchQueue.main.async { self.finish(error: CancellationError()) }
            }
        }

        private func finish(error: Error?) {
            guard let continuation else { return }
            self.continuation = nil
            // Either cancellation or the timer owns this one terminal receipt.
            // Disarm the source before resuming so it cannot outlive its poll.
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: ProcessInfo.processInfo.systemUptime) }
        }
    }
}

/// AppKit windows, focus, the Edit menu and the pasteboard belong to the process,
/// not a suite. MainActor isolation does not protect them across an `await`.
/// Keep this gate in one module shared by both integration test targets.
private actor NativeTestGate {
    static let shared = NativeTestGate()
    private var occupied = false
    private var pending: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !occupied { occupied = true; return }
        await withCheckedContinuation { pending.append($0) }
    }

    func release() {
        if pending.isEmpty { occupied = false }
        else { pending.removeFirst().resume() }
    }
}

public struct SerializedNativeTrait: TestTrait, SuiteTrait, TestScoping {
    public var isRecursive: Bool { true }

    // Acquiring at both suite/function and case scope would deadlock. Each
    // parameterized case owns the gate through its asynchronous cleanup.
    public func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        testCase == nil ? nil : self
    }

    public func provideScope(for test: Test, testCase: Test.Case?,
                             performing function: @Sendable () async throws -> Void) async throws {
        await NativeTestGate.shared.acquire()
        // Native SDK exits can precede the runner's summary. Opt-in ownership
        // markers identify the active fixture without logging its user data.
        let tracing = ProcessInfo.processInfo.environment["MOKUSEI_NATIVE_TEST_GATE_TRACE"] == "1"
        func trace(_ phase: String) {
            if tracing { FileHandle.standardOutput.write(Data("NATIVE_GATE \(phase): \(test.id)\n".utf8)) }
        }
        trace("begin")
        do {
            try Task.checkCancellation()
            try await function()
            trace("end")
            await NativeTestGate.shared.release()
        } catch {
            trace("error")
            await NativeTestGate.shared.release()
            throw error
        }
    }
}

extension Trait where Self == SerializedNativeTrait {
    public static var serializedNative: Self { Self() }
}

extension Trait where Self == ConditionTrait {
    /// The override exercises the same admission path on a developer's desktop
    /// without logging out, disconnecting displays or changing system settings.
    public static var requiresDisplay: Self {
        .enabled("Requires a logged-in WindowServer session and a display; unavailable in headless mode (MOKUSEI_TEST_HEADLESS=1). Run again in a graphical macOS session.") {
            guard ProcessInfo.processInfo.environment["MOKUSEI_TEST_HEADLESS"] != "1",
                  CGSessionCopyCurrentDictionary() != nil else { return false }
            return await MainActor.run { !NSScreen.screens.isEmpty }
        }
    }
}
