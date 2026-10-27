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
struct NativeMokuCompletionMotionTests {
    @Test func keyboardSelectionScrollsTheThinIndicatorListIntoView() async throws {
        let mentions = NativeMokuDirectoryMentions()
        let directories = (0..<12).map { NativeComposerDirectory(name: JSONText("Directory \($0)"), path: JSONText("/tmp/directory-\($0)")) }
        await mentions.load(enabled: true, using: { directories })
        mentions.update(.init(text: "@", selection: NSRange(location: 1, length: 0), focused: true, composing: false))
        let window = SwiftUIReplay.window(NativeMokuDirectoryMentionList(mentions: mentions, maxHeight: 260, onChoose: { _ in }),
            width: 560, height: 260)
        defer { window.close() }
        let root = try #require(window.contentView)
        func findScroll(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap(findScroll).first
        }
        try await SwiftUIReplay.wait { findScroll(root)?.documentView?.bounds.height ?? 0 > 300 }
        let scroll = try #require(findScroll(root))
        try await Task.sleep(for: .milliseconds(150))
        let content = try #require(scroll.documentView).bounds.height
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 100))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await SwiftUIReplay.wait { scroll.contentView.bounds.minY >= 99 }
        let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
        for _ in 0..<11 { #expect(mentions.handle(.init(key: .down), draft: draft)) }
        try await SwiftUIReplay.wait { scroll.contentView.bounds.maxY >= content - 12 }
        #expect(mentions.index == 11)
    }

    @Test func completionKeepsTheEditorOnItsBottomSeatAcrossEntryExitAndReversal() async throws {
        let state = NativeMokuSceneState()
        state.setWindowVisible(true)
        state.setInputOpen(true)
        let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
        let directories = (0..<12).map { NativeComposerDirectory(name: JSONText("Directory \($0)"), path: JSONText("/tmp/directory-\($0)")) }
        let window = SwiftUIReplay.window(NativeMokuDock(state: state, draft: draft, cwd: "/tmp",
            loadMentionDirectories: { directories }, onSend: { _ in }, onCancel: {}).environment(\.colorScheme, .dark), width: 900, height: 600)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await Task.sleep(for: .milliseconds(600))
        let editor = try #require(SwiftUIReplay.editor(in: root))
        func seat() -> CGRect { editor.convert(editor.bounds, to: root) }
        let baseline = seat()
        for (iteration, delay) in [500, 70, 500].enumerated() {
            editor.insertText("@", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            var entryDrift: CGFloat = 0
            var capturedEntry = false
            let start = ContinuousClock.now
            while ContinuousClock.now - start < .milliseconds(delay) {
                root.layoutSubtreeIfNeeded()
                entryDrift = max(entryDrift, abs(seat().midY - baseline.midY))
                if !capturedEntry, ContinuousClock.now - start > .milliseconds(40) {
                    try capture(root, name: "entry-mid-\(iteration)"); capturedEntry = true
                }
                try await Task.sleep(for: .milliseconds(16))
            }
            #expect(entryDrift < 2, "Editor drifted during completion entry: \(entryDrift)pt")
            if delay == 500 { #expect(state.capsuleFrame.height > 200) }
            try capture(root, name: "entry-\(iteration)")
            editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
            editor.insertText("", replacementRange: editor.selectedRange())
            var exitDrift: CGFloat = 0
            var capturedExit = false
            let close = ContinuousClock.now
            while ContinuousClock.now - close < .milliseconds(500) {
                root.layoutSubtreeIfNeeded()
                exitDrift = max(exitDrift, abs(seat().midY - baseline.midY))
                if !capturedExit, ContinuousClock.now - close > .milliseconds(100) {
                    try capture(root, name: "exit-mid-\(iteration)"); capturedExit = true
                }
                try await Task.sleep(for: .milliseconds(16))
            }
            #expect(exitDrift < 2, "Editor drifted during completion exit: \(exitDrift)pt")
            #expect(state.capsuleFrame.height == 58)
            try capture(root, name: "exit-\(iteration)")
        }
        #expect(draft.text.isEmpty)
        #expect(SwiftUIReplay.editor(in: root) === editor)
        #expect(state.inputOpen)
    }
    private func capture(_ root: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["MOKUSEI_MOKU_MOTION_EVIDENCE"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let window = try #require(root.window)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber),
            directory.appendingPathComponent("\(name).png").path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
