import AppKit
import ScreenCaptureKit
import SwiftUI
@testable import MokuseiUI

private struct ReplayFailure: Error, CustomStringConvertible { let description: String }
@MainActor private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ReplayFailure(description: message) }
}
@MainActor private func wait(_ message: String, until condition: () -> Bool) async throws {
    for _ in 0..<300 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw ReplayFailure(description: message)
}

@MainActor private func editor(in root: NSView) -> NSTextView? {
    if let text = root as? NSTextView, text.isEditable { return text }
    return root.subviews.lazy.compactMap { editor(in: $0) }.first
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
            if CommandLine.arguments.contains("--verify") {
                window.level = .floating
                try await verify()
                finish(ok: true, message: "PASS: mounted setup controls, empty discovery, retry, host/targets, role inheritance, back navigation, native landing and dispatch")
            }
        } catch { finish(ok: false, message: String(describing: error)) }
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

    private func press(_ id: String) async throws {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await wait("Setup window did not acquire focus") { self.window.isKeyWindow && NSApp.isActive }
        try await Task.sleep(for: .milliseconds(100))
        try await wait("Missing mounted control: \(id)") { self.fixture.controlFrames[id] != nil }
        let frame = fixture.controlFrames[id]!
        try require(frame.width > 0 && frame.height > 0, "Empty hit target: \(id)")
        let location = NSPoint(x: frame.midX, y: window.contentView!.bounds.height - frame.midY)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        }
        // Real AppKit hit testing owns the action. Queue mouse-up before mouse-down
        // because native tracking may synchronously wait for the release event.
        NSApp.postEvent(event(.leftMouseUp), atStart: false)
        window.sendEvent(event(.leftMouseDown))
        try await Task.sleep(for: .milliseconds(450))
        clicks.append(["control": id, "frame": NSStringFromRect(frame), "stepAfter": fixture.step.label,
                       "keyWindow": String(window.isKeyWindow), "active": String(NSApp.isActive)])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: clicks, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("interactions.json"))
    }

    private func capture(_ name: String) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        let content = try await SCShareableContent.currentProcess
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw ReplayFailure(description: "Own setup window unavailable")
        }
        let config = SCStreamConfiguration()
        config.width = Int(window.contentView!.bounds.width * window.backingScaleFactor)
        config.height = Int(window.contentView!.bounds.height * window.backingScaleFactor)
        config.showsCursor = false; config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ReplayFailure(description: "Could not encode own-window screenshot")
        }
        try data.write(to: output.appendingPathComponent(name + ".png"))
    }

    private func verify() async throws {
        try await wait("Discovery did not finish") { !self.fixture.scanning }
        try await capture("01-discovery")
        try await press("setup-next")
        try require(fixture.step == .moku, "Discovery did not advance to Moku")
        try await press("host-claude")
        try require(fixture.host == .claude && fixture.targets.contains(.claude), "Host and target must be allowed to overlap")
        try await press("target-codex")
        try require(fixture.targets == [.claude], "Target deselection failed")
        try await press("target-claude")
        try require(fixture.targets == [.claude], "Last target must not be removable")
        try await press("target-opencode")
        try await capture("02-moku")
        try await press("setup-next")
        try require(fixture.step == .tag && fixture.tag.followsHost, "Tag should initially follow Moku")
        try await capture("03-tag-inherit")
        try await press("tag-custom")
        try await press("tag-opencode")
        try await press("tag-inherit")
        try await press("tag-custom")
        try require(fixture.tag.agent == .opencode, "Independent Tag selection was lost")
        try await capture("03b-tag-custom")
        try await press("setup-back")
        try require(fixture.host == .claude && fixture.targets == [.claude, .opencode], "Back navigation lost Moku choices")
        try await press("setup-next")
        try require(!fixture.tag.followsHost && fixture.tag.agent == .opencode, "Returning to Tag lost its draft")
        try await press("setup-next")
        try require(fixture.step == .report && fixture.report.followsHost, "Report configuration leaked from Tag")
        try await capture("04-report")
        try await press("report-custom")
        try await press("report-claude")
        fixture.landing.dark = true
        try await capture("04b-report-dark")
        window.setContentSize(.init(width: 620, height: 760))
        try await capture("04c-report-compact")
        try await press("setup-next")
        try require(fixture.step == .landing, "Setup did not enter landing")
        try require(fixture.landing.dispatchHarness.descriptor.id == "claude", "Demo dispatch did not respect selected Targets")
        try await wait("Production landing composer not mounted") { editor(in: self.window.contentView!) != nil }
        fixture.landing.dark = false
        window.setContentSize(.init(width: 1000, height: 800))
        try await capture("05-landing")
        let input = editor(in: window.contentView!)!
        window.makeFirstResponder(input)
        input.insertText("帮我整理新项目的第一步。", replacementRange: .init(location: 0, length: 0))
        try await wait("Native input did not update production draft") { self.fixture.landing.draft.text == "帮我整理新项目的第一步。" }
        try await capture("05b-native-input")
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        window.sendEvent(event)
        try await wait("Production Return did not dispatch") { self.fixture.landing.running }
        try await wait("Fixture dispatch did not finish") { self.fixture.landing.hasThread }
        try await capture("06-first-task")
        fixture.reset(empty: true)
        try await wait("Empty discovery did not finish") { !self.fixture.scanning }
        try require(fixture.controlFrames["setup-next"] == nil && fixture.step == .discovery, "Empty discovery exposed a continue action")
        try await capture("00-install-guide")
        try await press("rescan")
        try await wait("Retry did not finish") { !self.fixture.scanning }
        try require(fixture.step == .discovery && fixture.installed.isEmpty, "Retry fabricated an installed Agent")
        fixture.reset(onlyCodex: true)
        try await wait("Single Agent discovery did not finish") { !self.fixture.scanning }
        window.setContentSize(.init(width: 620, height: 760))
        try await capture("01b-discovery-compact")
        try await press("setup-next")
        try require(fixture.host == .codex && fixture.targets == [.codex], "Single Agent setup has invalid defaults")
        try await capture("02b-single-agent-compact")
    }

    private func finish(ok: Bool, message: String) {
        let root = Bundle.main.bundleURL.deletingLastPathComponent()
        try? JSONSerialization.data(withJSONObject: ["ok": ok, "message": message], options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("result.json"))
        print(message)
        exit(ok ? 0 : 1)
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
            }
        }
    }
}
