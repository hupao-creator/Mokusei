import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import MokuseiHarnessCodex
import MokuseiUI

@MainActor @Observable private final class Preview {
    let scene = NativeMokuSceneState()
    let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
    let client: RuntimeClient
    let host: NativeHarnessHost
    let current: HarnessThread
    let archive: HarnessThread
    var appearance = "light"
    var running = false
    var resize: (CGSize) -> Void = { _ in }
    var scheme: ColorScheme? { appearance == "system" ? nil : appearance == "dark" ? .dark : .light }

    init() throws {
        client = RuntimeClient(profile: try RuntimeProfile(dataDirectory:
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("profile")))
        func thread(_ id: JSONText, archived: Bool) throws -> HarnessThread {
            try HarnessThread(id: id, harnessID: "codex", revision: 0,
                sessionState: .null, observation: .init(), cwd: "/fixture", settings: .object([:]),
                createdAt: 1, updatedAt: 2, title: archived ? "Previous Moku" : "Moku", tags: [],
                archived: archived ? true : nil, moku: archived ? nil : true, mokuHistory: archived, transcript: .array([]))
        }
        current = try thread("moku", archived: false)
        archive = try thread("archive", archived: true)
        let threads = [current, archive]
        host = NativeHarnessHost(client: client, registry: try HarnessPluginRegistry([AnyHarnessPlugin(CodexHarnessPlugin())]),
            currentThread: { id in threads.first { $0.id == id } },
            callbacks: .init(openExternal: { _ in }, openFollowUp: { _, _ in }, onError: { _ in }))
    }
    // Supply private content at the real subscription boundary. Never start the
    // client: this fixture has no Runtime, transport, model or user data access.
    func feedContent() async {
        for await event in await client.events() {
            if Task.isCancelled { break }
            if case let .threadContent(id, _) = event {
                host.receive(.threadContent(subscriptionId: id, state: .ready(Self.content)))
            }
        }
    }
    static let content: JSONValue = {
        let answer = "## 历史展示与应用主题\n\n阅读卡片与 Moku bar 分开。切换浅色、深色或跟随系统时，正文、菜单和关闭按钮使用应用主题。\n\n- 历史会话继续只读\n- 当前会话保留草稿与目录选择\n- Close 返回原来的阅读页面\n\n`NativeMokuThreadView` 继续使用共享 reader。"
        let turns: [JSONValue] = (0..<3).map { index in
            .object(["executionId": .text("execution-\(index)"), "createdAt": .integer(1), "updatedAt": .integer(2),
                "finishedAt": .integer(2), "status": .text("completed"), "answer": .text(answer), "reasoning": .text(""),
                "messages": .array([]), "plan": .array([]), "activities": .array([]), "interactions": .array([]), "notices": .array([]),
                "timeline": .array([.object(["id": .text("answer-\(index)"), "kind": .text("assistant"), "createdAt": .integer(2),
                    "itemId": .text("message-\(index)"), "content": .text(answer), "status": .text("complete")])])])
        }
        return .object(["schema": .text("mokusei.harness.codex.thread.v1"), "updatedAt": .integer(2),
            "backgroundTerminals": .array([]), "turns": .array(turns)])
    }()
}

private struct Surface: View {
    let model: Preview
    var body: some View {
        NativeMokuScene(state: model.scene) {
            NativePalette.thread.canvas.swiftUI.overlay {
                Button("打开 Moku 历史") { model.scene.setMokuOpen(true) }
            }
        } thread: {
            NativeMokuThreadView(harnessHost: model.host, thread: model.current, draft: model.draft,
                archiveThreads: [model.archive], running: model.running,
                loadMentionDirectories: { [.init(name: "Mokusei", path: "/fixture/Mokusei")] },
                focusEnabled: model.scene.mokuOpen,
                onNavigationChange: { _ in }, onBack: { model.scene.closeHistory() },
                onSend: { _ in model.running = true }, onCancel: { model.running = false })
                .environment(\.nativeReadingNavigation, nil)
        } dock: {
            NativeMokuDock(state: model.scene, draft: model.draft, cwd: "/fixture",
                mode: model.running ? .running : .idle, running: model.running,
                note: .init(id: "note", text: "## Moku Note\n\n保留当前工作进展。点击 Moku history 打开生产历史页面。", revision: 1, updatedAt: 2),
                onSend: { _ in model.running = true }, onCancel: { model.running = false })
        } settings: { EmptyView() }
        .preferredColorScheme(model.scheme)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        .task { await model.feedContent() }
    }
}

private struct Controls: View {
    let model: Preview
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("主题", selection: Bindable(model).appearance) {
                Text("浅色").tag("light"); Text("深色").tag("dark"); Text("跟随系统").tag("system")
            }
            Button("打开历史") { model.scene.setMokuOpen(true) }
            Button("关闭返回") { model.scene.closeHistory() }
            Button("打开 Note") { model.scene.closeHistory(); model.scene.setNotePanelOpen(true) }
            Toggle("运行中 / Stop", isOn: Bindable(model).running)
            ForEach([CGSize(width: 1200, height: 800), CGSize(width: 760, height: 600), CGSize(width: 420, height: 420)], id: \.width) { size in
                Button("\(Int(size.width)) × \(Int(size.height))") { model.resize(size) }
            }
        }.padding(16).frame(width: 220)
    }
}

@MainActor private final class Delegate: NSObject, NSApplicationDelegate {
    let model: Preview
    var window: NSWindow!
    var controls: NSPanel!
    init(model: Preview) { self.model = model }
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: .init(x: 100, y: 100, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Moku history · production preview"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Surface(model: model))
        model.resize = { [weak self] in self?.window.setContentSize($0) }
        controls = NSPanel(contentRect: .init(x: 1320, y: 200, width: 250, height: 320),
            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        controls.title = "Fixture controls"
        controls.contentView = NSHostingView(rootView: Controls(model: model))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        model.scene.setMokuOpen(true)
        if CommandLine.arguments.contains("--capture") {
            Task {
                do { try await capture() }
                catch { try? String(describing: error).write(to: root.appendingPathComponent("capture-error.txt"), atomically: true, encoding: .utf8) }
                NSApp.terminate(nil)
            }
        } else { controls.orderFront(nil) }
    }
    var root: URL { Bundle.main.bundleURL.deletingLastPathComponent() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    private func capture() async throws {
        let output = root.appendingPathComponent("evidence")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for appearance in ["light", "dark", "system"] {
            model.appearance = appearance
            for size in [CGSize(width: 1200, height: 800), CGSize(width: 760, height: 600), CGSize(width: 420, height: 420)] {
                window.setContentSize(size)
                try await Task.sleep(for: .milliseconds(1000))
                try await shot("\(appearance)-\(Int(size.width))", output: output)
            }
        }
        window.setContentSize(.init(width: 1200, height: 800))
        model.scene.closeHistory()
        try await Task.sleep(for: .milliseconds(800))
        model.scene.setNotePanelOpen(true)
        try await Task.sleep(for: .milliseconds(800))
        try await shot("note-return", output: output)
    }
    private func shot(_ name: String, output: URL) async throws {
        guard let target = try await SCShareableContent.currentProcess.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw NSError(domain: "Preview window unavailable", code: 1)
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * 2); configuration.height = Int(window.frame.height * 2)
        configuration.ignoreShadowsSingleWindow = true; configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration)
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            .write(to: output.appendingPathComponent(name + ".png"))
    }
}

@main private struct App {
    @MainActor static func main() throws {
        try prepareIsolatedNativeReplay()
        NativeTypography.registerFonts()
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = try Delegate(model: Preview()); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
