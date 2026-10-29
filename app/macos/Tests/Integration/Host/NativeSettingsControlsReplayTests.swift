import AppKit
import SwiftUI
import Testing
import MokuseiCore
import MokuseiPluginUI
import MokuseiTestSupport

@MainActor @Suite(.serializedNative, .requiresDisplay)
struct NativeSettingsControlsReplayTests {
    @Test(arguments: NativeSelectSurface.allCases)
    func systemPopupPreservesIdentityAndDisabledChoices(surface: NativeSelectSurface) async throws {
        let fixture = NativeFormFixture()
        let window = SwiftUIReplay.window(NativeFormReplay(fixture: fixture, surface: surface), width: 540, height: 420)
        defer { window.orderOut(nil); window.contentView = nil }
        func popup() -> NSPopUpButton? {
            guard let content = window.contentView else { return nil }
            return descendants(content).compactMap { $0 as? NSPopUpButton }.first
        }
        try await SwiftUIReplay.wait { popup()?.numberOfItems == 3 }
        let control = try #require(popup())
        #expect(control.accessibilityLabel() == "Choice")
        #expect(control.itemArray.filter { $0.title == "Same name" }.count == 2)
        #expect(control.item(at: 0)?.isEnabled == false)
        #expect(control.titleOfSelectedItem == "Choose")
        #expect(fixture.writes == 0)
        control.selectItem(at: 2)
        NSApp.sendAction(try #require(control.action), to: control.target, from: control)
        #expect(fixture.selection == JSONText("cafe\u{301}"))
        #expect(fixture.discrete && fixture.writes == 1)

        fixture.selection = "unavailable"
        try await SwiftUIReplay.wait { control.titleOfSelectedItem == "unavailable" }
        #expect(control.selectedItem?.isEnabled == false)
        #expect(fixture.writes == 1)
        fixture.enabled = false
        try await SwiftUIReplay.wait { !control.isEnabled }
        control.selectItem(withTitle: "Same name")
        NSApp.sendAction(try #require(control.action), to: control.target, from: control)
        #expect(fixture.selection == "unavailable" && fixture.writes == 1)

        fixture.enabled = true
        fixture.options = [.init(id: "unavailable", label: "Retired", disabled: true),
                           .init(id: "new/native", label: "Refreshed")]
        try await SwiftUIReplay.wait { control.isEnabled && control.titleOfSelectedItem == "Retired" }
        #expect(control.selectedItem?.isEnabled == false)
        control.selectItem(at: 1)
        NSApp.sendAction(try #require(control.action), to: control.target, from: control)
        #expect(fixture.selection == "new/native" && fixture.writes == 2)
        fixture.options = [.init(id: "new/native", label: "Only choice")]
        try await SwiftUIReplay.wait { control.numberOfItems == 1 && control.titleOfSelectedItem == "Only choice" }
        #expect(control.isEnabled && fixture.writes == 2)
        fixture.options = [.init(id: "new/native", label: "Unavailable", disabled: true)]
        try await SwiftUIReplay.wait { !control.isEnabled }
        #expect(fixture.selection == "new/native" && fixture.writes == 2)
    }

    @Test func nativeInputAndTextareaKeepEditingAndUndo() async throws {
        let fixture = NativeFormFixture()
        let window = SwiftUIReplay.window(NativeFormReplay(fixture: fixture), width: 540, height: 420)
        defer { window.orderOut(nil); window.contentView = nil }
        let content = try #require(window.contentView)
        try await SwiftUIReplay.wait { SwiftUIReplay.textField(in: content) != nil }
        let field = try #require(SwiftUIReplay.textField(in: content))
        window.makeFirstResponder(field)
        let input = try #require(field.currentEditor() as? NSTextView)
        input.insertText("typed", replacementRange: NSRange(location: 0, length: 0))
        try await SwiftUIReplay.wait { fixture.text == "typed" }
        let editor = try #require(descendants(content).compactMap { $0 as? NSTextView }
            .first { !$0.isFieldEditor })
        #expect(editor.enclosingScrollView?.borderType == .bezelBorder)
        window.makeFirstResponder(editor)
        let undo = try #require(editor.undoManager)
        // The window shares Undo across its field editor and text views. Start
        // this document's assertion independently of the input typed above.
        undo.removeAllActions()
        editor.breakUndoCoalescing()
        editor.insertText("guidance", replacementRange: NSRange(location: 0, length: 0))
        editor.breakUndoCoalescing()
        try await SwiftUIReplay.wait { fixture.guidance == "guidance" }
        // The native typing event must finish before invoking Undo.
        try await SwiftUIReplay.wait { undo.groupingLevel == 0 }
        #expect(undo.canUndo)
        undo.undo()
        try await SwiftUIReplay.wait { fixture.guidance.isEmpty }
        #expect(undo.canRedo)
        undo.redo()
        try await SwiftUIReplay.wait { fixture.guidance == "guidance" }
        fixture.enabled = false
        try await SwiftUIReplay.wait { !editor.isEditable && !field.isEnabled }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

@MainActor @Observable private final class NativeFormFixture {
    var options: [NativeSettingsOption] = [
        .init(id: "", label: "Choose", disabled: true),
        .init(id: "first", label: "Same name"),
        .init(id: JSONText("cafe\u{301}"), label: "Same name")
    ]
    var selection: JSONText = ""
    var text = ""
    var guidance = ""
    var enabled = true
    var writes = 0
    var discrete = false
}

enum NativeSelectSurface: CaseIterable, Sendable {
    case settings, settingsModel, settingsReasoning, onboarding, onboardingModel, onboardingReasoning

    var onboarding: Bool {
        switch self {
        case .onboarding, .onboardingModel, .onboardingReasoning: true
        default: false
        }
    }
}

private struct NativeFormReplay: View {
    @Bindable var fixture: NativeFormFixture
    var surface: NativeSelectSurface = .settings
    var body: some View {
        Group {
            VStack {
                NativeSettingsRow(label: "Choice") {
                    select
                }
                NativeSettingsRow(label: "Input") { NativeSettingsInput(value: $fixture.text) }
                NativeSettingsRow(label: "Guidance", layout: .stacked) { NativeSettingsTextarea(value: $fixture.guidance) }
            }.disabled(!fixture.enabled).padding(20)
        }.environment(\.nativeSettingsFormPage, !surface.onboarding)
            .environment(\.nativeSettingsCompactPresentation, surface.onboarding)
            .environment(\.locale, Locale(identifier: "en_US"))
    }

    @ViewBuilder private var select: some View {
        let binding = Binding(get: { fixture.selection }, set: {
            fixture.selection = $0; fixture.writes += 1
            fixture.discrete = NativeSettingsChangeContext.isDiscreteChange
        })
        switch surface {
        case .settings, .onboarding:
            NativeSettingsSelect(value: binding, options: fixture.options)
        case .settingsModel, .onboardingModel:
            NativeModelSelector(value: binding, options: fixture.options)
        case .settingsReasoning, .onboardingReasoning:
            NativeModelSelector(value: binding, options: fixture.options, presentation: .reasoning)
        }
    }
}
