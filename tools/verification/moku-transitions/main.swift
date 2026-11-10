import AppKit
import MokuseiPluginUI

@MainActor private final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            let root = Bundle.main.bundleURL.deletingLastPathComponent()
            var result: [String: Any]
            do {
                let output = URL(fileURLWithPath: CommandLine.arguments[1])
                var evidence: [String: Any] = [:]
                evidence["horizontal"] = try await replayHorizontalTravel(output: output)
                result = ["ok": true, "message": "production Moku horizontal travel", "evidence": evidence]
            } catch { result = ["ok": false, "message": String(describing: error)] }
            try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("result.json"))
            NSApp.terminate(nil)
        }
    }
}

@main private struct Replay {
    @MainActor static func main() throws {
        try prepareIsolatedNativeReplay()
        NativeTypography.registerFonts()
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Delegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
