import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI
import MokuseiPluginUI

@MainActor @Observable final class PreviewModel {
    var revision = 0
    var playRequested = false
    var busy = false
    var status = "正在准备原生阅读器…"
    var slow = false
    var longResult = false
    var forceReducedMotion = false
    var systemReducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    var dark = false
    var resize: (CGSize) -> Void = { _ in }
    var reduceMotion: Bool { forceReducedMotion || systemReducedMotion }
    func play() { playRequested = true; revision += 1 }
    func reset() { playRequested = false; revision += 1 }
}

private struct DemoWindow: View {
    @Bindable var model: PreviewModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Mokusei").font(NativeTypography.inter(size: 13, weight: 600))
                Text("/").foregroundStyle(.tertiary)
                Text("Thread · execution 交接").font(NativeTypography.inter(size: 12))
                Spacer()
                Text("独立原生提案 · 内存数据").font(NativeTypography.mono(size: 10)).foregroundStyle(.secondary)
            }.padding(.horizontal, 24).padding(.vertical, 15)
            HStack(spacing: 0) {
                HandoffStage(model: model)
                    .nativeReadingPanelClose(label: "回到运行中", onClose: model.reset)
                VStack(spacing: 14) {
                    Button { model.busy ? model.reset() : model.play() } label: {
                        NativeIcon(name: "Activity", size: 17)
                            .frame(width: 42, height: 42)
                    }.buttonStyle(.plain)
                        .glassEffect(.regular.tint(NativePalette.thread.accent.swiftUI.opacity(0.15)).interactive(), in: .circle)
                        .help(model.busy ? "取消交接，回到运行中" : "重播 execution 交接")
                        .accessibilityLabel("执行卡片：重播或取消交接")
                    NativeIcon(name: "Globe", size: 17).frame(width: 42, height: 42).opacity(0.3)
                        .help("Browser · 此 demo 不连接网页")
                    NativeIcon(name: "Phone", size: 17).frame(width: 42, height: 42).opacity(0.3)
                        .help("Voice · 此 demo 不打开麦克风")
                }.frame(width: 62)
            }.padding(.leading, 22).padding(.trailing, 10).padding(.bottom, 18)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Button(model.playRequested ? "重播交接" : "完成新 execution") { model.play() }
                        .buttonStyle(.borderedProminent).tint(NativePalette.thread.accent.swiftUI)
                        .keyboardShortcut(.return, modifiers: .command)
                    Button("回到运行中") { model.reset() }.keyboardShortcut("r", modifiers: .command)
                    Text(model.status).font(NativeTypography.inter(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(2).accessibilityIdentifier("handoff-status")
                    Spacer(minLength: 0)
                }
                HStack(spacing: 18) {
                    Toggle("慢速 3×", isOn: $model.slow)
                    Toggle("长结果", isOn: $model.longResult).onChange(of: model.longResult) { _, _ in model.reset() }
                    Toggle("减弱动态效果", isOn: $model.forceReducedMotion)
                        .disabled(model.systemReducedMotion)
                    Toggle("深色", isOn: $model.dark)
                    Spacer()
                    if model.systemReducedMotion { Text("系统已减弱动态效果").foregroundStyle(.secondary) }
                    Menu("窗口尺寸") {
                        Button("紧凑 · 960 × 680") { model.resize(.init(width: 960, height: 680)) }
                        Button("标准 · 1240 × 800") { model.resize(.init(width: 1240, height: 800)) }
                    }
                }.toggleStyle(.checkbox).font(NativeTypography.inter(size: 11))
            }.padding(.horizontal, 24).padding(.vertical, 16)
                .background(NativePalette.thread.canvas.swiftUI)
        }
        .background(NativePalette.overview.canvas.swiftUI)
        .preferredColorScheme(model.dark ? .dark : .light)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            model.systemReducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }
}

@MainActor private final class Delegate: NSObject, NSApplicationDelegate {
    let model = PreviewModel()
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: .init(x: 100, y: 100, width: 1240, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Execution handoff · Native demo"
        window.isReleasedWhenClosed = false
        window.contentMinSize = .init(width: 960, height: 620)
        window.contentView = NSHostingView(rootView: DemoWindow(model: model))
        model.resize = { [weak self] in self?.window.setContentSize($0) }
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if CommandLine.arguments.contains("--capture") {
            Task {
                do { try await captureReel() }
                catch {
                    try? String(describing: error).write(to: Bundle.main.bundleURL.deletingLastPathComponent()
                        .appendingPathComponent("capture-error.txt"), atomically: true, encoding: .utf8)
                }
                NSApp.terminate(nil)
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Presentation capture only: no test assertions, suite or regression runner.
    private func captureReel() async throws {
        let root = Bundle.main.bundleURL.deletingLastPathComponent()
        let output = root.appendingPathComponent("evidence")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var samples: [[String: Any]] = []
        let start = ContinuousClock.now
        func pause(_ ms: Int) async throws { try await Task.sleep(for: .milliseconds(ms)) }
        func shot(_ name: String) async throws {
            guard let target = try await SCShareableContent.currentProcess.windows.first(where: {
                $0.windowID == CGWindowID(window.windowNumber)
            }) else { throw CocoaError(.fileReadUnknown) }
            let configuration = SCStreamConfiguration()
            configuration.width = Int(window.frame.width * 2); configuration.height = Int(window.frame.height * 2)
            configuration.ignoreShadowsSingleWindow = true; configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                .write(to: output.appendingPathComponent(name + ".png"))
            samples.append(["name": name, "elapsed": String(describing: start.duration(to: .now)),
                "status": model.status, "busy": model.busy, "reduced": model.reduceMotion,
                "systemReducedMotion": model.systemReducedMotion, "size": NSStringFromSize(window.contentLayoutRect.size)])
        }
        try await pause(1200); try await shot("00-running")
        model.slow = true; model.play()
        for i in 0..<13 { try await pause(220); try await shot(String(format: "01-handoff-%02d", i)) }
        try await pause(600); try await shot("02-complete")
        model.reset(); try await pause(400); model.play(); try await pause(550)
        model.reset(); try await pause(450); try await shot("03-cancel")
        model.dark = true; model.longResult = true; model.reset()
        model.resize(.init(width: 960, height: 680))
        try await pause(600); try await shot("04-compact-dark")
        model.slow = false; model.play(); try await pause(1400); try await shot("05-compact-result")
        model.forceReducedMotion = true; model.reset(); try await pause(300)
        model.play(); try await pause(500); try await shot("06-reduced")
        try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("samples.json"))
    }
}

@main private struct DemoApp {
    @MainActor static func main() throws {
        try prepareIsolatedNativeReplay()
        NativeTypography.registerFonts()
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let menu = NSMenu()
        let application = NSMenuItem(); application.submenu = NSMenu()
        application.submenu?.addItem(withTitle: "Quit demo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(application); app.mainMenu = menu
        let delegate = Delegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
