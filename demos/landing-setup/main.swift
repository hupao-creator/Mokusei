import AppKit
import SwiftUI
import MokuseiCore
@testable import MokuseiUI

private struct ReplayFailure: Error, CustomStringConvertible { let description: String }

@MainActor private func wait(_ message: String, until condition: () -> Bool) async throws {
    for _ in 0..<300 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw ReplayFailure(description: message)
}

private struct DemoControls: View {
    @Bindable var fixture: SetupFixture
    var resize: (CGSize) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Landing setup").font(.system(size: 22, weight: .medium))
            Text("原生交互 demo · 示例数据").font(.system(size: 12)).foregroundStyle(.secondary)
            Divider()
            Button("重新开始 · 发现三个 Agent") { fixture.reset() }
            Button("重新开始 · 没有 Agent") { fixture.reset(empty: true) }
            Button("模拟安装完成 · 只有 Codex") { fixture.reset(onlyCodex: true) }
            Divider()
            Toggle("深色外观", isOn: Binding(get: { fixture.landing.dark }, set: { fixture.landing.dark = $0 }))
            Toggle("高对比背景检查", isOn: $fixture.contrastBackdrop)
            HStack {
                Button("宽窗口") { resize(.init(width: 1000, height: 800)) }
                Button("紧凑窗口") { resize(.init(width: 620, height: 760)) }
            }
            Divider()
            Text("当前选择").font(.system(size: 12, weight: .medium))
            Text("Host  ·  \(fixture.host.name)")
            Text("Targets  ·  \(fixture.available.filter { fixture.targets.contains($0) }.map(\.name).joined(separator: "、"))")
            Text("Tag  ·  \(fixture.tag.followsHost ? "跟随 Moku" : fixture.tag.agent.name)")
            Text("Report  ·  \(fixture.report.followsHost ? "跟随 Moku" : fixture.report.agent.name)")
            Text("配置仅保存在内存。安装指南会打开官方网页，检测和任务派发均为模拟。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12)).buttonStyle(.bordered)
        .padding(24).frame(width: 330)
    }
}

@MainActor private final class DemoDelegate {
    let fixture = SetupFixture()
    var window: NSWindow!
    var controls: NSWindow!
    private var clicks: [[String: String]] = []
    var output: URL { URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("evidence") }

    func mount() async {
        guard window == nil else { return }
        do {
            try await wait("Setup window did not mount") { NSApp.windows.contains { $0.identifier?.rawValue == "setup-demo" } }
            window = NSApp.windows.first { $0.identifier?.rawValue == "setup-demo" }!
            window.setContentSize(.init(width: 1000, height: 800))
            window.minSize = .init(width: 620, height: 650)
            window.center(); window.makeKeyAndOrderFront(nil)
            fixture.openControls = { [weak self] in self?.showControls() }
            fixture.landing.openControls = fixture.openControls
            NSApp.activate(ignoringOtherApps: true)

        } catch { print(error); exit(1) }
    }

    func showControls() {
        if controls == nil {
            controls = NSWindow(contentRect: .init(x: 0, y: 0, width: 330, height: 500),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            controls.title = "演示控制"; controls.isReleasedWhenClosed = false
            controls.contentView = NSHostingView(rootView: DemoControls(fixture: fixture, resize: { [weak self] size in
                self?.window.setContentSize(size); self?.window.center(); self?.window.makeKeyAndOrderFront(nil)
            }))
        }
        controls.setFrameTopLeftPoint(.init(x: window.frame.maxX - 120, y: window.frame.maxY - 65))
        controls.makeKeyAndOrderFront(nil)
    }

}

@main @MainActor private struct SetupDemo: App {
    @State private var delegate = DemoDelegate()
    init() {
        do { try prepareIsolatedNativeReplay() }
        catch { print(error); exit(1) }
    }
    var body: some Scene {
        Window("Mokusei Setup Demo", id: "setup-demo") {
            SetupSurface(fixture: delegate.fixture).task { await delegate.mount() }
        }
        .nativeWorkspaceWindowStyle().defaultLaunchBehavior(.presented).defaultSize(width: 1000, height: 800)
        .commands {
            CommandMenu("演示") {
                Button("演示控制…", action: delegate.showControls).keyboardShortcut("d")
                Button("重新开始 · 发现 Agent") { delegate.fixture.reset() }.keyboardShortcut("1")
                Button("重新开始 · 没有 Agent") { delegate.fixture.reset(empty: true) }.keyboardShortcut("2")
                Button("模拟安装 Codex") { delegate.fixture.reset(onlyCodex: true) }.keyboardShortcut("3")
                Divider()
                Toggle("深色外观", isOn: Binding(get: { delegate.fixture.landing.dark }, set: { delegate.fixture.landing.dark = $0 }))
                Toggle("高对比背景检查", isOn: Binding(get: { delegate.fixture.contrastBackdrop }, set: { delegate.fixture.contrastBackdrop = $0 }))
                    .keyboardShortcut("5")
            }
        }
    }
}
