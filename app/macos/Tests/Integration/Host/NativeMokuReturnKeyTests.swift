import AppKit
import MokuseiCore
import MokuseiPluginUI
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiUI

@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeMokuReturnKeyTests {
    private func enter(_ window: NSWindow, modifiers: NSEvent.ModifierFlags = []) throws {
        window.makeKeyAndOrderFront(nil)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        NSApp.sendEvent(event)
    }

    @Test func mokuReturnPrecedenceNewlinesCompositionAndAttachments() async throws {
        let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in
            [.init(id: "file", path: "/tmp/file", name: "file", mimeType: "text/plain", size: 1, kind: .file)]
        }, discardAttachments: { _ in }))
        await draft.importFiles([.init(data: Data([1]), name: "file", mimeType: "text/plain")])
        var submissions: [NativeComposerSubmission] = []
        let directory = NativeComposerDirectory(name: "Alpha", path: "/tmp/alpha")
        let window = SwiftUIReplay.window(NativeMokuHistoryComposer(draft: draft, cwd: "/tmp",
            loadMentionDirectories: { [directory] }, onSend: { submissions.append($0) }, onCancel: {}), width: 560, height: 400)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { SwiftUIReplay.editor(in: root) != nil }
        let editor = try #require(SwiftUIReplay.editor(in: root))
        editor.insertText("Hello", replacementRange: NSRange(location: 0, length: 0))
        try await SwiftUIReplay.wait { draft.text == "Hello" }
        for modifiers: NSEvent.ModifierFlags in [.command, .shift] {
            let before = editor.string
            try enter(window, modifiers: modifiers)
            try await SwiftUIReplay.wait { editor.string == before + "\n" && draft.text == editor.string }
            #expect(submissions.isEmpty)
        }
        try enter(window, modifiers: .control)
        #expect(submissions.isEmpty) // macOS has no Ctrl+Return send alias.
        editor.insertText("@Al", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await SwiftUIReplay.wait { draft.text == "@Al" && root.fittingSize.height > 100 }
        try await Task.sleep(for: .milliseconds(100))
        try enter(window)
        try await SwiftUIReplay.wait { draft.directories == [directory] && draft.text.isEmpty && editor.string.isEmpty }
        #expect(submissions.isEmpty)
        #expect(draft.attachments.count == 1)
        editor.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        try enter(window) // Confirmation belongs to the input method.
        #expect(submissions.isEmpty)
        // Explicitly finish the synthetic composition if the active system IME
        // leaves it marked; real language candidate selection is system-owned.
        editor.unmarkText()
        editor.insertText(" ready", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await SwiftUIReplay.wait { draft.text == editor.string && draft.text.contains("ready") }
        try enter(window)
        try await SwiftUIReplay.wait { submissions.count == 1 }
        #expect(submissions.first?.directories == [directory])
        #expect(submissions.first?.attachments.first?.id == "file")
    }

    @Test func anotherEditorInTheSameWindowCannotSendMoku() async throws {
        let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
        draft.text = "Moku draft"
        var sent = false
        let window = SwiftUIReplay.window(VStack {
            NativeMokuHistoryComposer(draft: draft, cwd: "/tmp", onSend: { _ in sent = true }, onCancel: {})
            TextEditor(text: .constant("Other editor"))
        }, width: 560, height: 400)
        defer { window.close() }
        let root = try #require(window.contentView)
        func editors(_ view: NSView) -> [NSTextView] {
            if let text = view as? NSTextView { return [text] }
            return view.subviews.flatMap(editors)
        }
        try await SwiftUIReplay.wait { editors(root).count == 2 }
        let other = try #require(editors(root).last)
        window.makeFirstResponder(other)
        try enter(window)
        #expect(!sent)
        #expect(draft.text == "Moku draft")
    }

    @Test func sharedComposerRetainsItsDefaultReturnBehavior() async throws {
        let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
        var sends = 0
        let window = SwiftUIReplay.window(NativeComposerTextInput(value: Binding(get: { draft.text }, set: { draft.text = $0 }),
            placeholder: "Shared composer", onSubmit: { sends += 1 }), width: 560, height: 150)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { SwiftUIReplay.editor(in: root) != nil }
        let editor = try #require(SwiftUIReplay.editor(in: root))
        editor.insertText("Default", replacementRange: NSRange(location: 0, length: 0))
        try await SwiftUIReplay.wait { draft.text == "Default" }
        try enter(window)
        try await SwiftUIReplay.wait { draft.text == "Default\n" }
        #expect(sends == 0)
        try enter(window, modifiers: .command)
        #expect(sends == 1)
    }
}
