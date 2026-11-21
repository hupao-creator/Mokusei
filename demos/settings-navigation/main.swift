import AppKit
import Observation
import SwiftUI
import ChiefCore
import ChiefPluginAPI
import ChiefPluginUI
import ChiefUI
import ChiefHarnessCodex
import ChiefHarnessClaude
import ChiefHarnessPi
import ChiefHarnessOpenCode

// Production Settings, scene and Dock, with in-memory configuration only.
@MainActor @Observable private final class Fixture {
    let navigation = NativeSettingsNavigation(section: "archived")
    let model: NativeSettingsModel
    let scene = NativeMokuSceneState()
    let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
    var settings: Bool {
        get { scene.settingsOpen }
        set {
            if newValue { scene.openSettings() }
            else { scene.closeSettings(); scene.settle() }
        }
    }
    var dark = false
    var scale: CGFloat = 1
    let harnesses = [AnyHarnessPlugin(PiHarnessPlugin()), AnyHarnessPlugin(CodexHarnessPlugin()),
                     AnyHarnessPlugin(ClaudeHarnessPlugin()), AnyHarnessPlugin(OpenCodeHarnessPlugin())]

    init() throws {
        let value = try JSONValue(data: Data(#"{"moku":{"hostHarnessPreference":"codex","targetHarnessIds":["codex","claude"],"routingGuidance":null}}"#.utf8))
        model = NativeSettingsModel(settings: value, revision: 0,
            save: { value, revision in .saved(settings: value, revision: revision + 1) },
            clearHistory: {}, loadInstallations: {
                .object(["pi": .object(["status": .text("installed")]), "codex": .object(["status": .text("installed")]),
                         "claude": .object(["status": .text("installed")]), "opencode": .object(["status": .text("installed")])])
            }, installHarness: { _ in })
        model.receive(snapshot: nil, runtimeAvailable: true)
    }
}

private struct FixtureHarnessForm: View {
    @Environment(\.nativeSettingsBeforeAdvanced) private var beforeAdvanced
    var body: some View { beforeAdvanced }
}

private struct Surface: View {
    let fixture: Fixture
    var body: some View {
        GeometryReader { geometry in
            NativeMokuScene(state: fixture.scene) {
                NativePalette.overview.canvas.swiftUI.overlay {
                    Button("Settings") { fixture.settings = true }.buttonStyle(.bordered)
                }
            } thread: { EmptyView() } dock: {
                NativeMokuDock(state: fixture.scene, draft: fixture.draft, cwd: "/tmp", onSend: { _ in }, onCancel: {})
            } onCloseSettings: {
                fixture.navigation.requestClose(model: fixture.model) { _ in fixture.scene.closeSettings() }
            } settings: {
                NativeSettingsPage(model: fixture.model, navigation: fixture.navigation,
                    locale: .chinese, harnesses: fixture.harnesses,
                    harnessSettings: { _ in AnyView(FixtureHarnessForm()) },
                    onClose: { _ in fixture.scene.closeSettings() })
            }
            .frame(width: geometry.size.width / fixture.scale, height: geometry.size.height / fixture.scale)
            .coordinateSpace(name: "workspace")
            .environment(\.nativeWindowContentScale, fixture.scale)
            .scaleEffect(fixture.scale, anchor: .topLeading)
        }
        .modifier(NativeWorkspaceWindowSurface())
        .environment(\.locale, Locale(identifier: "zh-CN"))
        .preferredColorScheme(fixture.dark ? .dark : .light)
    }
}


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
        let opensMoku = Bundle.main.object(forInfoDictionaryKey: "SettingsDemoOpensMoku") as? Bool == true
        let fixture = try Fixture()
        self.fixture = fixture
        if opensMoku {
            fixture.dark = true
            fixture.navigation.section = "moku"
        }
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 1100, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        self.window = window
        window.title = opensMoku ? "Moku Map · Production UI" : "Settings Navigation · Production UI"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Surface(fixture: fixture))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        fixture.settings = true
        await fixture.model.refreshInstallations()

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
