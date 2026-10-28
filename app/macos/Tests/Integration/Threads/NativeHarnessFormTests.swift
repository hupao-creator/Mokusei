import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
@testable import MokuseiHarnessPi
@testable import MokuseiHarnessOpenCode

/// Mounted production Harness controls fed by a native catalog and Go-produced
/// form projections. No settings selection or public-ID algorithm lives here.
@MainActor
@Suite(.serializedNative, .requiresDisplay, .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MOKUSEI_HARNESS_FORM_FIXTURE"] != nil,
                "Requires Go form projections: python3 tools/verification/reading-presentation/run.py --harness-forms"))
struct NativeHarnessFormTests {
    @Observable final class PiDraft {
        var value: JSONValue = .object(["useDefaultThreadSettings": .bool(false), "threadSettings": .object([
            "provider": .text("alpha/beta"), "model": .text("delta"), "thinkingLevel": .text("low")
        ])])
    }
    private struct PiEditor: View {
        let draft: PiDraft
        let resource: HarnessSettingsResource<JSONValue>
        let controls: NativeSettingsInteractions
        let context: NativeSettingsInteractionContext
        var body: some View {
            PiHarnessPlugin().harnessSettings(props: .init(section: .thread, executionSnapshot: true,
                settingsFormPage: true, value: draft.value, resource: resource, host: nil,
                change: { draft.value = $0 }))
                .environment(\.locale, Locale(identifier: "en-US"))
                .environment(\.nativeSettingsInteractions, controls)
                .environment(\.nativeSettingsInteractionContext, context)
                .environment(\.nativeSettingsInteractionRefresh, controls.refresh)
                .padding(24)
        }
    }

    @Test func piModelSelectionRetainsTheCatalogTupleAcrossRemount() async throws {
        let catalog: JSONValue = .object(["cli": .object(["status": .text("ready")]), "models": .array([
            .object(["provider": .text("alpha"), "id": .text("beta/gamma"), "name": .text("Collision first"), "thinkingLevels": .array([.text("low")])]),
            .object(["provider": .text("alpha/beta"), "id": .text("delta"), "name": .text("Standby"), "thinkingLevels": .array([.text("low")])]),
            .object(["provider": .text("alpha/beta"), "id": .text("gamma"), "name": .text("Collision second"), "thinkingLevels": .array([.text("low")])])
        ])])
        let checked = try PiHarnessPlugin().settingsPresentationCodec.decode(catalog)
        let resource = HarnessSettingsResource(state: .ready(checked), reload: { _ in checked })
        let draft = PiDraft(), controls = NativeSettingsInteractions()
        let context = NativeSettingsInteractionContext(visit: UUID(), section: "pi")
        func control(_ id: String) -> JSONValue? { controls.snapshot(context: context).first { $0["id"] == .text(id) } }
        let window = mount(PiEditor(draft: draft, resource: resource, controls: controls, context: context))
        defer { window.close() }
        try await wait { control("pi.model")?["options"]?.arrayValue?.contains { $0["label"]?.stringValue?.contains("Collision second") == true } == true }
        let model = try #require(control("pi.model"))
        let options = try #require(model["options"]?.arrayValue)
        #expect(!options.contains { $0["label"]?.stringValue?.contains("Collision first") == true })
        let selected = try #require(options.first { $0["label"]?.stringValue?.contains("Collision second") == true })
        try controls.perform(id: "pi.model", handle: try #require(model["handle"]?.stringValue),
            operation: "select", value: try #require(selected["id"]), context: context)
        try await wait { draft.value["threadSettings"]?["model"] == .text("gamma") }
        #expect(draft.value["threadSettings"]?["provider"] == .text("alpha/beta"))
        #expect(draft.value["threadSettings"]?["thinkingLevel"] == .text("low"))

        window.close()
        let reopened = mount(PiEditor(draft: draft, resource: resource, controls: controls, context: context))
        defer { reopened.close() }
        try await wait { control("pi.provider")?["value"] == .text("alpha/beta") }
        let reopenedModel = try #require(control("pi.model"))
        #expect(reopenedModel["options"]?.arrayValue?.first { $0["id"] == reopenedModel["value"] }?["label"]?.stringValue?.contains("Collision second") == true)
    }

    @Test func nativeReaderAdoptsDefaultsAndSubmitsWithOptionalAndInactiveFieldsAbsent() async throws {
        let (interaction, state) = try fixture(modeDefault: true)
        let native = try #require(state.nativeInteraction(interaction.id))
        #expect(native["id"]?.stringValue?.contains("<&") == true)
        var sent: HarnessRespondRequest?
        let window = mount(OpenCodeInteractionPanel(interaction: interaction, native: native,
            actions: actions { sent = $0 }).environment(\.locale, Locale(identifier: "en-US")))
        defer { window.close() }
        let root = try #require(window.contentView)
        try await wait { textFields(root).contains { $0.stringValue == "DEFAULT_FROM_NATIVE" } }
        #expect(textFields(root).count == 2)
        #expect(!labels(root).contains(where: { $0.contains("HIDDEN_FIELD_MUST_NOT_APPEAR") || $0.contains("ONLY_MODE_B_MUST_NOT_APPEAR_FOR_A") }))
        try await wait { button("Submit", root).map(isEnabled) == true }
        try press(try #require(button("Submit", root)))
        try await wait { sent != nil }
        try expectModeAResponse(try #require(sent), interaction: interaction)
    }

    @Test func publicReaderFiltersConditionalFieldsAndKeepsOptionalInputEmpty() async throws {
        let (interaction, state) = try fixture(modeDefault: false)
        // Both surfaces receive the same Go-generated public identity. The
        // fallback deliberately has no private payload, so metadata must suffice.
        #expect(state.nativeInteraction(interaction.id) != nil)
        var sent: HarnessRespondRequest?
        let window = mount(OpenCodeInteractionPanel(interaction: interaction, native: nil,
            actions: actions { sent = $0 }).environment(\.locale, Locale(identifier: "en-US")))
        defer { window.close() }
        let root = try #require(window.contentView)
        try await wait { textFields(root).contains { $0.stringValue == "DEFAULT_FROM_NATIVE" } && button("Mode B", root) != nil }
        #expect(textFields(root).count == 2)
        #expect(!labels(root).contains(where: { $0.contains("HIDDEN_FIELD_MUST_NOT_APPEAR") || $0.contains("ONLY_MODE_B_MUST_NOT_APPEAR_FOR_A") }))
        try press(try #require(button("Mode B", root)))
        try await wait { textFields(root).count == 3 }
        #expect(button("Submit", root).map(isEnabled) == false)
        let conditional = try #require(textFields(root).first { $0.accessibilityLabel() == "ONLY_MODE_B_MUST_NOT_APPEAR_FOR_A" })
        try edit(conditional, text: "local mode-B draft", window: window)
        try await wait { button("Submit", root).map(isEnabled) == true }
        try press(try #require(button("Mode A", root)))
        try await wait { textFields(root).count == 2 && button("Submit", root).map(isEnabled) == true }
        #expect(!labels(root).contains(where: { $0.contains("ONLY_MODE_B_MUST_NOT_APPEAR_FOR_A") }))
        try press(try #require(button("Submit", root)))
        try await wait { sent != nil }
        try expectModeAResponse(try #require(sent), interaction: interaction)
    }

    @Test(arguments: [false, true])
    func readerCancelIsAvailableBeforeRequiredModeAnswer(useNative: Bool) async throws {
        let (interaction, state) = try fixture(modeDefault: false)
        let native = try #require(state.nativeInteraction(interaction.id))
        var sent: HarnessRespondRequest?
        let window = mount(OpenCodeInteractionPanel(interaction: interaction, native: useNative ? native : nil,
            actions: actions { sent = $0 }).environment(\.locale, Locale(identifier: "en-US")))
        defer { window.close() }
        let root = try #require(window.contentView)
        try await wait { button("Cancel", root).map(isEnabled) == true }
        #expect(button("Submit", root).map(isEnabled) == false)
        try press(try #require(button("Cancel", root)))
        try await wait { sent != nil }
        #expect(sent?.actionID == "cancel" && sent?.answers == nil)
    }

    private func fixture(modeDefault: Bool) throws -> (PublicInteraction, OpenCodeState) {
        let path = try #require(ProcessInfo.processInfo.environment["MOKUSEI_HARNESS_FORM_FIXTURE"])
        let fixtures = try #require(try JSONValue(data: Data(contentsOf: URL(fileURLWithPath: path))).arrayValue)
        let value = try #require(fixtures.first { $0["modeDefault"] == .bool(modeDefault) })
        return (try PublicInteraction(json: #require(value["interaction"])),
                try OpenCodeState(#require(value["nativeState"])))
    }
    private func expectModeAResponse(_ response: HarnessRespondRequest, interaction: PublicInteraction) throws {
        let fields = try #require(response.answers)
        let note = try #require(interaction.questions.first { $0.prompt == "Default note" })
        let mode = try #require(interaction.questions.first { $0.prompt == "Select mode" })
        let modeA = try #require(mode.options.first { $0.label == "Mode A" })
        #expect(response.interactionID == interaction.id && response.actionID == "submit")
        #expect(fields.count == 2)
        #expect(fields[note.id] == .text("DEFAULT_FROM_NATIVE"))
        #expect(fields[mode.id] == .text(modeA.value))
    }
    private func actions(_ respond: @escaping (HarnessRespondRequest) -> Void) -> HarnessThreadActions {
        .init(interrupt: {}, respond: { respond($0) }, invokeHarnessExtension: { _, _ in .null },
              forkThread: { _ in "unused" }, openExternal: { _ in }, openFollowUp: { _ in })
    }
    private func mount<Content: View>(_ content: Content) -> NSWindow {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular); app.activate(ignoringOtherApps: true)
        let enable = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        if app.responds(to: enable) { _ = app.perform(enable, with: true, with: "AXEnhancedUserInterface") }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 760, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content.frame(width: 760, height: 700).accessibilityElement(children: .contain))
        window.makeKeyAndOrderFront(nil)
        return window
    }
    private func wait(sourceLocation: SourceLocation = #_sourceLocation, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            for window in NSApp?.windows ?? [] { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        for window in NSApp?.windows ?? [] {
            guard let root = window.contentView, window.isVisible else { continue }
            print("HARNESS AX LABELS", labels(root))
            print("HARNESS NATIVE FIELDS", textFields(root).map { [$0.stringValue, $0.accessibilityLabel() ?? ""] })
        }
        try #require(predicate(), "Mounted Harness controls did not settle", sourceLocation: sourceLocation)
    }
    private func edit(_ field: NSTextField, text: String, window: NSWindow) throws {
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    }
    private func textFields(_ view: NSView) -> [NSTextField] {
        if let field = view as? NSTextField, field.isEditable { return [field] }
        return view.subviews.flatMap(textFields)
    }
    private func nodes(_ root: NSView) -> [NSObject] {
        var seen: Set<ObjectIdentifier> = [], result: [NSObject] = []
        func visit(_ object: AnyObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted, seen.count < 10000,
                  let node = object as? NSObject else { return }
            result.append(node)
            let children = NSSelectorFromString("accessibilityChildren")
            if node.responds(to: children), let values = node.perform(children)?.takeUnretainedValue() as? [AnyObject] { values.forEach(visit) }
            let legacy = NSSelectorFromString("accessibilityAttributeValue:")
            if node.responds(to: legacy), let values = node.perform(legacy, with: "AXChildren")?.takeUnretainedValue() as? [AnyObject] { values.forEach(visit) }
            if let view = node as? NSView { view.subviews.forEach(visit) }
        }
        _ = root.window?.accessibilityChildren()
        visit(root.window ?? root)
        return result
    }
    private func label(_ node: NSObject) -> String? {
        let selector = NSSelectorFromString("accessibilityLabel")
        guard node.responds(to: selector) else { return nil }
        return node.perform(selector)?.takeUnretainedValue() as? String
    }
    private func labels(_ root: NSView) -> [String] { nodes(root).compactMap(label) }
    private func button(_ title: String, _ root: NSView) -> NSObject? {
        nodes(root).first { node in
            let selector = NSSelectorFromString("accessibilityRole")
            let role = node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() as? String : nil
            return role == "AXButton" && label(node) == title && node.responds(to: NSSelectorFromString("accessibilityPerformPress"))
        }
    }
    private func isEnabled(_ node: NSObject) -> Bool {
        if let accessible = node as? any NSAccessibilityProtocol { return accessible.isAccessibilityEnabled() }
        let selector = NSSelectorFromString("accessibilityAttributeValue:")
        if node.responds(to: selector), let enabled = node.perform(selector, with: "AXEnabled")?.takeUnretainedValue() as? Bool { return enabled }
        // SwiftUI's AX nodes expose the modern getter through KVC without
        // declaring NSAccessibilityProtocol or the legacy attribute interface.
        guard node.responds(to: NSSelectorFromString("isAccessibilityEnabled")) else { return false }
        return node.value(forKey: "accessibilityEnabled") as? Bool ?? false
    }
    private func press(_ node: NSObject) throws {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        try #require(node.responds(to: selector))
        _ = node.perform(selector)
    }
}
