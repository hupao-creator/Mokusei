import AppKit
import Testing

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
