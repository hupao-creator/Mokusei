import AppKit
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

@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized) struct NativeMokuVoiceTranscriptLayoutTests {
    @Test func streamingWrapDoesNotTemporarilyOverflowAndLongInputRemainsScrollable() async throws {
        for width in [CGFloat(320), 900] {
            let state = NativeMokuSceneState()
            state.setWindowVisible(true)
            let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
            let input = TranscriptSurfaceInput()
            input.message = .init(id: "session:item", text: "First partial")
            let host = NSHostingView(rootView: TranscriptSurface(state: state, draft: draft, input: input)
                .environment(\.colorScheme, width == 320 ? .light : .dark))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 500),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            await settle(host)
            let scroll = try #require(findScroll(host))
            let textWidth = min(560, width - 48) - NativeMokuTalkTypography.leading - 48
            let source = String(repeating: "实时转写 English words keep growing. ", count: 30)
            var previousHeight: CGFloat = 0
            for count in 1...source.count {
                let text = String(source.prefix(count))
                let height = NativeMokuTalkTypography.height(text, width: textWidth)
                guard height > previousHeight else { continue }
                guard height <= NativeMokuTalkTypography.maximumHeight else { break }
                previousHeight = height
                input.message = .init(id: "session:item", text: text)
                var overflow: CGFloat = 0
                let start = ContinuousClock.now
                while ContinuousClock.now - start < .milliseconds(480) {
                    host.layoutSubtreeIfNeeded()
                    overflow = max(overflow, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
                    try await Task.sleep(for: .milliseconds(16))
                }
                #expect(overflow <= 0.01, "Transient overflow at wrap: \(overflow)pt, width \(width), text \(text)")
                #expect(findScroll(host) === scroll)
            }
            input.message = .init(id: "session:item", text: source)
            await settle(host)
            let document = try #require(scroll.documentView)
            #expect(document.bounds.height > scroll.contentView.bounds.height * 2)
            #expect(abs(scroll.contentView.bounds.maxY - document.bounds.height) <= 1)
            #expect(scroll.hasVerticalScroller)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: 30))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(60))
            let readingPosition = scroll.contentView.bounds.minY
            input.message = .init(id: "session:item", text: source + " More live words.")
            await settle(host)
            #expect(abs(scroll.contentView.bounds.minY - readingPosition) <= 1)
            #expect(findScroll(host) === scroll)
            #expect(SwiftUIReplay.text(in: host).contains(source + " More live words."))
        }
    }

    private func findScroll(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap(findScroll).first
    }

    @Test func existingCapsuleTransitionAndTextKitFitNarrowLightAndDarkSurfaces() async throws {
        for (width, scheme) in [(CGFloat(320), ColorScheme.light), (CGFloat(900), ColorScheme.dark)] {
            let state = NativeMokuSceneState()
            state.setWindowVisible(true)
            let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
            draft.text = "Retained typed draft"
            let input = TranscriptSurfaceInput()
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 500),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: TranscriptSurface(state: state, draft: draft, input: input)
                .environment(\.colorScheme, scheme))
            window.contentView = host
            defer { window.close() }
            await settle(host)
            #expect(state.capsuleFrame.width == 168 && state.capsuleFrame.height == 44)
            #expect(state.dockHitRects.contains { $0.contains(state.capsuleFrame) })

            input.message = .init(id: "session:item", text: "First partial")
            await settle(host)
            let expanded = state.capsuleFrame
            #expect(expanded.width == min(560, width - 48) && expanded.height >= 58)
            #expect(state.dockHitRects.contains { $0.contains(expanded) })
            let root = host
            #expect(SwiftUIReplay.text(in: root).contains("First partial"))

            let long = String(repeating: "流式转写保留完整文本 Streamed input\n", count: 30)
            input.message = .init(id: "session:item", text: long)
            await settle(host)
            #expect(SwiftUIReplay.text(in: host).contains(long))
            #expect(state.capsuleFrame.height == NativeMokuTalkTypography.maximumHeight + 38)

            // Feedback removes only the ephemeral surface; the existing native
            // transition restores the capsule and never submits/edits the draft.
            input.message = nil
            await settle(host)
            #expect(state.capsuleFrame.width == 168 && state.capsuleFrame.height == 44)
            #expect(state.dockHitRects.contains { $0.contains(state.capsuleFrame) })
            #expect(!state.inputOpen && draft.text == "Retained typed draft")
            #expect(input.sends == 0)
        }
    }

    @Test func transcriptCoveredNotificationsSurviveHistoryAndWindowVisibility() async throws {
        for dispatch in [false, true] {
            for history in [false, true] {
                let state = NativeMokuSceneState()
                state.setWindowVisible(true)
                let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
                let input = TranscriptSurfaceInput()
                input.message = .init(id: "session:input", text: "Foreground user transcript")
                let host = NSHostingView(rootView: TranscriptSurface(state: state, draft: draft, input: input))
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 500),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host
                defer { window.close() }
                await settle(host)
                let notification: NativeMokuTalkMessage
                if dispatch {
                    let operation: JSONValue = .object(["type": .text("tool-operation"), "id": .text("dispatch"),
                        "executionId": .text("execution"), "name": .text("create_thread"),
                        "arguments": .object(["harnessId": .text("codex"), "prompt": .text("Task"), "worktree": .bool(true)])])
                    let thread = try HarnessThread(id: "moku", harnessID: "codex", revision: 1, sessionState: .null,
                        observation: .init(latestExecution: .init(executionID: "execution", status: .running, startedAt: 1)),
                        cwd: "/tmp", settings: .object([:]), createdAt: 1, updatedAt: 2, title: "Moku", tags: [],
                        moku: true, transcript: .array([operation]))
                    notification = try #require(NativeMokuTalkMessage.latest(in: thread))
                } else { notification = .init(id: "talk", text: "Unseen Moku notification") }
                state.receiveTalk(notification)
                await settle(host)
                #expect(SwiftUIReplay.text(in: host).contains("Foreground user transcript"))
                #expect(state.capsuleFrame.width == 560) // Background dispatch cannot shrink ASR to 400pt.
                #expect(!state.talkPresentation.presented)
                if history { state.setMokuOpen(true) } else { state.setWindowVisible(false) }
                await settle(host)
                #expect(state.talkPresentation.message == notification)
                if history { state.setMokuOpen(false) } else { state.setWindowVisible(true) }
                await settle(host)
                #expect(state.talkPresentation.message == notification && !state.talkPresentation.presented)
                #expect(SwiftUIReplay.text(in: host).contains("Foreground user transcript"))
                input.message = nil
                await settle(host)
                #expect(state.talkPresentation.message == notification && state.talkPresentation.presented)
                if dispatch { #expect(state.capsuleFrame.width == 400 && state.capsuleFrame.height == 58) }
                else { #expect(SwiftUIReplay.text(in: host).contains(notification.text)) }
                // Once actually foregrounded, retain the existing consume-on-hide policy.
                state.setWindowVisible(false)
                #expect(state.talkPresentation.message == nil)
                window.close()
            }
        }
    }

    private func settle(_ host: NSView) async {
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(600))
        host.layoutSubtreeIfNeeded()
    }

}

@MainActor @Observable private final class TranscriptSurfaceInput {
    var message: NativeMokuTalkMessage?
    var sends = 0
}

@MainActor private struct TranscriptSurface: View {
    let state: NativeMokuSceneState
    let draft: NativeComposerDraft
    let input: TranscriptSurfaceInput
    var body: some View {
        NativeMokuDock(state: state, draft: draft, cwd: "/tmp", voiceStatusVisible: true,
                       voiceModeActive: true, voiceTranscript: input.message,
                       onSend: { _ in input.sends += 1 }, onCancel: {})
    }
}
