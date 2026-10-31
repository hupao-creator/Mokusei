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
struct NativeMokuHistoryComposerTests {    private func editor(in view: NSView) -> NSTextView? { SwiftUIReplay.editor(in: view) }
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
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOKUSEI_READING_PRESENTATION_NATIVE_REPLAY"] == "1",
                   "Requires AppKit native mouse tracking: python3 tools/verification/reading-presentation/run.py --moku-composer"))
    func ordinaryClickFocusesAndPersistsExactUnicodeReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = NativeComposerDraftPersistence(storageDirectory: directory, scope: "moku")
        let services = NativeComposerServices(stageFiles: { _, _ in [] }, discardAttachments: { _ in })
        let draft = NativeComposerDraft(services: services, persistence: persistence)
        let window = SwiftUIReplay.window(NativeMokuHistoryComposer(draft: draft, cwd: "/tmp",
            suppressInitialFocus: true, onSend: { _ in }, onCancel: {}), width: 560, height: 220)
        defer { window.close() }
        try await SwiftUIReplay.wait { editor(in: window.contentView!) != nil }
        let input = try #require(editor(in: window.contentView!))
        window.makeFirstResponder(nil)
        let point = input.convert(CGPoint(x: 12, y: 8), to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        // NSTextView can enter synchronous selection tracking inside mouseDown.
        // Queue the real release first so that tracking can consume the complete
        // click without waiting for this test's main-actor continuation.
        NSApp.postEvent(up, atStart: true)
        NSApp.sendEvent(down)
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.firstResponder === input)
        input.insertText("é", replacementRange: NSRange(location: 0, length: input.string.utf16.count))
        input.insertText("e\u{301}", replacementRange: NSRange(location: 0, length: input.string.utf16.count))
        try await SwiftUIReplay.wait { Array(draft.text.utf16) == [0x65, 0x301] }
        #expect(Array(input.string.utf16) == [0x65, 0x301])
        let restored = NativeComposerDraft(services: services, persistence: persistence)
        #expect(Array(restored.text.utf16) == [0x65, 0x301])
        try await mountedEditorHoldStartsOnceAndRetainsDraft()
    }

    private func monitor(in view: NSView) -> NativeMokuLongPressVoiceMonitor.MonitorView? {
        if let monitor = view as? NativeMokuLongPressVoiceMonitor.MonitorView { return monitor }
        return view.subviews.lazy.compactMap { monitor(in: $0) }.first
    }

    private func mountedEditorHoldStartsOnceAndRetainsDraft() async throws {
        let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
        draft.text = "保持这份草稿"
        var starts = 0
        var available = true
        let window = SwiftUIReplay.window(NativeMokuHistoryComposer(draft: draft, cwd: "/tmp",
            onSend: { _ in }, onCancel: {}, canStartVoice: { available }, startVoice: { starts += 1 }), width: 560, height: 180)
        defer { window.close() }
        try await SwiftUIReplay.wait {
            guard let view = monitor(in: window.contentView!) else { return false }
            return view.bounds.width > 100 && view.bounds.height >= 58 && window.isKeyWindow && NSApp.isActive
        }
        let view = try #require(monitor(in: window.contentView!))
        let recognizer = try #require(window.contentView?.gestureRecognizers.first { $0.target === view })
        // `MOKUSEI_DIAG_LONG_PRESS=1` samples the recognizer and app state while a
        // hold is in flight. The sampler only observes; it never sends events or
        // changes recognition, so the default run is byte-for-byte unchanged.
        let diag = LongPressHoldDiag()
        if diag.isEnabled {
            diag.start(window: window, recognizer: recognizer)
        }
        defer { diag.finish("starts=\(starts) resign=\(diag.resignations)") }
        func diagLog(_ message: @autoclosure () -> String) { diag.log(message()) }
        let event: @MainActor @Sendable (NSEvent.EventType, CGPoint) -> NSEvent = { type, point in
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        func hold(duration: TimeInterval, drag: Bool = false) async throws {
            diagLog("hold begin duration=\(duration) drag=\(drag) starts=\(starts)"
                + " state=\(recognizer.state.rawValue) enabled=\(recognizer.isEnabled)")
            window.makeKeyAndOrderFront(nil)
            try await SwiftUIReplay.wait { window.isKeyWindow && NSApp.isActive && recognizer.state == .possible }
            diagLog("hold armed appActive=\(NSApp.isActive) key=\(window.isKeyWindow)"
                + " state=\(recognizer.state.rawValue) enabled=\(recognizer.isEnabled)")
            let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            // Create each event when delivered: pre-creating the release gives
            // AppKit a zero-duration gesture even though the timer waited.
            let sendUp: @MainActor @Sendable () -> Void = { NSApp.postEvent(event(.leftMouseUp, point), atStart: true) }
            let sendDrag: @MainActor @Sendable () -> Void = {
                NSApp.postEvent(event(.leftMouseDragged, CGPoint(x: point.x + 20, y: point.y)), atStart: true)
            }
            let release = Timer(timeInterval: duration, repeats: false) { _ in
                MainActor.assumeIsolated { sendUp() }
            }
            RunLoop.main.add(release, forMode: .common)
            RunLoop.main.add(release, forMode: .eventTracking)
            var movement: Timer?
            if drag {
                let timer = Timer(timeInterval: 0.1, repeats: false) { _ in
                    MainActor.assumeIsolated { sendDrag() }
                }
                RunLoop.main.add(timer, forMode: .common)
                RunLoop.main.add(timer, forMode: .eventTracking)
                movement = timer
            }
            NSApp.sendEvent(event(.leftMouseDown, point))
            diagLog("hold down-sent state=\(recognizer.state.rawValue) enabled=\(recognizer.isEnabled)")
            try await Task.sleep(for: .seconds(duration + 0.1))
            try await SwiftUIReplay.wait { recognizer.state == .possible }
            diagLog("hold end state=\(recognizer.state.rawValue) starts=\(starts) resign=\(diag.resignations)")
            release.invalidate(); movement?.invalidate()
        }
        #expect(view.hitTest(.zero) == nil)
        try await hold(duration: 0.1)
        #expect(starts == 0)
        try await hold(duration: 0.8, drag: true)
        #expect(starts == 0)
        try await hold(duration: 0.8)
        #expect(starts == 1)
        #expect(draft.text == "保持这份草稿")
        available = false
        try await hold(duration: 0.8)
        #expect(starts == 1)
        if diag.isEnabled {
            // A single run cannot distinguish "the press never began" from a run
            // that happened to win the race, so repeat the same hold and report
            // how many attempts actually start.
            available = true
            for attempt in 1...8 {
                let before = starts
                try await hold(duration: 0.8)
                diag.log("repeat \(attempt) started=\(starts > before)")
            }
        }
        // Detachment removes the recognizer owned by this editor.
        let count = window.contentView?.gestureRecognizers.count ?? 0
        view.stop()
        #expect(window.contentView?.gestureRecognizers.count == count - 1)
    }

    @Test func historyExposesExecutionStopAndFirstQuestionCancel() async throws {
        let app = NSApplication.shared
        let enableAX = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        if app.responds(to: enableAX) { _ = app.perform(enableAX, with: true, with: "AXEnhancedUserInterface") }
        var stops = 0
        let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
        let composer = SwiftUIReplay.window(NativeMokuHistoryComposer(draft: draft, cwd: "/tmp", running: true,
            onSend: { _ in }, onCancel: { stops += 1 }), width: 560, height: 180)
        defer { composer.close() }
        let root = try #require(composer.contentView)
        try await SwiftUIReplay.wait { element(id: "moku-stop", in: root) != nil }
        _ = try #require(element(id: "moku-stop", in: root)).perform(NSSelectorFromString("accessibilityPerformPress"))
        #expect(stops == 1)

        let question = PublicInteractionQuestion(id: "first", prompt: "A required first answer", multiple: false,
            allowOther: false, secret: false, options: [.init(value: "yes", label: "Yes")])
        let request = PublicInteraction(id: "wizard", kind: .question, title: "Two questions", actions: [
            .init(id: "submit", intent: .submit, label: "Submit"), .init(id: "cancel", intent: .cancel, label: "Cancel")
        ], questions: [question, .init(id: "second", prompt: "Another required answer", multiple: false,
            allowOther: false, secret: false, options: [.init(value: "no", label: "No")])])
        let intervention = NativeMokuDockIntervention(threadID: "moku", harnessID: "fixture", executionID: "execution",
            threadTitle: "Moku", request: request, questions: PublicInteractionQuestionnaire.specs(for: request), submitActionID: "submit")
        var response: HarnessRespondRequest?
        let panel = SwiftUIReplay.window(NativeMokuDockInteractionPanel(intervention: intervention,
            disabled: false, respond: { response = $0 }), width: 640, height: 360)
        defer { panel.close() }
        let panelRoot = try #require(panel.contentView)
        try await SwiftUIReplay.wait { element(id: "moku-interaction-action-cancel", in: panelRoot) != nil }
        #expect(element(id: "moku-interaction-action-submit", in: panelRoot) == nil)
        _ = try #require(element(id: "moku-interaction-action-cancel", in: panelRoot)).perform(NSSelectorFromString("accessibilityPerformPress"))
        try await SwiftUIReplay.wait { response != nil }
        #expect(response?.actionID == "cancel" && response?.answers == nil)
    }

    private func element(id: String, in root: NSView) -> NSObject? {
        var seen = Set<ObjectIdentifier>()
        func visit(_ object: AnyObject) -> NSObject? {
            guard seen.insert(ObjectIdentifier(object)).inserted, seen.count < 10000,
                  let item = object as? NSObject else { return nil }
            let identity = NSSelectorFromString("accessibilityIdentifier")
            if item.responds(to: identity), item.perform(identity)?.takeUnretainedValue() as? String == id { return item }
            let children = NSSelectorFromString("accessibilityChildren")
            if item.responds(to: children), let values = item.perform(children)?.takeUnretainedValue() as? [AnyObject] {
                for value in values { if let found = visit(value) { return found } }
            }
            // SwiftUI exposes some bridge nodes only through the legacy AX
            // attribute API, even when their ancestors use modern children.
            let legacy = NSSelectorFromString("accessibilityAttributeValue:")
            if item.responds(to: legacy), let values = item.perform(legacy, with: "AXChildren")?.takeUnretainedValue() as? [AnyObject] {
                for value in values { if let found = visit(value) { return found } }
            }
            if let view = item as? NSView {
                for child in view.subviews { if let found = visit(child) { return found } }
            }
            return nil
        }
        _ = root.window?.accessibilityChildren()
        return visit(root.window ?? root)
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

/// Samples a mounted hold under `MOKUSEI_DIAG_LONG_PRESS=1`. It exists so the
/// `@Sendable` timer and notification blocks can reach MainActor state without
/// capturing AppKit objects directly; every field is read on the main actor.
@MainActor
private final class LongPressHoldDiag: @unchecked Sendable {
    let isEnabled = ProcessInfo.processInfo.environment["MOKUSEI_DIAG_LONG_PRESS"] == "1"
    private let origin = Date()
    private var window: NSWindow?
    private var recognizer: NSGestureRecognizer?
    private var observer: NSObjectProtocol?
    private var sampler: Timer?
    private(set) var resignations = 0

    func log(_ message: String) {
        guard isEnabled else { return }
        print("LONGPRESS-TEST +\(String(format: "%.3f", Date().timeIntervalSince(origin)))s \(message)")
    }

    func start(window: NSWindow, recognizer: NSGestureRecognizer) {
        self.window = window
        self.recognizer = recognizer
        log("mounted recognizers=\(window.contentView?.gestureRecognizers.count ?? 0)"
            + " state=\(recognizer.state.rawValue) enabled=\(recognizer.isEnabled)")
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.resignations += 1
                    self.log("resignKey count=\(self.resignations)"
                        + " state=\(self.recognizer?.state.rawValue ?? -1)")
                }
            }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        sampler = timer
    }

    private func sample() {
        guard isEnabled, let window, let recognizer else { return }
        log("sample state=\(recognizer.state.rawValue) enabled=\(recognizer.isEnabled)"
            + " appActive=\(NSApp.isActive) key=\(window.isKeyWindow)"
            + " firstResponderIsEditor=\(window.firstResponder is NSTextView) resign=\(resignations)")
    }

    func finish(_ summary: String) {
        sampler?.invalidate(); sampler = nil
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        log("finished \(summary)")
    }
}
