import AppKit
import Observation
import SwiftUI
import Testing
import MokuseiCore
import MokuseiPluginUI
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif

/// Exercises the shipped AppKit control, not a duplicate of its selection logic.
@MainActor
@Suite(.serializedNative, .requiresDisplay, .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MOKUSEI_READING_PRESENTATION_NATIVE_REPLAY"] == "1",
                "Requires the AppKit loop: python3 tools/verification/reading-presentation/run.py --model-selector"))
struct NativeModelSelectorReplayTests {
    @Test func modelListPreservesIdentityAndKeyboardCancellation() async throws {
        let fixture = ModelSelectorFixture()
        let window = mount(fixture)
        defer { window.orderOut(nil); window.contentView = nil }
        try await settle()
        let button = try selector("Model", window)
        #expect(button.accessibilityValue() as? String == "GPT-6 Sol")
        button.performClick(nil)
        try await settle()
        let popup = try popupContent()
        let unavailable = try #require(views(popup).compactMap { $0 as? NSButton }.first { $0.title == "Unavailable" })
        #expect(!unavailable.isEnabled)
        try capture(popup, "models-dark")
        try key(125, in: popup) // skip disabled item after the current model
        try key(36, in: popup)
        try await settle()
        #expect(fixture.model == "cafe\u{301}")
        #expect(fixture.changes == 1)
        button.performClick(nil)
        try await settle()
        let reopened = try popupContent()
        try key(115, in: reopened)
        try key(53, in: reopened)
        try await settle()
        #expect(fixture.model == "cafe\u{301}") // Escape does not commit keyboard highlight.
        #expect(!NSApp.windows.contains { $0.isVisible && containsPopup($0.contentView) })

        #expect(window.firstResponder === button)
        window.appearance = NSAppearance(named: .aqua)
        button.performClick(nil)
        try await settle()
        let light = try popupContent()
        try capture(light, "models-light")
        try key(0, characters: "GPT-6 Astra", in: light)
        try key(36, in: light)
        try await settle()
        #expect(fixture.model == "astra")
    }

    @Test func reasoningMapsNativeStepsResetAndModelNavigation() async throws {
        let fixture = ModelSelectorFixture()
        let window = mount(fixture)
        defer { window.orderOut(nil); window.contentView = nil }
        try await settle()
        let button = try selector("Reasoning effort", window)
        button.performClick(nil)
        try await settle()
        let popup = try popupContent()
        let slider = try #require(views(popup).compactMap { $0 as? NSSlider }.first)
        #expect(slider.numberOfTickMarks == 3)
        #expect(slider.accessibilityValue() as? String == "High")
        try capture(popup, "reasoning-dark")
        slider.doubleValue = 2
        slider.sendAction(slider.action, to: slider.target)
        try await settle()
        #expect(fixture.effort == "opaque/max")
        let reset = try #require(views(popup).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Model default" })
        reset.performClick(nil)
        try await settle()
        #expect(fixture.effort == "")
        #expect(slider.accessibilityValue() as? String == "Model default")
        try key(124, in: popup)
        try await settle()
        #expect(fixture.effort == "native/low")
        let models = try #require(views(popup).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Choose model" })
        models.performClick(nil)
        try await settle()
        #expect(popup.frame.height > 150)
        try key(119, in: popup)
        try key(36, in: popup)
        try await settle()
        #expect(fixture.model == "cafe\u{301}")
        #expect(fixture.effort == "native/low") // Model dependency policy belongs to the binding owner.
    }

    @Test func refreshRetiresPopupAndSingleChoiceRemainsSelectable() async throws {
        let fixture = ModelSelectorFixture()
        let window = mount(fixture)
        defer { window.orderOut(nil); window.contentView = nil }
        try await settle()
        let button = try selector("Reasoning effort", window)
        button.performClick(nil)
        try await settle()
        fixture.effort = ""
        fixture.efforts = [.init(id: "", label: "Choose", disabled: true), .init(id: "fixed", label: "Fixed")]
        try await settle()
        #expect(!NSApp.windows.contains { $0.isVisible && containsPopup($0.contentView) })
        button.performClick(nil)
        try await settle()
        let popup = try popupContent()
        let fixed = try #require(views(popup).compactMap { $0 as? NSButton }.first { $0.title == "Fixed" })
        fixed.performClick(nil)
        try await settle()
        #expect(fixture.effort == "fixed")
        fixture.enabled = false
        try await settle()
        #expect(!button.isEnabled)
        #expect(!NSApp.windows.contains { $0.isVisible && containsPopup($0.contentView) })
    }

    private func mount(_ fixture: ModelSelectorFixture) -> NSWindow {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: .init(x: 180, y: 180, width: 480, height: 460),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: ModelSelectorSurface(fixture: fixture))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }
    private func settle() async throws { try await Task.sleep(for: .milliseconds(250)) }
    private func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    private func selector(_ label: String, _ window: NSWindow) throws -> NSButton {
        let root = try #require(window.contentView)
        return try #require(views(root).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == label })
    }
    private func containsPopup(_ root: NSView?) -> Bool {
        guard let root else { return false }
        return views(root).contains { String(describing: type(of: $0)) == "ModelSelectorContent" }
    }
    private func popupContent(sourceLocation: SourceLocation = #_sourceLocation) throws -> NSView {
        try #require(NSApp.windows.filter(\.isVisible).compactMap(\.contentView).flatMap(views)
            .first { String(describing: type(of: $0)) == "ModelSelectorContent" }, sourceLocation: sourceLocation)
    }
    private func key(_ code: UInt16, characters: String = "", in view: NSView) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        let window = try #require(view.window)
        window.sendEvent(event)
    }
    private func capture(_ view: NSView, _ name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["MOKUSEI_MODEL_SELECTOR_ARTIFACTS"] else { return }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }
}

@MainActor @Observable private final class ModelSelectorFixture {
    var model: JSONText = "sol"
    var effort: JSONText = "native/high"
    var changes = 0
    var enabled = true
    let models: [NativeSettingsOption] = [
        .init(id: "", label: "Default"), .init(id: "astra", label: "GPT-6 Astra"),
        .init(id: "sol", label: "GPT-6 Sol"), .init(id: "unavailable", label: "Unavailable", disabled: true),
        .init(id: "cafe\u{301}", label: "Decomposed identifier")
    ]
    var efforts: [NativeSettingsOption] = [
        .init(id: "", label: "Model default"), .init(id: "native/low", label: "Low"),
        .init(id: "hidden", label: "Unavailable", disabled: true),
        .init(id: "native/high", label: "High"), .init(id: "opaque/max", label: "Max")
    ]
}

private struct ModelSelectorSurface: View {
    let fixture: ModelSelectorFixture
    private var model: Binding<JSONText> {
        // Match Harness bindings that replace a complete captured profile.
        let effortAtRender = fixture.effort
        return .init(get: { fixture.model }, set: {
            fixture.model = $0; fixture.effort = effortAtRender; fixture.changes += 1
        })
    }
    var body: some View {
        VStack(spacing: 20) {
            NativeModelSelector(value: model, options: fixture.models, accessibilityLabel: "Model")
            NativeModelSelector(value: .init(get: { fixture.effort }, set: { fixture.effort = $0 }),
                options: fixture.efforts, presentation: .reasoning,
                model: .init(value: model, options: fixture.models, label: "Choose model"), accessibilityLabel: "Reasoning effort")
                .disabled(!fixture.enabled)
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
