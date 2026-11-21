import AppKit
import SwiftUI
import ChiefCore
@testable import ChiefUI

private struct ReplayFailure: Error, CustomStringConvertible { let description: String }

@MainActor private func wait(_ message: String, until condition: () -> Bool) async throws {
    for _ in 0..<300 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw ReplayFailure(description: message)
}

private struct DemoControls: View {
    @Bindable var fixture: SettingsTabsFixture
    var resize: (CGSize) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings tabs").font(.system(size: 22, weight: .medium))
            Text("原生交互预览 · 内存示例配置").font(.system(size: 12)).foregroundStyle(.secondary)
            Divider()
            Toggle("深色外观", isOn: Binding(get: { fixture.setup.landing.dark }, set: { fixture.setup.landing.dark = $0 }))
            Toggle("高对比背景", isOn: Binding(get: { fixture.setup.contrastBackdrop }, set: { fixture.setup.contrastBackdrop = $0 }))
            Toggle("面板实色回退", isOn: $fixture.opaque)
            HStack {
                Button("宽窗口") { resize(.init(width: 1080, height: 840)) }
                Button("窄窗口") { resize(.init(width: 620, height: 760)) }
            }
            Divider()
            Text("⌘0 通用 · ⌘1 Moku · ⌘2 Tag · ⌘3 Report")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("三个配置页直接访问，选择在切换后保留。关闭面板后，点击右上角设置入口可重新打开。")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }.padding(24).frame(width: 340).buttonStyle(.bordered)
    }
}

@MainActor private final class DemoDelegate {
    let fixture = SettingsTabsFixture()
    var window: NSWindow!
    private var controls: NSWindow?
    private var clicks: [[String: String]] = []
    private var output: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("evidence")
    }

    func mount() async {
        guard window == nil else { return }
        do {
            try await wait("Settings window did not mount") { NSApp.windows.contains { $0.identifier?.rawValue == "settings-tabs-demo" } }
            window = NSApp.windows.first { $0.identifier?.rawValue == "settings-tabs-demo" }!
            window.setContentSize(.init(width: 1080, height: 840))
            window.minSize = .init(width: 620, height: 650)
            window.center(); window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

        } catch { print(error); exit(1) }
    }

    func showControls() {
        if controls == nil {
            let controls = NSWindow(contentRect: .init(x: 0, y: 0, width: 340, height: 420),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            controls.title = "演示控制"; controls.isReleasedWhenClosed = false
            controls.contentView = NSHostingView(rootView: DemoControls(fixture: fixture, resize: { [weak self] size in
                self?.window.setContentSize(size); self?.window.center(); self?.window.makeKeyAndOrderFront(nil)
            }))
            self.controls = controls
        }
        controls?.setFrameTopLeftPoint(.init(x: window.frame.maxX - 100, y: window.frame.maxY - 65))
        controls?.makeKeyAndOrderFront(nil)
    }

}

@main @MainActor private struct SettingsTabsDemo: App {
    @State private var delegate = DemoDelegate()
    init() {
        do { try prepareIsolatedNativeReplay() }
        catch { print(error); exit(1) }
    }
    var body: some Scene {
        Window("Chief Settings · Tabs Preview", id: "settings-tabs-demo") {
            SettingsTabsSurface(fixture: delegate.fixture).task { await delegate.mount() }
        }
        .nativeWorkspaceWindowStyle().defaultLaunchBehavior(.presented).defaultSize(width: 1080, height: 840)
        .commands {
            CommandMenu("演示") {
                Button("演示控制…", action: delegate.showControls).keyboardShortcut("d")
                Divider()
                Button("General") { delegate.fixture.tab = .general; delegate.fixture.open = true }.keyboardShortcut("0")
                Button("Moku") { delegate.fixture.tab = .moku; delegate.fixture.open = true }.keyboardShortcut("1")
                Button("Tag") { delegate.fixture.tab = .tag; delegate.fixture.open = true }.keyboardShortcut("2")
                Button("Report") { delegate.fixture.tab = .report; delegate.fixture.open = true }.keyboardShortcut("3")
                Divider()
                Toggle("深色外观", isOn: Binding(get: { delegate.fixture.setup.landing.dark }, set: { delegate.fixture.setup.landing.dark = $0 }))
                    .keyboardShortcut("4")
                Toggle("高对比背景", isOn: Binding(get: { delegate.fixture.setup.contrastBackdrop }, set: { delegate.fixture.setup.contrastBackdrop = $0 }))
                    .keyboardShortcut("5")
            }
        }
    }
}
