import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import MokuseiUI
import MokuseiHarnessCodex
import MokuseiHarnessClaude

// Production Settings and window navigation, with in-memory configuration only.
@MainActor @Observable private final class Fixture {
    let navigation = NativeSettingsNavigation(section: "archived")
    let model: NativeSettingsModel
    let preferences: DesktopPreferences
    var settings = true
    var dark = false
    var scale: CGFloat = 1
    let harnesses = [AnyHarnessPlugin(CodexHarnessPlugin()), AnyHarnessPlugin(ClaudeHarnessPlugin())]

    init(directory: URL) throws {
        preferences = DesktopPreferences(directory: directory)
        try preferences.setLocale(.chinese)
        let value = try JSONValue(data: Data(#"{"moku":{"hostHarnessPreference":"codex","targetHarnessIds":["codex","claude"],"routingGuidance":null}}"#.utf8))
        model = NativeSettingsModel(settings: value, revision: 0,
            save: { value, revision in .saved(settings: value, revision: revision + 1) },
            clearHistory: {}, loadInstallations: {
                .object(["codex": .object(["status": .text("installed")]), "claude": .object(["status": .text("installed")])])
            }, installHarness: { _ in })
        model.receive(snapshot: nil, runtimeAvailable: true)
    }
}

private struct Surface: View {
    let fixture: Fixture
    var body: some View {
        GeometryReader { geometry in
            Group {
                if fixture.settings {
                    NativeSettingsPage(model: fixture.model, navigation: fixture.navigation,
                        preferences: fixture.preferences, harnesses: fixture.harnesses,
                        harnessSettings: { _ in AnyView(EmptyView()) },
                        onSetAppearance: { try fixture.preferences.setAppearance($0) },
                        onSetLocale: { try fixture.preferences.setLocale($0) },
                        onClose: { _ in fixture.settings = false })
                } else {
                    Color(nsColor: .windowBackgroundColor)
                        .overlay { Text("Thread Detail · 导航对照").font(.title2) }
                        .overlay(alignment: .topLeading) {
                            NativeWindowNavigationView(action: .init(label: "返回设置", onBack: { fixture.settings = true }))
                        }
                }
            }
            .frame(width: geometry.size.width / fixture.scale, height: geometry.size.height / fixture.scale)
            .environment(\.nativeWindowContentScale, fixture.scale)
            .scaleEffect(fixture.scale, anchor: .topLeading)
        }
        .modifier(NativeWorkspaceWindowSurface())
        .environment(\.locale, Locale(identifier: "zh-CN"))
        .preferredColorScheme(fixture.dark ? .dark : .light)
    }
}

private struct Failure: Error { let message: String }

@MainActor private final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var fixture: Fixture?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await run() }
            catch { print("FAIL: \(error)"); exit(1) }
        }
    }

    private func run() async throws {
        let directory = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "SettingsDemoDirectory") as! String)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("result.txt"))
        let fixture = try Fixture(directory: directory.appendingPathComponent("profile"))
        self.fixture = fixture
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 1100, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        self.window = window
        window.title = "Settings Navigation · Production UI"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Surface(fixture: fixture))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await fixture.model.refreshInstallations()
        try await Task.sleep(for: .seconds(1))
        guard fixture.navigation.section == "general",
              NativeSettingsNavigation.sections(model: fixture.model, applications: []) == ["general", "moku"] else {
            throw Failure(message: "Removed Settings selection did not fall back to General")
        }
        fixture.settings = false
        try await Task.sleep(for: .milliseconds(150))
        fixture.navigation.section = "plugins"
        fixture.settings = true
        try await Task.sleep(for: .milliseconds(150))
        guard fixture.navigation.section == "general" else { throw Failure(message: "Removed plugin selection did not fall back to General") }
        window.selectNextKeyView(nil)
        try await Task.sleep(for: .milliseconds(150))
        func press(_ code: UInt16, _ characters: String) {
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code) { window.sendEvent(event) }
        }
        press(125, "\u{F701}") // Down: General -> Moku.
        try await Task.sleep(for: .milliseconds(150))
        guard fixture.navigation.section == "moku" else { throw Failure(message: "Settings arrow navigation did not reach Moku") }
        press(125, "\u{F701}") // Wrap without visiting either removed section.
        try await Task.sleep(for: .milliseconds(150))
        guard fixture.navigation.section == "general" else { throw Failure(message: "Settings arrow navigation did not wrap to General") }
        press(119, "\u{F72B}") // End.
        try await Task.sleep(for: .milliseconds(150))
        guard fixture.navigation.section == "moku" else { throw Failure(message: "Settings End navigation did not reach Moku") }
        press(115, "\u{F729}") // Home.
        try await Task.sleep(for: .milliseconds(150))
        guard fixture.navigation.section == "general" else { throw Failure(message: "Settings Home navigation did not reach General") }
        fixture.navigation.section = "moku"
        let rect = fixture.navigation.returnRect
        guard abs(rect.width - 32) < 1, abs(rect.height - 30) < 1,
              abs(rect.minX - 100) < 1, abs(rect.minY - 22) < 1 else {
            throw Failure(message: "Unexpected shared back target: \(rect)")
        }

        func clickBack() {
            let rect = fixture.navigation.returnRect
            let location = NSPoint(x: rect.midX, y: (window.contentView?.bounds.height ?? 0) - rect.midY)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { window.sendEvent(event) }
            }
        }

        // Exercise the visible shared control through the production close gate.
        fixture.model.draft.composing = true
        clickBack()
        try await Task.sleep(for: .milliseconds(150))
        guard fixture.settings else { throw Failure(message: "IME composition did not block close") }
        fixture.model.draft.composing = false
        clickBack()
        try await Task.sleep(for: .milliseconds(150))
        guard !fixture.settings else { throw Failure(message: "Shared back control did not close Settings") }

        let images = directory.appendingPathComponent("screenshots")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        func capture(_ name: String) async throws {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            try await Task.sleep(for: .seconds(2))
            if fixture.settings {
                let target = fixture.navigation.returnRect
                guard abs(target.minX - 100) < 1, abs(target.minY - 22) < 1,
                      abs(target.width - 32) < 1, abs(target.height - 30) < 1 else {
                    throw Failure(message: "Settings layout moved the shared back target: \(target)")
                }
            }
            // Route and resize transitions can briefly publish a zero or stale
            // WindowServer frame. Capture only after the real window settles.
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            var settled: SCWindow?
            while ContinuousClock.now < deadline {
                let shareable = try await SCShareableContent.currentProcess
                if let candidate = shareable.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }),
                   abs(candidate.frame.width - window.frame.width) < 2,
                   abs(candidate.frame.height - window.frame.height) < 2 {
                    settled = candidate
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let target = settled else {
                throw Failure(message: "WindowServer capture did not settle for \(name); expected \(window.frame)")
            }
            let config = SCStreamConfiguration()
            config.width = Int(target.frame.width * 2); config.height = Int(target.frame.height * 2)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
            let representation = NSBitmapImageRep(cgImage: image)
            guard let png = representation.representation(using: .png, properties: [:]) else { throw Failure(message: "PNG encoding failed") }
            try png.write(to: images.appendingPathComponent(name + ".png"))
        }
        try await capture("thread-navigation-light")
        fixture.settings = true
        try await capture("settings-light")
        fixture.navigation.section = "moku"
        try await capture("settings-moku")
        fixture.navigation.section = "general"
        fixture.dark = true
        try await capture("settings-dark")
        fixture.dark = false
        window.setContentSize(.init(width: 540, height: 780))
        try await capture("settings-compact")
        try fixture.preferences.setLocale(.english)
        window.setContentSize(.init(width: 621, height: 780))
        try await capture("settings-narrow-english")
        window.setContentSize(.init(width: 1100, height: 780))
        fixture.scale = 0.76
        try await capture("settings-zoom-out-english")
        try fixture.preferences.setLocale(.chinese)
        try await capture("settings-zoom-out-chinese")
        fixture.scale = 0.25
        try await capture("settings-minimum-zoom")
        fixture.scale = 1
        window.setContentSize(.init(width: 540, height: 780))
        fixture.scale = 1.5
        try await capture("settings-compact-zoom-in")
        fixture.scale = 1
        window.setContentSize(.init(width: 1100, height: 780))
        let result = "PASS: production Settings + shared Thread Detail navigation; 32×30 back target at (100,22); removed sections fall back to General; arrow/Home/End navigation; visible back blocks IME close and closes after composition; light/dark/compact/narrow-English/zoom screenshots; fixed back target verified at every scale.\n"
        try result.write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        print(result)
        if !CommandLine.arguments.contains("--interactive") { NSApp.terminate(nil) }
    }
}

@main private struct SettingsDemo {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = Delegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
