import AppKit
import MokuseiCore
import MokuseiPluginUI
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiUI

@MainActor
@Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeMokuComposerSelectionTests {
    @Test func reopeningTheDockInputRestoresSelection() async throws {
        _ = NSApplication.shared
        let state = NativeMokuSceneState()
        state.setWindowVisible(true)
        state.setInputOpen(true)
        let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
        draft.text = "alpha beta gamma"
        let window = SwiftUIReplay.window(NativeMokuDock(state: state, draft: draft, cwd: "/tmp",
            onSend: { _ in }, onCancel: {}), width: 900, height: 600)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { SwiftUIReplay.editor(in: root)?.string == draft.text }
        let editor = try #require(SwiftUIReplay.editor(in: root))
        window.makeFirstResponder(editor)
        let selection = NSRange(location: 6, length: 4)
        editor.setSelectedRange(selection)
        try await Task.sleep(for: .milliseconds(100))

        state.setInputOpen(false)
        try await SwiftUIReplay.wait { !state.inputLeaving }
        try #require(SwiftUIReplay.editor(in: root) == nil)

        state.setInputOpen(true)
        try await SwiftUIReplay.wait {
            guard let reopened = SwiftUIReplay.editor(in: root),
                  reopened.string == draft.text, window.firstResponder === reopened else { return false }
            return reopened.selectedRange() == selection
        }
    }
}
