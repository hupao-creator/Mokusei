import AppKit
import SwiftUI

final class MaterialDemoDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct MokuGradientMaterialApp: App {
    @NSApplicationDelegateAdaptor(MaterialDemoDelegate.self) private var delegate
    var body: some Scene {
        Window("Moku · 渐变玻璃材质预览", id: "moku-gradient") {
            MokuGradientDemo()
        }
        .defaultSize(width: 1180, height: 800)
        .windowResizability(.contentMinSize)
    }
}
