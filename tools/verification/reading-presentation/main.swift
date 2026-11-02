import AppKit
import Testing

/// SwiftPM does not run AppKit's event loop. Run the same integration suite in
/// an isolated native app, with real occlusion, focus and animation lifecycles.
@MainActor private final class ReadingPresentationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        Task(priority: .userInitiated) { await Testing.__swiftPMEntryPoint() as Never }
    }
}

@main private struct ReadingPresentationReplay {
    @MainActor static func main() {
        do { try prepareIsolatedNativeReplay() }
        catch { print("FAIL replay isolation: \(error)"); exit(1) }
        let app = NSApplication.shared
        let delegate = ReadingPresentationDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        // Submit live input before the captured frame's 50ms freshness expires.
        // Request timer precision for this isolated app, not system preferences.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Observe native replay animation frames at their original deadlines")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        print("NATIVE_REPLAY_TIMING userInitiated=true latencyCritical=true")
        withExtendedLifetime(delegate) { app.run() }
    }
}
