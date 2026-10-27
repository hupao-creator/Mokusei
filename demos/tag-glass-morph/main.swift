import AppKit
import SwiftUI

final class MorphDemoDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct TagGlassMorphApp: App {
    @NSApplicationDelegateAdaptor(MorphDemoDelegate.self) private var delegate
    var body: some Scene {
        Window("Tag · Glass Morph — 独立预览", id: "tag-glass-morph") {
            TagGlassMorphDemo()
        }
        .defaultSize(width: 1020, height: 670)
    }
}
