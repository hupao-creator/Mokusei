import AppKit
import ScreenCaptureKit
import Observation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
@testable import MokuseiUI

@MainActor @Observable private final class SettingsTransitionFixture {
    let scene = NativeMokuSceneState()
    let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
    let navigation = NativeSettingsNavigation(section: "general")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NativeSettingsModel(settings: .object([:]), revision: 0,
        save: { value, revision in .saved(settings: value, revision: revision + 1) },
        clearHistory: {}, loadInstallations: { .object([:]) }, installHarness: { _ in })
    var phase: ScenePhase = .active
    var size = CGSize(width: 1180, height: 780)
    var scale = 1.0
    var landing = false
    var pageSize = CGSize.zero
    var appearances = 0
    var disappearances = 0
    var outsideAppearances = 0
    var backgroundClicks = 0
    var interaction = false
    var interactionMounted = false
    var interactionFrame = CGRect.zero
    var answers = 0
    var closeRequests = 0
    let note = NativeMokuNote(id: "settings-note", text: "Keep this note open", revision: 1, updatedAt: 1)
    var preferences: DesktopPreferences
    init() { preferences = DesktopPreferences(directory: directory) }
    func close() { closeRequests += 1; navigation.requestClose(model: model) { _ in scene.closeSettings() } }
    func dispose() {
        scene.overviewState.camera.dispose()
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct SettingsTransitionReplay: View {
    let fixture: SettingsTransitionFixture
    var body: some View { GeometryReader { _ in replay } }
    private var replay: some View {
        NativeMokuScene(state: fixture.scene) {
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    for index in 0..<Int(ceil(size.width / 10)) {
                        context.fill(Path(CGRect(x: CGFloat(index) * 10, y: 0, width: 10, height: size.height)),
                            with: .color(index.isMultiple(of: 2) ? .white : .black))
                    }
                }
                Button("Background") { fixture.backgroundClicks += 1 }
                    .buttonStyle(.plain).frame(width: 100, height: 30).padding(.top, 45)
            }.onAppear { fixture.outsideAppearances += 1 }
        } thread: { Color.green } dock: {
            NativeMokuDock(state: fixture.scene, draft: fixture.draft, cwd: "/tmp", landing: fixture.landing,
                interaction: fixture.interaction ? AnyView(Button("Waiting permission") { fixture.answers += 1 }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("workspace")) } action: { fixture.interactionFrame = $0 }
                    .onAppear { fixture.interactionMounted = true }
                    .onDisappear { fixture.interactionMounted = false }) : nil,
                note: fixture.note, onSend: { _ in }, onCancel: {})
        } onCloseSettings: { fixture.close() } settings: {
            NativeSettingsPage(model: fixture.model, navigation: fixture.navigation,
                preferences: fixture.preferences, harnesses: [], harnessSettings: { _ in AnyView(EmptyView()) },
                onSetAppearance: { try fixture.preferences.setAppearance($0) },
                onSetLocale: { try fixture.preferences.setLocale($0) }, onClose: { _ in fixture.scene.closeSettings() })
                .onGeometryChange(for: CGSize.self) { $0.size } action: { fixture.pageSize = $0 }
                .onAppear { fixture.appearances += 1 }
                .onDisappear { fixture.disappearances += 1 }
        }
        .frame(width: fixture.size.width / fixture.scale, height: fixture.size.height / fixture.scale)
        .coordinateSpace(name: "workspace")
        .environment(\.nativeWindowContentScale, fixture.scale)
        .scaleEffect(fixture.scale, anchor: .topLeading)
        .environment(\.scenePhase, fixture.phase)
    }
}

@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["MOKUSEI_READING_PRESENTATION_NATIVE_REPLAY"] == "1",
             "Requires the isolated AppKit/WindowServer Settings replay: python3 tools/verification/reading-presentation/run.py --settings-transition"))
struct NativeSettingsTransitionTests {
    private func pixels(_ window: NSWindow) async throws -> NSBitmapImageRep {
        // cacheDisplay omits compositor filters such as SwiftUI blur and native
        // glass. WindowServer pixels are the oracle for this visual contract.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await SwiftUIReplay.wait { window.isKeyWindow && NSApp.isActive }
        window.orderFrontRegardless()
        let deadline = ContinuousClock.now + .seconds(3)
        var settled: SCWindow?
        var observed = CGRect.zero
        while ContinuousClock.now < deadline {
            let content = try await SCShareableContent.currentProcess
            let candidate = content.windows.first { $0.windowID == CGWindowID(window.windowNumber) }
            observed = candidate?.frame ?? .zero
            if let candidate,
               abs(candidate.frame.width - window.frame.width) < 2,
               abs(candidate.frame.height - window.frame.height) < 2 {
                settled = candidate; break
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        let target = try #require(settled, "WindowServer geometry must settle before visual sampling: observed \(observed), window \(window.frame), visible \(window.isVisible)")
        let configuration = SCStreamConfiguration()
        configuration.width = Int(target.frame.width * 2)
        configuration.height = Int(target.frame.height * 2)
        configuration.showsCursor = false
        return NSBitmapImageRep(cgImage: try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration))
    }
    private func contrast(_ bitmap: NSBitmapImageRep) throws -> CGFloat {
        let samples = try (50..<110).map { x in
            try #require(bitmap.colorAt(x: x * bitmap.pixelsWide / 1180, y: bitmap.pixelsHigh / 3)?.usingColorSpace(.sRGB)).redComponent
        }
        return try #require(samples.max()) - #require(samples.min())
    }
    private func click(_ window: NSWindow, point: CGPoint) async throws {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await SwiftUIReplay.wait { window.isKeyWindow && NSApp.isActive }
        let height = try #require(window.contentView).bounds.height
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: point.x, y: height - point.y),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            NSApp.sendEvent(event)
            try await Task.sleep(for: .milliseconds(40))
        }
    }
    private func escape(_ window: NSWindow) throws {
        NSApp.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
    }
    private func capture(_ window: NSWindow, name: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["MOKUSEI_SETTINGS_ARTIFACTS"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(await pixels(window).representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }

    @Test func capsuleExpandsWithoutRemountingAndFitsViewport() async throws {
        for (size, scale, landing) in [(CGSize(width: 1180, height: 780), 1.0, false),
                                      (CGSize(width: 640, height: 480), 1.0, true),
                                      (CGSize(width: 1180, height: 780), 2.0, false),
                                      (CGSize(width: 1180, height: 780), 5.0, true)] {
            let fixture = SettingsTransitionFixture()
            fixture.size = size; fixture.scale = scale; fixture.landing = landing
            let window = SwiftUIReplay.window(SettingsTransitionReplay(fixture: fixture), width: size.width, height: size.height)
            defer { window.close(); fixture.dispose() }
            try await SwiftUIReplay.wait { fixture.scene.windowVisible && !fixture.scene.capsuleFrame.isEmpty }
            let original = fixture.scene.capsuleFrame
            let originalContrast = scale == 1 && !landing ? try await contrast(pixels(window)) : 0
            fixture.scene.openSettings()
            #expect(fixture.scene.settingsTransitioning)
            try await SwiftUIReplay.wait { fixture.scene.settingsOpen && !fixture.scene.settingsTransitioning && fixture.navigation.mounted }
            let panel = fixture.scene.capsuleFrame
            #expect(panel.width > original.width || landing)
            #expect(panel.width <= size.width / scale - 48 + 1)
            #expect(panel.height <= size.height / scale - 48 + 1)
            #expect(abs(panel.midX - size.width / scale / 2) < 1)
            #expect(abs(panel.midY - size.height / scale / 2) < 1)
            #expect(fixture.appearances == 1 && fixture.outsideAppearances == 1)
            #expect(fixture.pageSize.height > 40, "Settings must retain a usable content viewport")
            if originalContrast > 0 {
                #expect(try await contrast(pixels(window)) < originalContrast * 0.5, "The real Overview backdrop must be blurred")
                #expect(abs(panel.width - 780) < 1 && abs(panel.height - 668) < 1)
            }
            let before = fixture.pageSize
            fixture.navigation.section = "moku"
            try await Task.sleep(for: .milliseconds(60))
            #expect(fixture.pageSize == before && fixture.scene.capsuleFrame == panel)
            fixture.navigation.section = "general"
            try await capture(window, name: "panel-\(scale)-\(landing ? "landing" : "bottom")")
            fixture.close()
            #expect(fixture.scene.settingsOpen && fixture.scene.settingsClosing)
            try await Task.sleep(for: .milliseconds(100))
            #expect(fixture.scene.settingsOpen && fixture.disappearances == 0)
            try await SwiftUIReplay.wait { !fixture.scene.settingsOpen && fixture.disappearances == 1 }
        }
    }

    @Test func modalInputClosesWithoutClickThroughAndRestoresDock() async throws {
        let fixture = SettingsTransitionFixture()
        let window = SwiftUIReplay.window(SettingsTransitionReplay(fixture: fixture))
        defer { window.close(); fixture.dispose() }
        try await SwiftUIReplay.wait { fixture.scene.windowVisible }
        fixture.draft.text = "Keep draft"
        fixture.scene.setInputOpen(true)
        try await SwiftUIReplay.wait { fixture.scene.inputOpen && !fixture.scene.inputLeaving }
        fixture.scene.openSettings()
        try await SwiftUIReplay.wait { !fixture.scene.settingsTransitioning && fixture.navigation.mounted }
        fixture.scene.toggleInput(); fixture.scene.toggleNotePanel(); fixture.scene.toggleMoku()
        #expect(fixture.scene.inputOpen && !fixture.scene.notePanelOpen && !fixture.scene.mokuOpen)
        try await click(window, point: CGPoint(x: 50, y: 60))
        #expect(fixture.closeRequests == 1)
        try await SwiftUIReplay.wait { !fixture.scene.settingsOpen }
        #expect(fixture.backgroundClicks == 0 && fixture.scene.inputOpen && fixture.draft.text == "Keep draft")
        try await click(window, point: CGPoint(x: 50, y: 60))
        #expect(fixture.backgroundClicks == 1)
        fixture.scene.setNotePanelOpen(true)
        try await SwiftUIReplay.wait { fixture.scene.notePanelOpen }
        fixture.scene.openSettings()
        try await SwiftUIReplay.wait { !fixture.scene.settingsTransitioning }
        fixture.scene.receiveTalk(.init(id: "covered-talk", text: "Arrived during Settings"))
        try escape(window)
        try await SwiftUIReplay.wait { !fixture.scene.settingsOpen }
        #expect(fixture.scene.notePanelOpen && fixture.draft.text == "Keep draft")
        #expect(fixture.scene.talkPresentation.message?.id == "covered-talk")
        fixture.scene.openSettings()
        try await SwiftUIReplay.wait { !fixture.scene.settingsTransitioning }
        fixture.interaction = true
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.scene.settingsOpen && fixture.scene.notePanelOpen)
        #expect(!fixture.interactionMounted)
        let close = fixture.navigation.returnRect
        try await click(window, point: CGPoint(x: close.midX, y: close.midY))
        try await SwiftUIReplay.wait { !fixture.scene.settingsOpen && !fixture.scene.notePanelOpen }
        try await SwiftUIReplay.wait { fixture.interactionMounted && !fixture.interactionFrame.isEmpty }
        try await capture(window, name: "pending-intervention")
        let answer = fixture.interactionFrame
        try await click(window, point: CGPoint(x: answer.midX, y: answer.midY))
        #expect(fixture.answers == 1)
    }

    @Test func reversalsResizeInactiveAndExplicitSettleFenceCompletions() async throws {
        let fixture = SettingsTransitionFixture()
        let window = SwiftUIReplay.window(SettingsTransitionReplay(fixture: fixture))
        defer { window.close(); fixture.dispose() }
        try await SwiftUIReplay.wait { fixture.scene.windowVisible }
        fixture.scene.openSettings()
        try await SwiftUIReplay.wait { fixture.appearances == 1 && fixture.scene.settingsExpanded }
        try await Task.sleep(for: .milliseconds(60))
        fixture.close()
        try await SwiftUIReplay.wait { fixture.scene.settingsClosing && !fixture.scene.settingsExpanded }
        try await Task.sleep(for: .milliseconds(60))
        fixture.scene.openSettings()
        try await SwiftUIReplay.wait { !fixture.scene.settingsTransitioning }
        try await Task.sleep(for: .milliseconds(500))
        #expect(fixture.scene.settingsOpen && fixture.disappearances == 0 && fixture.appearances == 1,
            "open=\(fixture.scene.settingsOpen), mounted=\(fixture.appearances), unmounted=\(fixture.disappearances)")
        fixture.close(); fixture.size = CGSize(width: 700, height: 500)
        try await SwiftUIReplay.wait { !fixture.scene.settingsOpen }
        fixture.scene.openSettings(); fixture.phase = .inactive
        try await SwiftUIReplay.wait { !fixture.scene.settingsTransitioning }
        #expect(fixture.scene.settingsOpen)
        fixture.close(); fixture.scene.settle()
        #expect(!fixture.scene.settingsOpen && !fixture.scene.settingsTransitioning)
        fixture.scene.overviewVisible = false
        fixture.scene.openSettings()
        #expect(!fixture.scene.settingsOpen)
        fixture.scene.overviewVisible = true
        fixture.scene.setMokuOpen(true)
        fixture.scene.openSettings()
        #expect(!fixture.scene.settingsOpen && fixture.scene.mokuOpen)
    }
}
