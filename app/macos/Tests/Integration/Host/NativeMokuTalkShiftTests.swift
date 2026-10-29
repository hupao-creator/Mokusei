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

@MainActor @Observable private final class TalkShiftInput {
    var running = true
    var text: String? = nil
}

@MainActor private struct TalkShiftSurface: View {
    let state: NativeMokuSceneState
    let draft: NativeComposerDraft
    let input: TalkShiftInput
    var body: some View {
        NativeMokuDock(state: state, draft: draft, cwd: "/tmp", running: input.running, talk: input.text,
                       onSend: { _ in }, onCancel: {})
    }
}

@MainActor @Suite(.serializedNative, .serialized, .requiresDisplay)
struct NativeMokuTalkShiftTests {
    private func descendants<T: NSView>(_ root: NSView, of type: T.Type) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants($0, of: type) }
    }

    @Test func retiringStopKeepsTalkViewportStable() async throws {
        let text = "这就是消息的结尾。A talk message that stays put while the execution settles."
        for width: CGFloat in [320, 900] {
            let state = NativeMokuSceneState()
            state.setWindowVisible(true)
            let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
            let input = TalkShiftInput()
            let host = NSHostingView(rootView: TalkShiftSurface(state: state, draft: draft, input: input))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 500),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            func scroll() throws -> NSScrollView {
                try #require(descendants(host, of: NSScrollView.self).first { SwiftUIReplay.text(in: $0).contains(text) })
            }
            try await Task.sleep(for: .milliseconds(700))
            input.text = text
            try await Task.sleep(for: .milliseconds(1000))
            host.layoutSubtreeIfNeeded()
            let before = try scroll().convert(try scroll().bounds, to: host)
            input.running = false
            try await Task.sleep(for: .milliseconds(700))
            host.layoutSubtreeIfNeeded()
            let after = try scroll().convert(try scroll().bounds, to: host)
            #expect(abs(before.width - after.width) < 0.5)
            #expect(abs(before.midX - after.midX) < 0.5, "Talk viewport shifted horizontally after Stop retired at width \(width)")
        }
    }
}
