import AppKit
import MokuseiPluginUI
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiUI

@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeMokuLongPressVoiceTests {
    private func monitor(in view: NSView) -> NativeMokuLongPressVoiceMonitor.MonitorView? {
        if let monitor = view as? NativeMokuLongPressVoiceMonitor.MonitorView { return monitor }
        return view.subviews.lazy.compactMap { monitor(in: $0) }.first
    }

    @Test func inactiveAndReadOnlyEditorsCannotArmVoice() async throws {
        let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
        var starts = 0
        let window = SwiftUIReplay.window(NativeMokuComposerInput(draft: draft, readOnly: true,
            canStartVoice: { true }, startVoice: { starts += 1 }, onSend: {}), width: 560, height: 180)
        defer { window.close() }
        try await SwiftUIReplay.wait { monitor(in: window.contentView!) != nil }
        let view = try #require(monitor(in: window.contentView!))
        let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.receive(event)
        view.sample(at: window.convertPoint(toScreen: point), pressed: true, now: ProcessInfo.processInfo.systemUptime + 1)
        #expect(starts == 0)
    }
}
