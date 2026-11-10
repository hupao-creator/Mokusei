import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI
import MokuseiCore
import MokuseiHarnessCodex
import MokuseiHarnessClaude
import MokuseiHarnessPi
import MokuseiHarnessOpenCode
import MokuseiPluginAPI
import MokuseiPluginUI
@testable import MokuseiUI

@MainActor @Observable private final class Preview {
    let scene = NativeMokuSceneState()
    let canvas = NativeOverviewCanvasState()
    let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
    var agentTheme = NativeMokuTheme.claude
    var detail = false
    var harness: AnyHarnessPlugin { Self.harness(for: theme) }
    var targetHarness: AnyHarnessPlugin { Self.harness(for: agentTheme) }
    static func harness(for theme: NativeMokuTheme) -> AnyHarnessPlugin {
        switch theme {
        case .claude: AnyHarnessPlugin(ClaudeHarnessPlugin())
        case .pi: AnyHarnessPlugin(PiHarnessPlugin())
        case .opencode: AnyHarnessPlugin(OpenCodeHarnessPlugin())
        default: AnyHarnessPlugin(CodexHarnessPlugin())
        }
    }
    let card = try! composeThreadCard(.standard(identity: .init(), extensions: []), layoutContext: .init(availableCols: 3))
    let note = NativeMokuNote(id: "preview-note", text: "## 本轮进展\n\n新的品牌语言以玻璃球体为起点。输入、对话与笔记沿用各自的布局，由同一层玻璃连续展开。\n\n### 接下来\n\n- 检查展开与收起的节奏\n- 对照浅色与深色背景\n- 确认快速切换时仍然连贯", revision: 1, updatedAt: 1794297600000)
    var theme = NativeMokuTheme.codex
    var dark = false
    var reducedMotion = false
    var running = false
    var selected = "球体"
    var resize: (CGSize) -> Void = { _ in }
    var openControls: () -> Void = {}
    var sequence: Task<Void, Never>?

    func show(_ destination: String) {
        selected = destination
        detail = destination == "Agent 输入"
        scene.readingPanelVisible = detail
        scene.setComposerContext(draft, opensInput: detail, keepsInputOpen: detail)
        scene.setInputOpen(false)
        scene.setNotePanelOpen(false)
        scene.dismissTalk()
        running = false
        switch destination {
        case "Agent 输入": scene.setInputOpen(true)
        case "运行中": running = true
        case "输入": scene.setInputOpen(true)
        case "Note": scene.setNotePanelOpen(true)
        case "Talk":
            scene.receiveTalk(.init(id: JSONText(UUID().uuidString), text: "我已整理好这轮设计方向。你可以先检查预览，再决定下一步。"))
        case "创建 Thread": dispatch(completed: false)
        case "Thread 已启动": dispatch(completed: true)
        default: break
        }
    }
    func dispatch(completed: Bool) {
        let operation: JSONValue = .object([
            "name": .text("create_thread"),
            "arguments": .object(["target": .object([JSONText(theme.rawValue): .object(["model": .text("示例模型"), "thinking": .object(["mode": .text("effort"), "effort": .text("high")])])]),
                                  "prompt": .text("更新 Overview 的玻璃品牌。")]),
            "completedAt": completed ? .integer(1) : .null,
            "result": completed ? .object(["ok": .bool(true), "threadId": .text("preview-thread")]) : .null,
        ])
        let dispatch = NativeMokuDispatch(operation: operation, executionIsActive: !completed)!
        scene.receiveTalk(.init(id: JSONText(UUID().uuidString), text: dispatch.sentence(chinese: true), dispatch: dispatch))
    }
    func play() {
        sequence?.cancel()
        sequence = Task {
            for destination in ["球体", "运行中", "输入", "球体", "Talk", "球体", "Note", "球体", "创建 Thread", "Thread 已启动", "球体"] {
                guard !Task.isCancelled else { return }
                show(destination)
                do { try await Task.sleep(for: .milliseconds(destination == "球体" ? 1100 : destination == "运行中" ? 7500 : 2200)) } catch { return }
            }
        }
    }
}

private struct Surface: View {
    let model: Preview
    private let titles = ["整理品牌视觉", "完善 Overview 交互", "检查原生过渡"]
    private let excerpts = ["统一 Moku 的蓝色玻璃语言，让不同状态自然衔接。", "保留输入、笔记和任务通知的熟悉布局。", "检查展开、收起与快速反向操作时的连续性。"]
    var body: some View {
        NativeMokuScene(state: model.scene) {
            GeometryReader { geometry in
                let viewport = NativeOverviewWorkspaceView.viewport(in: geometry.size, hasFilters: true, hasDock: true)
                NativeOverviewCanvas(items: (0..<3).map {
                    .init(id: "preview-\($0)", columns: model.card.size.cols, rows: model.card.size.rows)
                }, sceneKey: "rebrand", state: model.canvas,
                    toolbarBottom: viewport.toolbarBottom, bottomReservedHeight: viewport.bottomReservedHeight,
                    cloudAnimationsEnabled: false, interactionPaused: model.scene.interactionPaused) { item in
                    let index = Int(item.id.replacingOccurrences(of: "preview-", with: "")) ?? 0
                    HarnessThreadCard(identity: .init(title: titles[index], harness: .init(brandKey: "codex", label: "Codex", logoSource: model.harness.logoSource),
                        model: "GPT-6", effort: "High", excerpt: excerpts[index]), presentation: model.card,
                        status: .init(kind: .running, label: "进行中"), emoji: ["🫧", "🌊", "✦"][index], harnessLogo: model.harness.logo(size: 12))
                }
                .overlay(alignment: .top) {
                    NativeOverviewChrome(filters: [.init(tag: "Mokusei", scope: "demo", count: 3, isDirectory: true)],
                        onTagChange: { _ in }, onSettings: model.openControls)
                }
            }
        } thread: { EmptyView() } dock: {
            NativeMokuDock(state: model.scene, draft: model.draft, cwd: "/fixture",
                threadID: model.detail ? "preview-agent" : nil, threadTitle: model.detail ? "Agent 输入配色预览" : nil,
                threadHarness: model.detail ? model.targetHarness : nil, onThreadClose: { model.show("球体") },
                mode: model.running ? .running : .idle, running: model.running, note: model.note,
                loadMentionDirectories: { [NativeComposerDirectory(name: "Mokusei", path: "/fixture/Mokusei")] },
                onSend: { _ in
                    // Let the actual composer finish its submission before fixture publication.
                    try await Task.sleep(for: .milliseconds(450))
                    model.show("创建 Thread")
                }, onCancel: { model.running = false })
        } settings: { EmptyView() }
        .overlay(alignment: .topLeading) { NativeWindowNavigationView(action: nil) }
        .coordinateSpace(name: "workspace")
        .modifier(NativeWorkspaceWindowSurface())
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        .environment(\.nativeMokuTheme, model.theme)
        .environment(\.scenePhase, .active)
        .transaction { if model.reducedMotion { $0.animation = nil; $0.disablesAnimations = true } }
        .preferredColorScheme(model.dark ? .dark : .light)
    }
}

private struct Controls: View {
    let model: Preview
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Moku · Glass").font(.system(size: 20, weight: .semibold))
            Text("球体直接成为每一种形态").foregroundStyle(.secondary)
            Picker("配色", selection: Bindable(model).theme) {
                ForEach(NativeMokuTheme.allCases.filter { $0 != .neutral }, id: \.self) { theme in Text(theme.previewLabel).tag(theme) }
            }.pickerStyle(.segmented)
            if model.detail {
                Picker("Agent Harness", selection: Bindable(model).agentTheme) {
                    ForEach(NativeMokuTheme.allCases.filter { $0 != .neutral }, id: \.self) { theme in Text(theme.previewLabel).tag(theme) }
                }.pickerStyle(.segmented)
            }
            Divider()
            ForEach(["球体", "运行中", "输入", "Talk", "Note", "创建 Thread", "Thread 已启动", "Agent 输入"], id: \.self) { state in
                Button { model.sequence?.cancel(); model.show(state) } label: {
                    HStack { Text(state); Spacer(); if model.selected == state { Image(systemName: "checkmark") } }
                    .frame(maxWidth: .infinity, minHeight: 23)
                }.buttonStyle(.bordered)
            }
            Button("连续演示所有过渡") { model.play() }.buttonStyle(.borderedProminent)
            Divider()
            Toggle("深色背景", isOn: Bindable(model).dark)
            Toggle("禁用预览过渡", isOn: Bindable(model).reducedMotion)
            HStack {
                Button("标准窗口") { model.resize(.init(width: 1180, height: 790)) }
                Button("窄窗口") { model.resize(.init(width: 480, height: 600)) }
            }
            Text("独立原生预览 · 内存示例数据\n点击球体输入，Escape 收起；向上滑动打开 Note。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.toggleStyle(.switch).padding(22).frame(width: 290)
            .tint(Color(red: 0.25, green: 0.48, blue: 0.95))
    }
}

@MainActor private final class Delegate: NSObject, NSApplicationDelegate {
    let model = Preview()
    var window: NSWindow!
    var controls: NSPanel!
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: .init(x: 60, y: 100, width: 1180, height: 790),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Moku · Orb Rebrand Preview"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Surface(model: model))
        model.resize = { [weak self] in self?.window.setContentSize($0) }
        controls = NSPanel(contentRect: .init(x: 1260, y: 100, width: 334, height: 650),
            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        controls.title = "Rebrand · 预览控制"
        controls.isReleasedWhenClosed = false
        controls.contentView = NSHostingView(rootView: ScrollView { Controls(model: model) }.frame(width: 334, height: 650))
        model.openControls = { [weak self] in self?.controls.makeKeyAndOrderFront(nil) }
        window.makeKeyAndOrderFront(nil)
        if !CommandLine.arguments.contains("--capture") && !CommandLine.arguments.contains("--capture-palettes") { controls.orderFront(nil) }
        NSApp.activate()
        if CommandLine.arguments.contains("--capture") || CommandLine.arguments.contains("--capture-palettes") {
            Task {
                do { try await capture() }
                catch { try? String(describing: error).write(to: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("capture-error.txt"), atomically: true, encoding: .utf8) }
                NSApp.terminate(nil)
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func capture() async throws {
        let evidence = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("evidence")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        func pause(_ ms: Int) async throws { try await Task.sleep(for: .milliseconds(ms)) }
        func shot(_ name: String) async throws {
            guard let target = try await SCShareableContent.currentProcess.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                throw NSError(domain: "Preview window unavailable", code: 1)
            }
            let configuration = SCStreamConfiguration()
            configuration.width = Int(window.frame.width * 2); configuration.height = Int(window.frame.height * 2)
            configuration.ignoreShadowsSingleWindow = true; configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: evidence.appendingPathComponent(name + ".png"))
        }
        try await pause(1000)
        if CommandLine.arguments.contains("--capture-palettes") {
            for theme in NativeMokuTheme.allCases where theme != .neutral {
                model.theme = theme
                for dark in [false, true] {
                    model.dark = dark
                    for (index, state) in [(0, "球体"), (1, "输入"), (3, "Talk"), (5, "Note"), (7, "创建 Thread")] {
                        model.show(state); try await pause(800)
                        try await shot("\(theme.rawValue)-\(dark ? "dark" : "light")-\(index)-settled")
                    }
                }
            }
            model.theme = .codex
            for theme in NativeMokuTheme.allCases where theme != .neutral {
                model.agentTheme = theme; model.show("Agent 输入")
                try await pause(850); try await shot("agent-\(theme.rawValue)")
            }
            model.show("球体"); try await pause(850); try await shot("agent-return-moku")
            return
        }
        for dark in [false, true] {
            model.dark = dark
            let theme = dark ? "dark" : "light"
            for (index, state) in ["球体", "输入", "球体", "Talk", "球体", "Note", "球体", "创建 Thread", "Thread 已启动"].enumerated() {
                model.show(state)
                if !dark && [1, 2, 5, 6].contains(index) {
                    for frame in 0..<5 { try await pause(55); try await shot("\(theme)-\(index)-motion-\(frame)") }
                }
                try await pause(850); try await shot("\(theme)-\(index)-settled")
            }
        }
        model.show("运行中"); try await pause(1800); try await shot("running-rest")
        try await pause(2500); try await shot("running-orbit")
        model.dark = false; try await pause(500); try await shot("running-light")
        model.show("球体"); try await pause(700)
        model.show("输入"); try await pause(100); model.show("球体"); try await pause(90); model.show("输入")
        try await pause(700); try await shot("reversal-settled")
        window.setContentSize(.init(width: 480, height: 600))
        for state in ["球体", "输入", "Note", "Talk", "创建 Thread"] {
            model.show(state); try await pause(850); try await shot("narrow-\(state)")
        }
    }
}

@main private struct App {
    @MainActor static func main() throws {
        try prepareIsolatedNativeReplay()
        NativeTypography.registerFonts()
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let delegate = Delegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

private extension NativeMokuTheme {
    var previewLabel: String {
        switch self { case .codex: "Codex"; case .opencode: "OpenCode"; case .claude: "CC"; case .pi: "Pi"; case .neutral: "Neutral" }
    }
}
