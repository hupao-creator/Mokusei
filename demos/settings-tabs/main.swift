import AppKit
import ScreenCaptureKit
import SwiftUI
import MokuseiCore
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
            Toggle("关闭界面过渡", isOn: $fixture.reduceMotion)
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
            if CommandLine.arguments.contains("--verify") {
                window.level = .floating
                try await verify()
                finish(ok: true, message: "PASS: native tab clicks, direct Report entry, shared Moku map, independent/inherited profiles, retained selections, keyboard tabs, close gate, light/dark/compact/accessibility renders")
            }
        } catch { finish(ok: false, message: String(describing: error)) }
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

    private func press(_ id: String) async throws {
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await wait("Demo did not acquire focus") { self.window.isKeyWindow && NSApp.isActive }
        try await wait("Missing mounted control: \(id)") { self.fixture.setup.controlFrames[id] != nil }
        try await Task.sleep(for: .milliseconds(100))
        let frame = fixture.setup.controlFrames[id]!
        try require(frame.width > 0 && frame.height > 0, "Empty hit target: \(id)")
        try require(window.contentView!.bounds.contains(frame), "Control outside window: \(id)")
        let location = NSPoint(x: frame.midX, y: window.contentView!.bounds.height - frame.midY)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        }
        NSApp.postEvent(event(.leftMouseUp), atStart: false)
        window.sendEvent(event(.leftMouseDown))
        try await Task.sleep(for: .milliseconds(400))
        clicks.append(["control": id, "frame": NSStringFromRect(frame), "tabAfter": fixture.tab.rawValue])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: clicks, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("interactions.json"))
    }

    private func activateMap(_ field: String) async throws {
        let context = fixture.setup.mapContext
        let id = "moku." + field
        try await wait("Map control did not mount: \(id)") {
            self.fixture.setup.mapInteractions.snapshot(context: context).contains { $0["id"]?.stringValue == id }
        }
        let control = fixture.setup.mapInteractions.snapshot(context: context).first { $0["id"]?.stringValue == id }!
        try fixture.setup.mapInteractions.perform(id: id, handle: control["handle"]!.stringValue!,
            operation: "activate", value: .null, context: context)
        try await Task.sleep(for: .milliseconds(1150))
    }

    private func capture(_ name: String) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(450))
        let content = try await SCShareableContent.currentProcess
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw ReplayFailure(description: "Own Settings window unavailable")
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
        try await wait("Agent fixture did not load") { self.fixture.setup.coordination.installationLoadState == .loaded }
        try await wait("Panel did not mount") { self.fixture.panelFrame.width > 0 }
        try require(fixture.setup.controlFrames.keys.filter { $0.hasPrefix("tab-") }.count == 4, "Not all tabs are directly available")
        try require(fixture.setup.controlFrames["setup-next"] == nil && fixture.setup.controlFrames["setup-back"] == nil,
                    "Settings exposed onboarding step navigation")
        try await capture("01-moku-light")
        // Jump to the final role before ever visiting Tag.
        try await press("tab-report")
        try require(fixture.tab == .report, "Report was not directly accessible")
        try await capture("03-report-light")
        try await Task.sleep(for: .milliseconds(4800))
        try await capture("03a-report-diagram")
        try await Task.sleep(for: .milliseconds(6500))
        try await capture("03aa-report-retained")
        try await press("report-custom")
        try await press("report-claude")
        try require(!fixture.setup.report.followsHost && fixture.setup.report.agent == .claude, "Report independent choice failed")
        try await capture("03b-report-independent")
        try await press("tab-tag")
        try await press("tag-custom")
        try await press("tag-opencode")
        try await press("tag-inherit")
        try await press("tag-custom")
        try require(fixture.setup.tag.agent == .opencode, "Tag independent choice was not retained across inheritance")
        try await capture("02-tag-light")
        try await Task.sleep(for: .milliseconds(3500))
        try await capture("02a-tag-organized")
        try await Task.sleep(for: .milliseconds(6500))
        try await capture("02aa-tag-retained")
        try await press("tab-moku")
        try await activateMap("host.claude")
        try await activateMap("target.codex")
        try require(fixture.setup.host == .claude && fixture.setup.targets == [.claude], "Shared Moku bindings failed")
        let last = fixture.setup.mapInteractions.snapshot(context: fixture.setup.mapContext).first { $0["id"] == .text("moku.target.claude") }
        try require(last?["enabled"] == .bool(false), "Last dispatch target could be removed")
        try await activateMap("target.opencode")
        try await press("tab-report")
        try require(!fixture.setup.report.followsHost && fixture.setup.report.agent == .claude, "Report changed while visiting other tabs")
        try await press("tab-tag")
        try require(!fixture.setup.tag.followsHost && fixture.setup.tag.agent == .opencode, "Tag changed while visiting other tabs")
        fixture.setup.landing.dark = true
        try await capture("02b-tag-dark")
        try await press("tab-report")
        try await capture("03c-report-dark")
        try await press("tab-moku")
        try await capture("01b-moku-dark")
        fixture.setup.contrastBackdrop = true
        try await capture("05-glass-dark-backdrop")
        fixture.setup.landing.dark = false
        try await capture("05b-glass-light-backdrop")
        fixture.opaque = true
        try await capture("05c-reduce-transparency")
        fixture.opaque = false; fixture.setup.contrastBackdrop = false
        try await press("tab-general")
        try await capture("04-general-light")
        window.setContentSize(.init(width: 620, height: 760))
        try await press("tab-tag")
        try await capture("06-tag-compact")
        try require(fixture.panelFrame.minX >= 20 && fixture.panelFrame.maxX <= 600, "Compact panel escaped viewport")
        let arrow = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: arrow, charactersIgnoringModifiers: arrow,
            isARepeat: false, keyCode: 124)!
        window.sendEvent(key)
        try await wait("Right arrow did not select next header tab") { self.fixture.tab == .report }
        fixture.reduceMotion = true
        try await capture("06b-report-compact-reduce-motion")
        fixture.setup.coordination.draft.composing = true
        try await press("settings-close")
        try require(fixture.open, "Close ignored composition gate")
        fixture.setup.coordination.draft.composing = false
        try await press("settings-close")
        try require(!fixture.open, "Close did not dismiss Settings")
        fixture.open = true
        try await press("tab-tag")
        try require(fixture.setup.tag.agent == .opencode, "Reopening lost independent configuration")
    }

    private func finish(ok: Bool, message: String) {
        let root = Bundle.main.bundleURL.deletingLastPathComponent()
        try? JSONSerialization.data(withJSONObject: ["ok": ok, "message": message], options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("result.json"))
        print(message)
        exit(ok ? 0 : 1)
    }
}

@main @MainActor private struct SettingsTabsDemo: App {
    @State private var delegate = DemoDelegate()
    init() {
        do { try prepareIsolatedNativeReplay() }
        catch { print(error); exit(1) }
    }
    var body: some Scene {
        Window("Mokusei Settings · Tabs Preview", id: "settings-tabs-demo") {
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
