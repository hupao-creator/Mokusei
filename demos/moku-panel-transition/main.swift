import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI
import MokuseiCore
import MokuseiPluginUI
@testable import MokuseiUI

@MainActor @Observable private final class Preview {
    let scene = NativeMokuSceneState()
    let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
    var running = true
    var landing = false
    var reducedMotion = false
    var thread = true
    var status = "普通 Thread · 点击胶囊打开，Escape 或外部点击收起"
    var resize: (CGSize) -> Void = { _ in }
}

private struct Surface: View {
    let model: Preview
    var body: some View {
        NativeMokuScene(state: model.scene) {
            Color(white: 0.91).overlay {
                RoundedRectangle(cornerRadius: 18).fill(.white)
                    .padding(.horizontal, 50).padding(.top, 54).padding(.bottom, 90)
            }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("🔧  修复历史执行工具消息泄漏").font(.title2.bold())
                    Text("仅内存 fixture · 复用生产 NativeMokuScene / Dock / 原生编辑器").foregroundStyle(.secondary)
                    Text(model.status).font(.callout)
                }.padding(.top, 90).padding(.leading, 85)
            }
        } thread: { Color.white } dock: {
            NativeMokuDock(state: model.scene, draft: model.draft, cwd: "/fixture",
                landing: model.landing, threadTitle: model.thread ? "修复历史执行工具消息泄漏" : nil,
                mode: model.running ? .running : .idle, running: model.running,
                loadMentionDirectories: { ["Mokusei", "Design", "Research"].map {
                    NativeComposerDirectory(name: JSONText($0), path: JSONText("/fixture/" + $0))
                } }, onSend: { _ in model.status = "已模拟发送 · 未调用模型或 Runtime" },
                onCancel: { model.running = false })
        } settings: { EmptyView() }
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        .transaction { if model.reducedMotion { $0.animation = nil; $0.disablesAnimations = true } }
    }
}

private struct Controls: View {
    let model: Preview
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("展开 / 收起") { model.scene.setInputOpen(!model.scene.inputOpen) }
            Toggle("运行中", isOn: Bindable(model).running)
            Toggle("Thread", isOn: Bindable(model).thread)
            Toggle("Landing", isOn: Bindable(model).landing)
            Toggle("禁用过渡", isOn: Bindable(model).reducedMotion)
            Menu("窗口") {
                Button("1024 × 650") { model.resize(.init(width: 1024, height: 650)) }
                Button("420 × 300") { model.resize(.init(width: 420, height: 300)) }
                Button("300 × 190") { model.resize(.init(width: 300, height: 190)) }
                Button("180 × 140") { model.resize(.init(width: 180, height: 140)) }
            }
        }.toggleStyle(.checkbox).font(.system(size: 11)).padding(10)
            .frame(width: 240)
    }
}

@MainActor private final class Delegate: NSObject, NSApplicationDelegate {
    let model = Preview()
    var window: NSWindow!
    var controls: NSPanel!
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: .init(x: 100, y: 100, width: 1024, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Moku panel · isolated production preview"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Surface(model: model))
        model.resize = { [weak self] in self?.window.setContentSize($0) }
        controls = NSPanel(contentRect: .init(x: 1150, y: 250, width: 260, height: 240),
            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        controls.title = "预览控制 · 不属于产品 UI"
        controls.isReleasedWhenClosed = false
        controls.contentView = NSHostingView(rootView: Controls(model: model))
        if !CommandLine.arguments.contains("--capture") { controls.orderFront(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if CommandLine.arguments.contains("--capture") {
            Task {
                do { try await capture() }
                catch {
                    let root = Bundle.main.bundleURL.deletingLastPathComponent()
                    try? String(describing: error).write(to: root.appendingPathComponent("capture-error.txt"), atomically: true, encoding: .utf8)
                }
                NSApp.terminate(nil)
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // A presentation reel, not a regression suite: no assertions or test runner.
    // It records the actual production views, including intermediate native pixels.
    private func capture() async throws {
        let root = Bundle.main.bundleURL.deletingLastPathComponent()
        let evidence = root.appendingPathComponent("evidence")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        var samples: [[String: Any]] = []
        let start = ContinuousClock.now
        func pause(_ ms: Int) async throws { try await Task.sleep(for: .milliseconds(ms)) }
        func shot(_ name: String) async throws {
            guard let target = try await SCShareableContent.currentProcess.windows.first(where: {
                $0.windowID == CGWindowID(window.windowNumber)
            }) else { throw NSError(domain: "Preview window unavailable", code: 1) }
            let configuration = SCStreamConfiguration()
            configuration.width = Int(window.frame.width * 2)
            configuration.height = Int(window.frame.height * 2)
            configuration.ignoreShadowsSingleWindow = true
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                .write(to: evidence.appendingPathComponent(name + ".png"))
            func editors(_ view: NSView) -> [NSTextView] {
                (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(editors)
            }
            func faces(_ view: NSView) -> [NativeMokuCharacterCanvas] {
                (view as? NativeMokuCharacterCanvas).map { [$0] } ?? view.subviews.flatMap(faces)
            }
            let content = window.contentView!
            samples.append(["name": name, "elapsed": String(describing: start.duration(to: .now)),
                "input": model.scene.inputOpen, "transitionsDisabled": model.reducedMotion,
                "systemReduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                "window": NSStringFromSize(window.contentLayoutRect.size),
                "faces": faces(content).filter { $0.seat == .face }.map { NSStringFromRect($0.convert($0.bounds, to: nil)) },
                "editors": editors(content).map { NSStringFromRect($0.convert($0.bounds, to: nil)) },
                "editorViewports": editors(content).compactMap { $0.enclosingScrollView }.map { NSStringFromRect($0.convert($0.bounds, to: nil)) },
                "editorIDs": editors(content).map { String(describing: ObjectIdentifier($0)) },
                "selection": editors(content).map { NSStringFromRange($0.selectedRange()) }])
        }
        try await pause(900)
        model.scene.setInputOpen(false)
        try await pause(650)
        try await shot("00-idle")
        model.scene.setInputOpen(true)
        for i in 0..<9 { try await shot(String(format: "01-open-%02d", i)); try await pause(25) }
        try await pause(450); try await shot("02-open-settled")
        model.scene.setInputOpen(false)
        for i in 0..<9 { try await shot(String(format: "03-close-%02d", i)); try await pause(25) }
        try await pause(450); try await shot("04-closed-settled")
        model.scene.setInputOpen(true)
        try await pause(120); try await shot("05-reverse-open")
        model.scene.setInputOpen(false)
        try await pause(100); try await shot("06-reverse-close")
        model.scene.setInputOpen(true)
        try await pause(100); try await shot("07-reverse-reopen")
        try await pause(550); try await shot("08-reverse-settled")
        model.draft.text = "多行内容不应随胶囊宽度挤压。\n第二行保留原生布局与选择。\nThird line remains readable."
        try await pause(200); try await shot("09-multiline")
        model.scene.setInputOpen(false)
        try await pause(100); try await shot("10-multiline-close")
        try await pause(550)
        window.setContentSize(.init(width: 420, height: 300))
        model.scene.setInputOpen(true)
        try await pause(550); try await shot("11-narrow")
        window.setContentSize(.init(width: 300, height: 190))
        try await pause(250); try await shot("12-short")
        model.scene.setInputOpen(false)
        try await pause(550); try await shot("13-short-closed")
        window.setContentSize(.init(width: 180, height: 140))
        model.scene.setInputOpen(true)
        try await pause(550); try await shot("14-tiny")
        window.setContentSize(.init(width: 1024, height: 650))
        model.scene.setInputOpen(false); model.draft.text = ""
        model.reducedMotion = true
        try await pause(550)
        model.scene.setInputOpen(true)
        try await shot("15-no-animation-open")
        model.scene.setInputOpen(false)
        try await shot("16-no-animation-close")
        model.reducedMotion = false; model.thread = false; model.running = false; model.landing = true
        model.scene.setInputOpen(true)
        try await pause(550); try await shot("17-landing")
        model.scene.setInputOpen(false)
        try await pause(100); try await shot("18-landing-close")
        try await pause(550); try await shot("19-landing-closed")
        try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
            .write(to: evidence.appendingPathComponent("samples.json"))
    }
}

@main private struct App {
    @MainActor static func main() throws {
        try prepareIsolatedNativeReplay()
        NativeTypography.registerFonts()
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Delegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
