import AppKit
import Testing

/// Swift Testing's command-line runner does not run NSApplication's event loop.
/// Real editing/focus and screenshot cases run here as a separate fixture app.
@MainActor private final class SearchReplayDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        Task { await Testing.__swiftPMEntryPoint() as Never }
    }
}

@main private struct SearchReplay {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = SearchReplayDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
