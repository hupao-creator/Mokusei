import Darwin
import Foundation

/// Keep helper launch admission bounded even if an atexit handler stalls.
enum NativeProcessExit {
    @MainActor static func forceExit(prepareForExit: () -> Void) -> Never {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(750)) {
            _exit(EXIT_SUCCESS)
        }
        prepareForExit()
        exit(EXIT_SUCCESS)
    }
}
