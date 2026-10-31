import AppKit
import MokuseiCore
import MokuseiNativeInputSupport
import MokuseiPluginUI
import MokuseiPluginAPI
import Synchronization
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiUI

/// Supply timed input independently of AppKit layout and tracking. Apple permits
/// postEvent from secondary threads; event creation and posting stay together.
private final class MokuHoldInputClock: Sendable {
    struct Delivery: Sendable {
        let name: String
        let planned: UInt64
        let began: UInt64
        let ended: UInt64
        let posted: Bool
        var latenessMilliseconds: Double { Double(Int64(ended) - Int64(planned)) / 1e6 }
    }
    struct Receipt: Sendable {
        var down: UInt64?
        var deliveries: [Delivery] = []
        var cancelled = false
    }
    private struct Input: Sendable {
        let name: String
        let type: NSEvent.EventType
        let delay: UInt64
        let point: CGPoint
    }
    private let application: NSApplication
    private let windowNumber: Int
    private let eventNumber: Int
    private let phase: String
    private let inputs: [Input]
    private let receipt = Mutex(Receipt())
    private let timer: any DispatchSourceTimer

    init(application: NSApplication, windowNumber: Int, eventNumber: Int,
         phase: String, point: CGPoint, duration: TimeInterval, drag: Bool) {
        self.application = application; self.windowNumber = windowNumber
        self.eventNumber = eventNumber; self.phase = phase
        let release = Input(name: "release", type: .leftMouseUp,
                            delay: UInt64(duration * 1e9), point: point)
        inputs = drag ? [Input(name: "drag", type: .leftMouseDragged, delay: 100_000_000,
                               point: CGPoint(x: point.x + 20, y: point.y)), release] : [release]
        timer = DispatchSource.makeTimerSource(flags: .strict,
            queue: DispatchQueue(label: "com.mokusei.test.hold-input.\(eventNumber)", qos: .userInteractive))
        timer.setEventHandler { [weak self] in self?.postNext() }
        timer.activate()
    }

    deinit { timer.cancel() }

    func arm(at down: UInt64) {
        receipt.withLock { value in
            guard value.down == nil, !value.cancelled else { return }
            value.down = down
            schedule(down + inputs[0].delay)
        }
    }

    func snapshot() -> Receipt { receipt.withLock { $0 } }

    func cancel() {
        // Synchronize cancellation with posting, so cleanup cannot leave an
        // in-progress handler that injects another gesture's late event.
        receipt.withLock { value in value.cancelled = true; timer.cancel() }
    }

    private func schedule(_ deadline: UInt64) {
        timer.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline),
                       repeating: .never, leeway: .nanoseconds(0))
    }

    private func postNext() {
        let message = receipt.withLock { value -> String? in
            guard !value.cancelled, let down = value.down,
                  value.deliveries.count < inputs.count else { return nil }
            let input = inputs[value.deliveries.count]
            let planned = down + input.delay
            let began = DispatchTime.now().uptimeNanoseconds
            guard began >= planned else { schedule(planned); return nil }
            let posted = MokuseiPostMouseEvent(application, input.type, input.point,
                ProcessInfo.processInfo.systemUptime, windowNumber, eventNumber)
            let delivery = Delivery(name: input.name, planned: planned, began: began,
                                    ended: DispatchTime.now().uptimeNanoseconds, posted: posted)
            value.deliveries.append(delivery)
            let message = "MOKU_COMPOSER_INPUT hold.\(phase).clock.\(input.name) "
                + "plannedNanoseconds=\(planned) beganNanoseconds=\(began) endedNanoseconds=\(delivery.ended) "
                + "posted=\(posted) latenessMilliseconds=\(delivery.latenessMilliseconds)\n"
            if value.deliveries.count < inputs.count { schedule(down + inputs[value.deliveries.count].delay) }
            else { timer.cancel() }
            return message
        }
        if let message { FileHandle.standardOutput.write(Data(message.utf8)) }
    }
}

@MainActor
@Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeMokuHistoryComposerTests {
    @MainActor private final class HoldReceipt {
        var downDispatchedAt: UInt64?
        var dragDispatchedAt: UInt64?
        var upDispatchedAt: UInt64?

        var summary: String {
            "downDispatchedNanoseconds=\(String(describing: downDispatchedAt)) "
                + "dragDispatchedNanoseconds=\(String(describing: dragDispatchedAt)) "
                + "upDispatchedNanoseconds=\(String(describing: upDispatchedAt))"
        }
    }

    private static func inputPhase(_ phase: String) {
        // Write directly so a blocked AppKit tracking loop cannot strand buffered diagnostics.
        FileHandle.standardOutput.write(Data("MOKU_COMPOSER_INPUT \(phase) uptime=\(ProcessInfo.processInfo.systemUptime)\n".utf8))
    }

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
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOKUSEI_READING_PRESENTATION_NATIVE_REPLAY"] == "1",
                   "Requires AppKit native mouse tracking: python3 tools/verification/reading-presentation/run.py --moku-composer"))
    func ordinaryClickFocusesAndPersistsExactUnicodeReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = NativeComposerDraftPersistence(storageDirectory: directory, scope: "moku")
        let services = NativeComposerServices(stageFiles: { _, _ in [] }, discardAttachments: { _ in })
        let draft = NativeComposerDraft(services: services, persistence: persistence)
        Self.inputPhase("click.mount.begin")
        let window = SwiftUIReplay.window(NativeMokuHistoryComposer(draft: draft, cwd: "/tmp",
            suppressInitialFocus: true, onSend: { _ in }, onCancel: {}), width: 560, height: 220)
        Self.inputPhase("click.mount.returned")
        defer { window.close() }
        try await SwiftUIReplay.wait { editor(in: window.contentView!) != nil }
        let input = try #require(editor(in: window.contentView!))
        Self.inputPhase("click.editor.ready")
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
        Self.inputPhase("click.mouseUp.post.begin")
        NSApp.postEvent(up, atStart: true)
        Self.inputPhase("click.mouseUp.post.returned")
        Self.inputPhase("click.mouseDown.send.begin")
        NSApp.sendEvent(down)
        Self.inputPhase("click.mouseDown.send.returned")
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.firstResponder === input)
        Self.inputPhase("unicode.persistence.begin")
        input.insertText("é", replacementRange: NSRange(location: 0, length: input.string.utf16.count))
        input.insertText("e\u{301}", replacementRange: NSRange(location: 0, length: input.string.utf16.count))
        try await SwiftUIReplay.wait { Array(draft.text.utf16) == [0x65, 0x301] }
        #expect(Array(input.string.utf16) == [0x65, 0x301])
        let restored = NativeComposerDraft(services: services, persistence: persistence)
        #expect(Array(restored.text.utf16) == [0x65, 0x301])
        Self.inputPhase("unicode.persistence.checked")
        try await mountedEditorHoldStartsOnceAndRetainsDraft()
        Self.inputPhase("click-and-hold.completed")
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
        var activeHold = "none"
        Self.inputPhase("hold.mount.begin")
        let window = SwiftUIReplay.window(NativeMokuHistoryComposer(draft: draft, cwd: "/tmp",
            onSend: { _ in }, onCancel: {}, canStartVoice: { available }, startVoice: {
                starts += 1
                Self.inputPhase("hold.\(activeHold).startVoice starts=\(starts) monotonicNanoseconds=\(DispatchTime.now().uptimeNanoseconds)")
            }), width: 560, height: 180)
        Self.inputPhase("hold.mount.returned")
        defer { window.close() }
        try await SwiftUIReplay.wait {
            guard let view = monitor(in: window.contentView!) else { return false }
            return view.bounds.width > 100 && view.bounds.height >= 58 && window.isKeyWindow && NSApp.isActive
        }
        let view = try #require(monitor(in: window.contentView!))
        let recognizer = try #require(window.contentView?.gestureRecognizers.first { $0.target === view } as? NSPressGestureRecognizer)
        let application = NSApplication.shared
        Self.inputPhase("hold.monitor.ready")
        let event: @MainActor @Sendable (NSEvent.EventType, CGPoint, Int) -> NSEvent = { type, point, eventNumber in
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: eventNumber, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        var nextEventNumber = 100
        @MainActor func hold(_ phase: String, duration: TimeInterval, drag: Bool = false) async throws {
            activeHold = phase
            Self.inputPhase("hold.\(phase).begin")
            window.makeKeyAndOrderFront(nil)
            try await SwiftUIReplay.wait { window.isKeyWindow && NSApp.isActive && recognizer.state == .possible }
            Self.inputPhase("hold.\(phase).ready")
            let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            let eventNumber = nextEventNumber
            nextEventNumber += 1
            let minimumPressDuration = recognizer.minimumPressDuration
            let receipt = HoldReceipt()
            let clock = MokuHoldInputClock(application: application, windowNumber: window.windowNumber,
                                          eventNumber: eventNumber, phase: phase, point: point, duration: duration, drag: drag)
            let observer = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { incoming in
                MainActor.assumeIsolated {
                    guard incoming.window === window, incoming.eventNumber == eventNumber else { return }
                    let dispatched = DispatchTime.now().uptimeNanoseconds
                    if incoming.type == .leftMouseUp {
                        receipt.upDispatchedAt = dispatched
                        Self.inputPhase("hold.\(phase).mouseUp.dispatch")
                        return
                    }
                    if incoming.type == .leftMouseDragged {
                        receipt.dragDispatchedAt = dispatched
                        Self.inputPhase("hold.\(phase).mouseDragged.dispatch")
                        return
                    }
                    guard receipt.downDispatchedAt == nil else { return }
                    receipt.downDispatchedAt = dispatched
                    clock.arm(at: dispatched)
                    Self.inputPhase("hold.\(phase).mouseDown.dispatch monotonicNanoseconds=\(dispatched) "
                        + "minimumPressDuration=\(minimumPressDuration) releaseDelay=\(duration) drag=\(drag)")
                }
                return incoming
            }
            let monitor = try #require(observer)
            defer {
                clock.cancel()
                NSEvent.removeMonitor(monitor)
                Self.inputPhase("hold.\(phase).cleanup \(receipt.summary) recognizer=\(recognizer.state)")
            }
            // Queue the whole gesture in order. A synchronous down from this
            // Swift task can overtake the preceding queued up and reenter tracking.
            NSApp.postEvent(event(.leftMouseDown, point, eventNumber), atStart: false)
            Self.inputPhase("hold.\(phase).mouseDown.queued eventNumber=\(eventNumber)")
            let deadline = ContinuousClock.now + .seconds(3)
            var settled = false
            while ContinuousClock.now < deadline {
                let posted = clock.snapshot().deliveries
                // No geometry changes during a hold: forced layout/display here
                // would compete with AppKit's event handling and input deadlines.
                // .possible alone is initial state; actual release posting is required.
                let released = posted.contains { $0.name == "release" && $0.posted }
                let moved = !drag || posted.contains { $0.name == "drag" && $0.posted }
                if receipt.downDispatchedAt != nil, released, moved, recognizer.state == .possible {
                    settled = true
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            Self.inputPhase("hold.\(phase).settled \(receipt.summary)")
            try #require(settled, Comment(rawValue: "Input replay did not post release and settle within 3 seconds: " + receipt.summary))
            let supplied = clock.snapshot()
            let down = try #require(supplied.down)
            try #require(supplied.deliveries.count == (drag ? 2 : 1))
            for delivery in supplied.deliveries {
                try #require(delivery.posted && delivery.began >= delivery.planned
                             && delivery.latenessMilliseconds <= 50,
                    Comment(rawValue: "Input supply missed its fixed deadline: hold.\(phase).\(delivery.name), lateness \(delivery.latenessMilliseconds)ms"))
            }
            let recognitionDeadline = down + UInt64(minimumPressDuration * 1e9)
            if drag {
                let movement = try #require(supplied.deliveries.first { $0.name == "drag" })
                try #require(movement.ended < recognitionDeadline,
                    "Input replay posted drag after the recognizer's actual minimum press duration")
                // Nested text tracking can consume drag/up without a local
                // monitor callback. Keep those observations optional; the
                // unchanged starts assertions still check actual recognition.
                if let dispatched = receipt.dragDispatchedAt {
                    try #require(dispatched < recognitionDeadline,
                        "Input replay dispatched drag after the recognizer's actual minimum press duration")
                }
            } else if duration < minimumPressDuration {
                let release = try #require(supplied.deliveries.first { $0.name == "release" })
                try #require(release.ended < recognitionDeadline,
                    "Input replay posted a short release after the recognizer's actual minimum press duration")
                if let dispatched = receipt.upDispatchedAt {
                    try #require(dispatched < recognitionDeadline,
                        "Input replay dispatched a short release after the recognizer's actual minimum press duration")
                }
            }
        }
        #expect(view.hitTest(.zero) == nil)
        try await hold("short", duration: 0.1)
        #expect(starts == 0)
        try await hold("drag", duration: 0.8, drag: true)
        #expect(starts == 0)
        try await hold("long", duration: 0.8)
        #expect(starts == 1)
        #expect(draft.text == "保持这份草稿")
        available = false
        try await hold("unavailable", duration: 0.8)
        #expect(starts == 1)
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
