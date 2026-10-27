import AppKit
import Observation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiPluginUI

@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeComposerCompositionTests {
    @MainActor @Observable final class Model {
        var text = "前👋 后"
        var revision = 0
        var state: NativeComposerEditorState?
        var selectionRequest: NativeComposerSelectionRequest?
        var submits = 0
        var keys = 0
    }
    private struct Fixture: View {
        @Bindable var model: Model
        var body: some View {
            NativeComposerTextInput(value: $model.text, placeholder: "Compose \(model.revision)",
                automaticFocus: false, onSubmit: { model.submits += 1 }, selectionRequest: model.selectionRequest,
                onEditorStateChange: { model.state = $0 }, onKeyDown: { _ in model.keys += 1; return false })
        }
    }

    @Test func markedTextAndCommitSurviveRenders() async throws {
        let model = Model()
        let window = SwiftUIReplay.window(Fixture(model: model), width: 420, height: 180)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        let root = try #require(window.contentView)
        let editor = try #require(SwiftUIReplay.editor(in: root))
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        for (marked, committed) in [("ni", "你"), ("hao", "好")] {
            editor.setMarkedText(marked, selectedRange: NSRange(location: marked.utf16.count, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            editor.didChangeText()
            let expected = editor.string, markedRange = editor.markedRange(), selectedRange = editor.selectedRange()
            model.revision += 1
            try await Task.sleep(for: .milliseconds(100))
            #expect(SwiftUIReplay.editor(in: root) === editor)
            #expect(editor.string == expected)
            #expect(editor.markedRange() == markedRange)
            #expect(editor.selectedRange() == selectedRange)
            #expect(editor.hasMarkedText())
            #expect(model.state?.composing == true)
            editor.insertText(committed, replacementRange: NSRange(location: NSNotFound, length: 0))
            editor.didChangeText()
            model.revision += 1
            try await Task.sleep(for: .milliseconds(100))
            #expect(!editor.hasMarkedText())
            #expect(model.text == editor.string)
            #expect(model.state?.composing == false)
        }
        #expect(editor.string == "前👋 你好后")
        #expect(model.text == "前👋 你好后")
    }
    @Test func controlledUpdatesAndSelectionWaitForComposition() async throws {
        let model = Model()
        let window = SwiftUIReplay.window(Fixture(model: model), width: 420, height: 180)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        let root = try #require(window.contentView)
        let editor = try #require(SwiftUIReplay.editor(in: root))
        editor.setSelectedRange(NSRange(location: 4, length: 1))
        editor.setMarkedText("shi", selectedRange: NSRange(location: 3, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.didChangeText()
        try await Task.sleep(for: .milliseconds(100))
        let marked = editor.markedRange(), selected = editor.selectedRange(), text = editor.string
        model.text = "stale controlled update"
        model.selectionRequest = .init(range: NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        #expect(editor.string == text)
        #expect(editor.markedRange() == marked)
        #expect(editor.selectedRange() == selected)
        #expect(model.state?.composing == true)
        editor.insertText("世", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.didChangeText()
        try await Task.sleep(for: .milliseconds(100))
        #expect(editor.string == "前👋 世")
        #expect(model.text == "前👋 世")
        #expect(editor.selectedRange() == NSRange(location: 0, length: 0))
        #expect(model.state?.composing == false)
        // A genuine controlled change after the commit still takes effect.
        model.text = "new draft 👋"
        try await Task.sleep(for: .milliseconds(100))
        #expect(editor.string == model.text)
        model.text = ""
        try await Task.sleep(for: .milliseconds(100))
        #expect(editor.string.isEmpty)
        editor.insertText("again", replacementRange: NSRange(location: NSNotFound, length: 0))
        model.revision += 1
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.text == "again" && editor.string == "again")
    }

    @Test func unmarkWithoutTextChangePublishesCompositionEnd() async throws {
        let model = Model()
        let window = SwiftUIReplay.window(Fixture(model: model), width: 420, height: 180)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        let root = try #require(window.contentView)
        let editor = try #require(SwiftUIReplay.editor(in: root))
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        editor.setMarkedText("你", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.didChangeText()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.state?.composing == true)
        editor.unmarkText()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.state?.composing == false)
        #expect(model.text == "前👋 你后")
        #expect(model.state?.selection == editor.selectedRange())
    }

    @Test func candidateKeysStayNativeAndCommandReturnStillSubmits() async throws {
        let model = Model()
        let window = SwiftUIReplay.window(Fixture(model: model), width: 420, height: 180)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        let root = try #require(window.contentView)
        let editor = try #require(SwiftUIReplay.editor(in: root))
        func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        editor.setSelectedRange(NSRange(location: model.text.utf16.count, length: 0))
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.keyDown(with: try key(125, "\u{F701}"))
        #expect(model.keys == 0)
        #expect(model.submits == 0)
        editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        let committed = editor.string
        editor.keyDown(with: try key(36, "\r"))
        #expect(editor.string == committed + "\n")
        #expect(model.submits == 0)
        editor.keyDown(with: try key(36, "\r", modifiers: .command))
        #expect(model.submits == 1)
        #expect(model.text == editor.string)
    }

}
