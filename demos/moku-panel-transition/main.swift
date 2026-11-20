import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI
import MokuseiCore
import MokuseiHarnessCodex
import MokuseiPluginAPI
import MokuseiPluginUI
@testable import MokuseiUI

// A nonactivating panel can still take the user's keyboard independently of
// the frontmost application. The replay drives its local first responder.
class ComposerReplayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor @Observable private final class Preview {
    let readingMotion = NativeReadingPageMotion()
    let scene: NativeMokuSceneState
    var draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
    var running = true
    var landing = false
    var transitionsDisabled = false
    var thread = true
    var collapseCapture = false
    var agentEntranceCapture = false
    var overviewCapture = false
    var language = "zh-Hans"
    @ObservationIgnored var overviewInputChanges: [Bool] = []
    var openingClock = CaptureOpeningClock.realtime
    var title = "修复历史执行工具消息泄漏"
    var readingRoute = UUID()
    let overviewDraft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
    var sendReplay: PendingSendReplay?
    var isolatedReplay: Bool { collapseCapture || agentEntranceCapture || overviewCapture || sendReplay != nil }
    let route = UUID()
    let harness = AnyHarnessPlugin(CodexHarnessPlugin())
    var status = "普通 Thread · 点击胶囊打开，Escape 或外部点击收起"
    var resize: (CGSize) -> Void = { _ in }

    init() { scene = NativeMokuSceneState(readingPanelMotion: readingMotion) }

    func enterAgent(title: String, draft: NativeComposerDraft, openingClock: CaptureOpeningClock) {
        self.openingClock = openingClock
        self.title = title
        thread = true
        running = true
        self.draft = draft
        readingRoute = UUID()
        scene.executionDockPlacement.beginRoute(readingRoute)
        scene.readingPanelVisible = true
        scene.overviewVisible = false
        scene.setComposerContext(draft, opensInput: true, keepsInputOpen: true, inputAdmissionReady: false,
                                 waitsForHarnessIdentity: true)
    }

    func finishReturn() {
        thread = false
        running = false
        draft = overviewDraft
        scene.executionDockPlacement.beginRoute(UUID())
        scene.overviewVisible = true
        scene.readingPanelVisible = false
        scene.setComposerContext(draft, opensInput: false)
    }
}

private struct Surface: View {
    let model: Preview
    var body: some View {
        NativeMokuScene(state: model.scene) {
            if model.agentEntranceCapture {
                NativeReadingPageStack(open: model.thread, identity: JSONText(model.readingRoute.uuidString),
                    motion: model.readingMotion, stationaryParent: true, panel: true,
                    threadPanelMotion: true, onClose: model.finishReturn) {
                    Color(white: 0.91)
                } front: {
                    ColumnMarker(model: model)
                        .environment(\.nativeExecutionDockRoute, model.readingRoute)
                }
            } else if model.overviewCapture {
                Color(white: 0.91)
                    .onChange(of: model.scene.inputOpen) { _, open in model.overviewInputChanges.append(open) }
            } else {
                previewBackdrop
            }
        } thread: { Color.white } dock: {
            dock
        } settings: { EmptyView() }
        .environment(\.locale, Locale(identifier: model.language))
        .environment(\.nativeExecutionDockRoute, model.route)
        .environment(\.scenePhase, model.isolatedReplay ? .active : scenePhase)
        .transaction { if model.transitionsDisabled { $0.animation = nil; $0.disablesAnimations = true } }
    }
    private var previewBackdrop: some View {
        Color(white: 0.91).overlay {
            RoundedRectangle(cornerRadius: 18).fill(.white)
                .padding(.horizontal, 50).padding(.top, 54).padding(.bottom, 90)
        }
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 12) {
                Text("🔧  \(model.title)").font(.title2.bold())
                Text("仅内存 fixture · 复用生产 NativeMokuScene / Dock / 原生编辑器").foregroundStyle(.secondary)
                Text(model.status).font(.callout)
            }.padding(.top, 90).padding(.leading, 85)
        }
        .background {
            if model.collapseCapture {
                GeometryReader { geometry in
                    NativeExecutionDockRegion(placement: model.scene.executionDockPlacement,
                        active: model.thread, threadID: "fixture-agent",
                        onSettled: {
                            guard model.thread else { return }
                            model.scene.setComposerContext(model.draft, opensInput: true, keepsInputOpen: true,
                                waitsForHarnessIdentity: true, autofocus: false)
                        })
                        .destinationFrame(CGRect(x: geometry.size.width / 2, y: 0,
                            width: geometry.size.width / 2, height: geometry.size.height))
                }
            }
        }
    }

    private var dock: some View {
        var dock = NativeMokuDock(state: model.scene, draft: model.draft, cwd: "/fixture",
            landing: model.landing,
            threadID: model.thread ? "fixture-agent" : nil,
            threadHarness: model.collapseCapture || (model.agentEntranceCapture && model.thread) ? model.harness : nil,
            mode: model.running ? .running : .idle, running: model.running,
            loadMentionDirectories: { ["Mokusei", "Design", "Research"].map {
                NativeComposerDirectory(name: JSONText($0), path: JSONText("/fixture/" + $0))
            } }, onSend: { submission in
                if let replay = model.sendReplay { try await replay.receive(submission) }
                else { model.status = "已模拟发送 · 未调用模型或 Runtime" }
            },
            onCancel: { model.running = false })
        // Install the fixture clock before input admission in the nested Dock host.
        if model.openingClock == .heldFrames {
            dock.readingInputAnimation = Animation(HeldOpeningFrames())
        }
        return dock
    }

    @Environment(\.scenePhase) private var scenePhase
}

// The workspace suppresses the selected Sidecard as soon as primary reading
// motion starts. Keep its marker mounted through return, as the reader does.
private struct ColumnMarker: View {
    let model: Preview
    @Environment(\.nativeReadingEntranceReady) private var entranceReady
    @State private var columnMounted = false

    var body: some View {
        GeometryReader { proxy in
            let width = min(404, proxy.size.width / 2)
            let frame = CGRect(x: proxy.size.width - width, y: 0, width: width, height: proxy.size.height)
            let active = columnMounted && !model.readingMotion.active
            Color.white.overlay(alignment: .topLeading) {
                Text(model.title).font(.title2.bold()).padding(48)
            }.background {
                NativeExecutionDockRegion(placement: model.scene.executionDockPlacement,
                    active: active, ready: columnMounted, threadID: "fixture-agent",
                    onSettled: {
                        guard model.thread, entranceReady, active else { return }
                        model.scene.setComposerContext(model.draft, opensInput: true, keepsInputOpen: true,
                            waitsForHarnessIdentity: true)
                    })
                    .destinationFrame(active ? frame : nil)
            }
            .onChange(of: entranceReady, initial: true) { _, ready in
                if ready { columnMounted = true }
            }
        }
    }
}

@MainActor func makePeerComposerPanel(draft: NativeComposerDraft, replay: PendingSendReplay) -> NSPanel {
    let model = Preview()
    model.sendReplay = replay
    model.draft = draft
    model.scene.readingPanelVisible = true
    model.scene.overviewVisible = false
    model.scene.setComposerContext(draft, opensInput: true, keepsInputOpen: true, autofocus: false)
    let panel = ComposerReplayPanel(contentRect: .init(x: 100, y: 100, width: 1024, height: 650),
        styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.ignoresMouseEvents = true
    panel.contentView = NSHostingView(rootView: Surface(model: model))
    panel.orderBack(nil)
    return panel
}

private struct Controls: View {
    let model: Preview
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("展开 / 收起") { model.scene.setInputOpen(!model.scene.inputOpen) }
            Toggle("运行中", isOn: Bindable(model).running)
            Toggle("Thread", isOn: Bindable(model).thread)
            Toggle("Landing", isOn: Bindable(model).landing)
            Toggle("禁用过渡", isOn: Bindable(model).transitionsDisabled)
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
        if CommandLine.arguments.contains("--replay-chief-input") {
            Task {
                do { try await replayChiefInput() }
                catch { print("Chief input replay failed:", error); exit(EXIT_FAILURE) }
                NSApp.terminate(nil)
            }
            return
        }
        if CommandLine.arguments.contains("--capture-overview") {
            startOverviewCapture()
            return
        }
        if CommandLine.arguments.contains("--capture-agent-entrance") {
            startAgentEntranceCapture()
            return
        }
        let replaySend = CommandLine.arguments.contains("--replay-send")
        model.collapseCapture = CommandLine.arguments.contains("--capture-collapse")
        if replaySend || model.collapseCapture {
            if replaySend {
                let replay = PendingSendReplay()
                model.sendReplay = replay
                model.draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }),
                    persistence: replay.persistence)
            } else {
                model.thread = false
                model.running = false
                model.scene.readingPanelVisible = true
                model.scene.overviewVisible = false
                model.scene.executionDockPlacement.beginRoute(model.route)
                model.scene.setComposerContext(model.draft, opensInput: false, inputAdmissionReady: false)
            }
            let width: CGFloat = CommandLine.arguments.contains("--narrow") ? 480 : 1024
            let frame = NSRect(x: 100, y: 100, width: width, height: 650)
            let style: NSWindow.StyleMask = [.titled, .nonactivatingPanel]
            window = ComposerReplayPanel(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            window.title = replaySend ? "Moku pending send replay" : "Moku collapse replay"
            window.contentView = NSHostingView(rootView: Surface(model: model))
            window.orderBack(nil)
            Task {
                do {
                    if let replay = model.sendReplay {
                        try await replay.run(window: window, scene: model.scene, draft: model.draft)
                    } else {
                        try await captureCollapse(window: window, scene: model.scene, selectExecution: {
                            model.scene.setComposerContext(model.draft, opensInput: true, keepsInputOpen: true,
                                inputAdmissionReady: false, waitsForHarnessIdentity: true, autofocus: false)
                            model.thread = true
                        }, returnToReportList: {
                            model.thread = false
                            model.scene.setComposerContext(model.draft, opensInput: false, inputAdmissionReady: false)
                        }, selectOverviewDraft: { draft in
                            model.thread = false
                            model.draft = draft
                        })
                    }
                } catch {
                    print("Isolated replay failed:", error)
                    exit(EXIT_FAILURE)
                }
                NSApp.terminate(nil)
            }
            return
        }
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
    private func startOverviewCapture() {
        let args = CommandLine.arguments
        let systemInput = args.contains("--system-input")
        let reduced = args.contains("--reduce-motion")
        let language = args.contains("--english") ? "en" : "zh-Hans"
        model.overviewCapture = true
        model.language = language
        model.thread = false
        model.scene.setComposerContext(model.draft, opensInput: false)
        let panel = ComposerReplayPanel(contentRect: .init(x: 0, y: 0, width: 720, height: 260),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window = panel
        panel.title = "Chief Dock replay"
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = !systemInput
        panel.level = .floating
        if !systemInput, let screen = NSScreen.screens.max(by: { $0.frame.maxX < $1.frame.maxX }) {
            panel.setFrameOrigin(.init(x: screen.frame.maxX - 2, y: screen.visibleFrame.minY))
        } else {
            panel.center()
        }
        panel.contentView = NSHostingView(rootView: Surface(model: model)
            .environment(\._accessibilityReduceMotion, reduced))
        panel.orderFrontRegardless()
        Task {
            do {
                try await Task.sleep(for: .milliseconds(400))
                let folder = ["overview", language, reduced ? "reduced" : "motion",
                              systemInput ? "system" : "scene"].joined(separator: "-")
                let movie = try await DockMovieCapture(window: panel, folder: folder)
                // The ready file lets an external driver address only this panel.
                let ready: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                                            "window": panel.windowNumber]
                try JSONSerialization.data(withJSONObject: ready)
                    .write(to: movie.directory.appendingPathComponent("ready.json"), options: .atomic)
                if systemInput {
                    // Click the eyes, click outside, AXPress Open, then activate Stop.
                    // Stop ends the running fixture through the production action.
                    let deadline = ContinuousClock.now.advanced(by: .seconds(35))
                    while model.running && ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                } else {
                    for _ in 0..<2 {
                        try await Task.sleep(for: .milliseconds(650))
                        model.scene.setInputOpen(true)
                        try await Task.sleep(for: .milliseconds(750))
                        model.scene.setInputOpen(false)
                    }
                }
                try await Task.sleep(for: .milliseconds(650))
                try await movie.finish()
                let expected = systemInput ? [true, false, true] : [true, false, true, false]
                let observed: [String: Any] = ["inputChanges": model.overviewInputChanges,
                    "running": model.running, "reduceMotion": reduced, "locale": language]
                try JSONSerialization.data(withJSONObject: observed, options: .prettyPrinted)
                    .write(to: movie.directory.appendingPathComponent("observations.json"), options: .atomic)
                guard model.overviewInputChanges == expected, model.running != systemInput else {
                    throw NSError(domain: "Unexpected Overview input or running state: \(observed)", code: 1)
                }
            } catch {
                print("Overview capture failed:", error)
                exit(EXIT_FAILURE)
            }
            NSApp.terminate(nil)
        }
    }

    private func startAgentEntranceCapture() {
        model.agentEntranceCapture = true
        let replay = PendingSendReplay()
        model.sendReplay = replay
        model.thread = false
        model.running = false
        let panel = CollapseCapturePanel(contentRect: .init(x: 100, y: 100, width: 1024, height: 650),
            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window = panel
        panel.isReleasedWhenClosed = false
        panel.title = "Moku Agent entrance replay"
        panel.contentView = NSHostingView(rootView: Surface(model: model))
        panel.installCaptureMarkers()
        // Leave only a click-through edge on screen. A fully occluded
        // window can deliver static endpoints even to current-process capture.
        window.ignoresMouseEvents = true
        if let screen = NSScreen.screens.max(by: { $0.frame.maxX < $1.frame.maxX }) {
            window.setFrameOrigin(.init(x: screen.frame.maxX - 2, y: screen.visibleFrame.minY))
        }
        window.orderFrontRegardless()
        Task {
            do {
                try await captureAgentEntrance(window: panel, scene: model.scene, overviewDraft: model.overviewDraft,
                    enterAgent: model.enterAgent, closeAgent: model.readingMotion.close)
                try await replay.verifyHandoff(window: panel, scene: model.scene, agent: model.draft,
                    overview: model.overviewDraft, closeAgent: model.readingMotion.close)
            } catch {
                print("Agent entrance replay failed:", error)
                exit(EXIT_FAILURE)
            }
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // A nonactivating panel need not count as an open main window.
        // Replay owns termination until every case and its observations finish.
        !model.isolatedReplay && !CommandLine.arguments.contains("--replay-chief-input")
    }

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
                "input": model.scene.inputOpen, "transitionsDisabled": model.transitionsDisabled,
                "window": NSStringFromSize(window.contentLayoutRect.size),
                "decorations": faces(content).filter { $0.seat == .decorations }.map { NSStringFromRect($0.convert($0.bounds, to: nil)) },
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
        model.transitionsDisabled = true
        try await pause(550)
        model.scene.setInputOpen(true)
        try await shot("15-no-animation-open")
        model.scene.setInputOpen(false)
        try await shot("16-no-animation-close")
        model.transitionsDisabled = false; model.thread = false; model.running = false; model.landing = true
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
        let isolated = ["--capture-collapse", "--capture-agent-entrance", "--capture-overview", "--replay-send", "--replay-chief-input"]
            .contains { CommandLine.arguments.contains($0) }
        app.setActivationPolicy(isolated ? .accessory : .regular)
        let delegate = Delegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
