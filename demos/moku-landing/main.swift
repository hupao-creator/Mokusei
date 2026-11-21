import AppKit
import Observation
import SwiftUI
import ChiefCore
import ChiefHarnessCodex
import ChiefPluginAPI
@testable import ChiefPluginUI
@testable import ChiefUI

private struct Controls: View {
    @Bindable var fixture: LandingFixture
    let resize: (CGSize) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Moku Landing").font(.system(size: 22, weight: .semibold))
            Text("原生交互预览").font(.subheadline).foregroundStyle(.secondary)
            Divider()
            Text(fixture.status).font(.system(size: 13)).frame(minHeight: 34, alignment: .leading)
            Picker("发送结果", selection: $fixture.outcome) {
                ForEach(LandingFixture.Outcome.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Button("重置为空工作区", action: fixture.reset)
            Button("演示首次成功派发") { fixture.simulate(.success) }.disabled(fixture.draft.submitting)
            Button("演示创建前失败") { fixture.simulate(.failure) }.disabled(fixture.draft.submitting)
            Button("归档全部会话", action: fixture.archive)
            Button("筛选无结果", action: fixture.filterToEmpty)
            Button("添加示例附件与目录") { Task { await fixture.addContext() } }
            Divider()
            Toggle("对照原来的空页面", isOn: $fixture.original)
            Toggle("深色外观", isOn: $fixture.dark)
            HStack {
                Button("宽窗口") { resize(.init(width: 1100, height: 720)) }
                Button("窄窗口") { resize(.init(width: 480, height: 620)) }
            }
            Text("在主窗口输入后按 Return 发送。派发结果为模拟数据。").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .buttonStyle(.bordered)
        .padding(22).frame(width: 290)
    }
}

private struct Failure: Error, CustomStringConvertible { let description: String }

@MainActor private func wait(_ message: String, until predicate: () -> Bool) async throws {
    for _ in 0..<300 {
        for window in NSApp.windows {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw Failure(description: message)
}

@MainActor private final class Delegate {
    let fixture = LandingFixture()
    var window: NSWindow!
    var controls: NSWindow!
    func mount() async {
        guard window == nil else { return }
        do {
            try await wait("SwiftUI window did not mount") {
                NSApp.windows.contains { $0.identifier?.rawValue == "landing-demo" }
            }
        } catch { print(error); exit(1) }
        window = NSApp.windows.first { $0.identifier?.rawValue == "landing-demo" }!
        window.setContentSize(.init(width: 1100, height: 720))
        window.minSize = .init(width: 360, height: 360)
        window.center(); window.makeKeyAndOrderFront(nil)
        fixture.openControls = { [weak self] in self?.showControls() }
        controls = NSWindow(contentRect: .init(x: 100, y: 100, width: 290, height: 590),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        controls.title = "演示控制"; controls.isReleasedWhenClosed = false
        controls.contentView = NSHostingView(rootView: Controls(fixture: fixture, resize: { [weak self] size in
            self?.window.setContentSize(size); self?.window.center(); self?.window.makeKeyAndOrderFront(nil)
        }))
        NSApp.activate(ignoringOtherApps: true)

    }
    func showControls() {
        controls.setFrameTopLeftPoint(.init(x: max(20, window.frame.maxX - 100), y: window.frame.maxY - 50))
        controls.makeKeyAndOrderFront(nil)
    }

}

@main @MainActor private struct Demo: App {
    @State private var delegate = Delegate()
    init() {
        do { try prepareIsolatedNativeReplay() }
        catch { print(error); exit(1) }
    }
    var body: some Scene {
        Window("Moku Landing Demo", id: "landing-demo") {
            LandingSurface(fixture: delegate.fixture).task { await delegate.mount() }
        }
        .nativeWorkspaceWindowStyle().defaultLaunchBehavior(.presented).defaultSize(width: 1100, height: 720)
        .commands {
            CommandMenu("演示") {
                Button("演示控制…") { delegate.showControls() }.keyboardShortcut("d")
                Button("重置为空工作区") { delegate.fixture.reset() }.keyboardShortcut("1")
                Button("演示首次成功派发") { delegate.fixture.simulate(.success) }.keyboardShortcut("2")
                Button("演示创建前失败") { delegate.fixture.simulate(.failure) }.keyboardShortcut("3")
                Button("归档全部会话") { delegate.fixture.archive() }.keyboardShortcut("4")
            }
        }
    }
}
