import AppKit
import Observation
import SwiftUI
import MokuseiCore
import MokuseiPluginUI
@testable import MokuseiUI

enum ThinkingStudy: String, CaseIterable {
    case arc = "胶囊 + Arc"
    case electron = "Electron · 原始阅读"
    case capsule = "Native · 胶囊环流"
}

@MainActor @Observable final class ThinkingFixture {
    let scene = NativeMokuSceneState()
    let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
    var study = ThinkingStudy.arc
    var role = HistoricalResidentRole.reasoning
    var dark = false
    var paused = false
    var streaming = true
    var batch = false
    var gaze = true
    var source = "先看看已有实现，"
    var segment = 0
    var index = 0
    var resetID = 0
    var customText = ""
    private let fragments = [
        "确认这个表情", "如何表达思考。", "新的文字", "顺着圆弧进入，", "已经读过的内容", "慢慢退出。",
        "眼睛会稍作停留，", "偶尔回看一个词，", "身体随后轻轻跟上。", "输入停止时，", "队列仍然按顺序读完，",
        "最后停在最新的文字。", "这段节奏来自", "Electron 时期的设计。", "切换到胶囊版本，", "可以看到后来加入的", "连续环流。"
    ]
    var inputFinished: Bool { index == fragments.count }
    var content: HistoricalReasoningContent {
        // The historical display tail counts code points without splitting a grapheme.
        var count = 0
        let tail = source.reversed().prefix { character in
            count += character.unicodeScalars.count
            return count <= 56
        }.reversed()
        return .init(text: String(tail), sourceText: source, sourceOffset: 0,
                     segmentKey: "demo-\(segment)", options: .init(gaze: gaze))
    }
    func next() {
        guard index < fragments.count else { streaming = false; return }
        let end = min(fragments.count, index + (batch ? 5 : 1))
        source += fragments[index..<end].joined(); index = end
        if index == fragments.count { streaming = false }
    }
    func replay() {
        segment += 1; index = 0; source = "先看看已有实现，"
        role = .reasoning; paused = false; streaming = true; resetID += 1
        scene.setInputOpen(false)
    }
    func shortText() {
        segment += 1; streaming = false; source = "让我想一想。"; role = .reasoning
    }
    func replace() {
        guard !customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        segment += 1; streaming = false; source = customText; role = .reasoning
    }
}

private struct ThinkingDemoView: View {
    @Bindable var fixture: ThinkingFixture
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var motion: Bool { !fixture.paused && !reduceMotion }
    private var background: Color { fixture.dark ? Color(red: 0.075, green: 0.085, blue: 0.075) : Color(red: 0.962, green: 0.958, blue: 0.938) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Moku").font(.system(size: 30, weight: .semibold)).tracking(-1)
                Text("Thinking study").font(.system(size: 17)).foregroundStyle(.secondary)
                Spacer()
                Toggle("深色", isOn: $fixture.dark).toggleStyle(.switch).controlSize(.small)
            }
            .padding(.bottom, 22)
            Picker("历史版本", selection: $fixture.study) {
                ForEach(ThinkingStudy.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).frame(width: 580)
            Text(fixture.study == .arc ? "胶囊身体 · 开口圆弧 · 新文字顺滑推进，读完后停住" : fixture.study == .electron
                 ? "新文字推动旧文字 · 读完后停住 · 眼睛扫读，身体轻微跟随"
                 : "文字沿当前胶囊持续环流 · 原生眨眼 · 保留切线方向")
                .font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 13)

            ZStack {
                if fixture.study == .electron {
                    HistoricalCharacterView(role: fixture.role, content: fixture.content, motion: motion)
                        .frame(width: 600, height: 465).id(fixture.resetID)
                } else {
                    capsule.frame(width: 620, height: 240).offset(y: -65)
                }
            }.frame(maxWidth: .infinity).frame(height: 340)
                .allowsHitTesting(fixture.study != .electron)

            HStack(spacing: 8) {
                ForEach([HistoricalResidentRole.reasoning, .running, .tool, .idle], id: \.self) { role in
                    Button(roleName(role)) { fixture.role = role; fixture.scene.setInputOpen(false) }
                        .buttonStyle(.bordered).tint(fixture.role == role ? .accentColor : .secondary)
                }
                Spacer()
                if fixture.study != .electron {
                    Button(fixture.scene.inputOpen ? "收起输入" : "打开输入") { fixture.scene.toggleInput() }
                } else {
                    Toggle("眼睛扫读", isOn: $fixture.gaze).toggleStyle(.checkbox)
                }
                Button(fixture.paused ? "继续动画" : "暂停动画") { fixture.paused.toggle() }
            }.controlSize(.regular).font(.system(size: 12))

            Divider().padding(.vertical, 18)
            HStack {
                Text("模拟思考输入").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(fixture.streaming ? "正在流入" : "流入已暂停，等待阅读队列收尾")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(fixture.source).font(.system(size: 13)).lineSpacing(5)
                .foregroundStyle(.secondary).lineLimit(3).frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                .textSelection(.enabled).padding(.top, 9)
            HStack(spacing: 10) {
                Button(fixture.streaming ? "暂停流入" : "继续流入") {
                    if fixture.inputFinished { fixture.replay() } else { fixture.streaming.toggle() }
                }
                Button("追加一句") { fixture.streaming = false; fixture.source += " 再检查一下细节。" }
                Button("短文本") { fixture.shortText() }
                Button("重放") { fixture.replay() }
                Toggle("批量输入", isOn: $fixture.batch).toggleStyle(.checkbox)
                Spacer()
            }.font(.system(size: 12))
            HStack {
                TextField("替换为自己的演示文字…", text: $fixture.customText).textFieldStyle(.roundedBorder)
                    .onSubmit { fixture.replace() }
                Button("新段落") { fixture.replace() }
            }.font(.system(size: 12)).padding(.top, 12)
            Text(fixture.study == .arc ? "Arc 提案：288° 开口圆弧 · 左倾 20° · 半径避开胶囊 · 原始顺滑阅读节奏" : fixture.study == .electron
                 ? "原始基准：288° 圆弧 · 左倾 20° · 顺滑推进 · 同一段增量不重启动作"
                 : "原生改编：外偏 19 pt · 26 pt/s · 34 pt 接缝 · 字素柔和淡入")
                .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 17)
        }
        .padding(32).padding(.top, 12).frame(minWidth: 820, minHeight: 720)
        .background(background)
        .environment(\.colorScheme, fixture.dark ? .dark : .light)
        .environment(\.locale, Locale(identifier: "zh-CN"))
        .preferredColorScheme(fixture.dark ? .dark : .light)
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(780)) } catch { return }
                if fixture.streaming && motion && fixture.role == .reasoning { fixture.next() }
            }
        }
    }
    private var capsule: some View {
        NativeMokuScene(state: fixture.scene) { Color.clear } thread: { Color.clear } dock: {
            NativeMokuDock(state: fixture.scene, draft: fixture.draft, cwd: "/tmp",
                mode: fixture.role == .running ? .running : fixture.role == .idle ? .idle : .operation(activity: "thinking", phase: "running"),
                running: fixture.role != .idle,
                reasoning: fixture.study == .arc && fixture.role == .reasoning
                    ? MokuReasoningContent(sourceText: fixture.content.sourceText ?? fixture.content.text,
                        sourceOffset: fixture.content.sourceOffset, segmentKey: fixture.content.segmentKey) : nil,
                onSend: { _ in fixture.role = .reasoning }, onCancel: { fixture.role = .idle })
                .overlay {
                    if fixture.study == .capsule { GeometryReader { geometry in
                        // Use the production layout directly: the scene's hit-test
                        // rectangle is intentionally not observable presentation state.
                        let rect = NativeMokuCapsuleLayout.idleSurface(in: fixture.scene.dockViewport(in: geometry.size))
                        ThinkingCapsuleReasoning(content: fixture.content,
                            presenting: fixture.role == .reasoning && !fixture.scene.inputOpen && !fixture.scene.inputLeaving,
                            motion: motion, capsuleSize: rect.size)
                            .frame(width: rect.width + 64, height: rect.height + 64)
                            .position(x: rect.midX, y: rect.midY)
                    }.allowsHitTesting(false) }
                }
        } settings: { Color.clear }
            .environment(\.scenePhase, motion ? .active : .inactive)
    }
    private func roleName(_ role: HistoricalResidentRole) -> String {
        switch role { case .reasoning: "Thinking"; case .running: "Running"; case .tool: "工具接管"; default: "结束" }
    }
}

@MainActor final class ThinkingDemoDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    let fixture = ThinkingFixture()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NativeTypography.registerFonts()
        let window = NSWindow(contentRect: CGRect(x: 180, y: 100, width: 900, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Moku · Thinking — Native Demo"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 840, height: 760)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ThinkingDemoView(fixture: fixture))
        self.window = window
        let menu = NSMenu()
        let app = NSMenuItem(); let submenu = NSMenu()
        submenu.addItem(withTitle: "退出 Moku Thinking Demo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = submenu; menu.addItem(app); NSApp.mainMenu = menu
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--verify") {
            fixture.streaming = false; fixture.study = .electron
            Task { await verifyThinkingDemo(window: window, fixture: fixture) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct ThinkingDemoApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = ThinkingDemoDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
