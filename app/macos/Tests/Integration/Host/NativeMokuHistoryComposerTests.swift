import AppKit
import MokuseiCore
import MokuseiPluginUI
import MokuseiPluginAPI
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiUI

@MainActor
@Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeMokuHistoryComposerTests {
    private func editor(in view: NSView) -> NSTextView? { SwiftUIReplay.editor(in: view) }
    private func enter(_ editor: NSTextView, window: NSWindow) throws {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        NSApp.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)))
    }
    @Test func historyKeepsItsEditorAndDraftAcrossFailureSendAndRemount() async throws {
        _ = NSApplication.shared
        let draft = NativeComposerDraft(services: .init(stageFiles: { files, _ in
            files.map { .init(id: "history-file", path: "/tmp/history-file", name: JSONText($0.name),
                mimeType: JSONText($0.mimeType), size: $0.size, kind: .file) }
        }, discardAttachments: { _ in }))
        draft.text = "历史上下文里的跟进"
        draft.insertDirectory(.init(name: "History workspace", path: "/tmp/history-workspace"))
        await draft.importFiles([.init(data: Data("notes".utf8), name: "notes.txt", mimeType: "text/plain")])
        var reject = true
        var submissions: [NativeComposerSubmission] = []
        func composer() -> NativeMokuHistoryComposer {
            NativeMokuHistoryComposer(draft: draft, cwd: "/tmp/history-workspace", suppressInitialFocus: true,
                onSend: { submission in
                    submissions.append(submission)
                    if reject { throw PluginContractError("history admission failed") }
                }, onCancel: {})
        }
        let host = NSHostingView(rootView: composer())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 220),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let input = try #require(editor(in: host))
        try enter(input, window: window)
        try await Task.sleep(for: .milliseconds(100))
        #expect(submissions.count == 1)
        #expect(submissions.first?.directories.first?.path == "/tmp/history-workspace")
        #expect(submissions.first?.attachments.first?.id == "history-file")
        #expect(draft.text == "历史上下文里的跟进")
        #expect(draft.attachments.count == 1)
        #expect(draft.error == "history admission failed")
        #expect(editor(in: host) === input)
        #expect(input.isEditable)
        #expect(host.fittingSize.height < 180)

        reject = false
        try enter(input, window: window)
        try await Task.sleep(for: .milliseconds(100))
        #expect(submissions.count == 2)
        #expect(draft.text.isEmpty && draft.attachments.isEmpty && draft.directories.isEmpty)
        #expect(draft.error == nil)
        #expect(editor(in: host) === input)
        #expect(input.isEditable)
        #expect(host.fittingSize.height == 58)
        // Escape leaves the permanent history editor mounted and editable.
        input.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
        #expect(editor(in: host) === input)
        #expect(input.isEditable)
        draft.text = "发送后继续写草稿"
        host.rootView = composer()
        try await Task.sleep(for: .milliseconds(100))
        #expect(draft.text == "发送后继续写草稿")
        #expect(!draft.isDisposed)
        // Disappearing/history navigation does not own draft teardown.
        window.contentView = nil
        #expect(!draft.isDisposed)
        #expect(draft.text == "发送后继续写草稿")
    }
    @Test(arguments: [320.0, 560.0])
    func historyInputGrowsToTheOriginalDockLimit(width: Double) async throws {
        _ = NSApplication.shared
        let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
        let host = NSHostingView(rootView: NativeMokuHistoryComposer(draft: draft, cwd: "/tmp",
            focusEnabled: false, onSend: { _ in }, onCancel: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(host.fittingSize.height == 58)
        draft.text = Array(repeating: "A multiline history draft", count: 30).joined(separator: "\n")
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let input = try #require(editor(in: host))
        #expect(input.isEditable)
        #expect(host.fittingSize.height == 126)
        #expect(input.string == draft.text)
    }

    @Test func inactiveComposerDoesNotMountAVoiceEntry() async throws {
        _ = NSApplication.shared
        let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
        var mounts = 0
        func composer(active: Bool) -> NativeMokuHistoryComposer {
            NativeMokuHistoryComposer(draft: draft, cwd: "/tmp", focusEnabled: false,
                activeVoiceControls: AnyView(Text("voice").onAppear { mounts += 1 }),
                voiceModeActive: active, onSend: { _ in }, onCancel: {})
        }
        let inactive = SwiftUIReplay.window(composer(active: false), width: 560, height: 160)
        defer { inactive.close() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(mounts == 0)

        // A call that was already active keeps its stop/mute control. It is not
        // an entry point because the inactive composer never mounts it.
        let active = SwiftUIReplay.window(composer(active: true), width: 560, height: 160)
        defer { active.close() }
        try await SwiftUIReplay.wait { mounts == 1 }
        #expect(mounts == 1)
    }

    @Test(arguments: [false, true])
    func persistedDraftConsumesLateAcceptedReceiptWithoutClearingNewEdits(editAfterReopen: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("composer-persistence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = NativeComposerDraftPersistence(storageDirectory: directory.appendingPathComponent("host-a"), scope: "moku")
        let otherHost = NativeComposerDraftPersistence(storageDirectory: directory.appendingPathComponent("host-b"), scope: "moku")
        let services = NativeComposerServices(stageFiles: { _, _ in [] }, discardAttachments: { _ in })
        let original = NativeComposerDraft(services: services, persistence: persistence)
        let other = NativeComposerDraft(services: services, persistence: otherHost)
        original.text = "发送前保存的草稿"
        original.insertDirectory(.init(name: "Project", path: "/host/project", hostID: "host-a"))
        other.text = "另一台主机的草稿"
        var receipt: CheckedContinuation<Void, Never>?
        let sending = Task { @MainActor in
            await original.submit { _ in await withCheckedContinuation { receipt = $0 } }
        }
        try await SwiftUIReplay.wait { receipt != nil }
        await original.dispose()

        let reopened = NativeComposerDraft(services: services, persistence: persistence)
        #expect(reopened.text == "发送前保存的草稿")
        #expect(reopened.directories.first?.hostID == "host-a")
        let window = SwiftUIReplay.window(NativeMokuHistoryComposer(draft: reopened, cwd: "/host/project",
            focusEnabled: false, onSend: { _ in }, onCancel: {}), width: 560, height: 220)
        defer { window.close() }
        try await SwiftUIReplay.wait { editor(in: window.contentView!) != nil }
        if editAfterReopen { reopened.text = "重新打开后继续编辑" }
        receipt?.resume(); receipt = nil
        await sending.value
        let expected = editAfterReopen ? "重新打开后继续编辑" : ""
        try await SwiftUIReplay.wait { editor(in: window.contentView!)?.string == expected }
        #expect(reopened.text == expected)
        #expect(reopened.directories.isEmpty == !editAfterReopen)
        let reloaded = NativeComposerDraft(services: services, persistence: persistence)
        #expect(reloaded.text == expected)
        #expect(NativeComposerDraft(services: services, persistence: otherHost).text == "另一台主机的草稿")
        #expect(reopened.error == nil && reloaded.error == nil)
    }

    @Test(arguments: [false, true])
    func offlineHistoryCanEditLocalDraftWithoutSending(offlineEditing: Bool) async throws {
        let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in
            Issue.record("Offline editing must not stage attachments"); return []
        }, discardAttachments: { _ in }))
        draft.text = "已有草稿"
        var sends = 0
        func composer() -> some View {
            NativeMokuHistoryComposer(draft: draft, cwd: "/tmp", disabled: true,
                suppressInitialFocus: true, onSend: { _ in sends += 1 }, onCancel: {})
                .environment(\.nativeOfflineDraftEditing, offlineEditing)
        }
        func nativeEditor(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap { nativeEditor(in: $0) }.first
        }
        let window = SwiftUIReplay.window(composer(), width: 560, height: 220)
        defer { window.close() }
        try await SwiftUIReplay.wait { nativeEditor(in: window.contentView!) != nil }
        let input = try #require(nativeEditor(in: window.contentView!))
        #expect(input.isEditable == offlineEditing)
        if offlineEditing {
            window.makeFirstResponder(input)
            input.insertText("，离线继续编辑", replacementRange: NSRange(location: input.string.utf16.count, length: 0))
            try await SwiftUIReplay.wait { draft.text == "已有草稿，离线继续编辑" }
            try enter(input, window: window)
            try await Task.sleep(for: .milliseconds(100))
            #expect(sends == 0)
            #expect(draft.text == "已有草稿，离线继续编辑")
            window.contentView = NSHostingView(rootView: composer())
            try await SwiftUIReplay.wait { nativeEditor(in: window.contentView!)?.string == draft.text }
            #expect(nativeEditor(in: window.contentView!)?.isEditable == true)
        } else {
            #expect(draft.text == "已有草稿" && sends == 0)
        }
    }

}
