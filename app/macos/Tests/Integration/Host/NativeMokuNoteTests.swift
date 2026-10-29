import AppKit
import Foundation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
@testable import MokuseiUI

@MainActor @Suite(.serializedNative)
struct NativeMokuNoteTests {
    private func thread(note: JSONValue?, moku: Bool = true) throws -> HarnessThread {
        try HarnessThread(id: "moku", harnessID: "fixture", revision: 0, sessionState: .object([:]),
            observation: .init(latestExecution: nil), cwd: "/tmp", settings: .object([:]),
            createdAt: 1, updatedAt: 2, title: "Moku", tags: [], moku: moku,
            note: note.map { try ThreadNote(json: $0) }, transcript: .array([]))
    }
    private func noteJSON(text: JSONText, revision: Int = 1, updatedAt: Double = 3,
                          id: JSONText = "note-incarnation",
                          extra: [JSONText: JSONValue] = [:]) -> JSONValue {
        var values: [JSONText: JSONValue] = ["id": .string(id), "text": .string(text),
            "revision": .integer(revision), "updatedAt": .number(updatedAt),
            "readingRevision": .integer(0)]
        for (key, value) in extra { values[key] = value }
        return .object(values)
    }
    private func selectableText(_ root: NSView) -> [NSTextView] {
        var result: [NSTextView] = []
        if let view = root as? NSTextView, view.isSelectable, !view.isEditable { result.append(view) }
        for child in root.subviews { result += selectableText(child) }
        return result
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

    @Test func trackpadSwipeRequiresUpwardIntentAndOpensOnlyOnce() {
        var sequence = NativeMokuSwipeSequence()
        func sample(_ y: CGFloat, x: CGFloat = 0, phase: NSEvent.Phase = .changed,
                    momentum: NSEvent.Phase = [], eligible: Bool = true, inside: Bool = true,
                    precise: Bool = true, inverted: Bool = true) -> (consume: Bool, action: NativeMokuSwipeSequence.Action?) {
            sequence.route(x: x, y: y, phase: phase, momentum: momentum,
                precise: precise, inverted: inverted, eligible: eligible, inside: inside)
        }
        #expect(sample(-12, phase: .began).action == nil)
        #expect(sample(-12).action == .note)
        #expect(sample(-50, eligible: false).action == nil)
        #expect(sample(-50, phase: [], momentum: .began, eligible: false).consume)
        #expect(sample(50, phase: .began).action == nil)
        #expect(sample(-40, x: 50, phase: .began).action == nil)
        #expect(!sample(-40, phase: .began, inside: false).consume)
        #expect(sample(-40).action == nil)
        #expect(sample(-40, phase: .began, eligible: false).action == nil)
        #expect(sample(-40, phase: .began, precise: false).action == nil)
        sequence.reset()
        #expect(!sample(-40, phase: [], momentum: .began).consume)
        #expect(sample(-12, phase: .began).action == nil)
        #expect(sample(-12, phase: .cancelled).action == nil)
        #expect(sample(-12, phase: .began).action == nil)
        #expect(sample(-12, inside: false).action == nil)
        #expect(sample(-40).action == nil)
        #expect(sample(24, phase: .began, inverted: false).action == .note)
        #expect(sample(0, x: -12, phase: .began).action == nil)
        #expect(sample(0, x: -12).action == nil)
        #expect(sample(0, x: -50).action == nil)
        #expect(sample(0, x: 30, phase: .began).action == nil)
        #expect(sample(0, x: 30, phase: .began, inverted: false).action == nil)
    }

    @Test func touchSwipeUsesTheSameThresholdAndIgnoresLeftwardInput() {
        let state = NativeMokuSceneState()
        state.setWindowVisible(true)
        var touch = NativeMokuTouchSwipeSequence()
        let start = CGPoint(x: 160, y: 322)
        #expect(touch.begin(at: start, eligible: true, inside: true) == true)
        #expect(touch.move(to: CGPoint(x: 160, y: 299), eligible: true) == nil)
        // A finger may leave the 44-point row while completing an upward swipe.
        #expect(touch.move(to: CGPoint(x: 160, y: 298), eligible: true) == .note)
        state.setNotePanelOpen(true)
        #expect(state.notePanelOpen && !state.inputOpen)
        #expect(touch.move(to: CGPoint(x: 80, y: 240), eligible: true) == nil)
        touch.cancel()
        #expect(touch.begin(at: start, eligible: true, inside: true) == true)
        #expect(touch.move(to: CGPoint(x: 136, y: 322), eligible: true) == nil)
        #expect(!state.inputOpen && state.notePanelOpen)
        #expect(touch.move(to: CGPoint(x: 100, y: 280), eligible: true) == nil)
        state.settle()
    }

    @Test func touchSwipeCannotAcquireMicNoteReadingOrCanvasTouches() {
        let row = CGRect(x: 100, y: 300, width: 168, height: 44)
        let mic = CGRect(x: 221, y: 300, width: 44, height: 44)
        func allowed(_ point: CGPoint, message: Bool = false) -> Bool {
            NativeMokuSwipeTarget.contains(point, row: row, showingMessage: message, excluding: [mic])
        }
        #expect(allowed(CGPoint(x: 160, y: 322)))
        #expect(!allowed(CGPoint(x: 243, y: 322))) // Mic tap and long press.
        #expect(!allowed(CGPoint(x: 160, y: 280))) // Note's reading/scrolling area.
        #expect(!allowed(CGPoint(x: 293, y: 322))) // Separate note button.
        #expect(allowed(CGPoint(x: 132, y: 322), message: true))
        #expect(!allowed(CGPoint(x: 180, y: 322), message: true)) // Talk prose.

        var touch = NativeMokuTouchSwipeSequence()
        #expect(touch.begin(at: CGPoint(x: 95, y: 322), eligible: true, inside: false) == false)
        #expect(touch.move(to: CGPoint(x: 160, y: 280), eligible: true) == nil)
        #expect(touch.begin(at: CGPoint(x: 160, y: 322), eligible: false, inside: true) == false)
        #expect(touch.begin(at: CGPoint(x: 160, y: 322), eligible: true, inside: true) == true)
        #expect(touch.move(to: CGPoint(x: 160, y: 310), eligible: false) == nil)
        #expect(!touch.isTracking)
        #expect(touch.move(to: CGPoint(x: 160, y: 280), eligible: true) == nil)
        #expect(touch.begin(at: CGPoint(x: 160, y: 322), eligible: true, inside: true) == true)
        touch.cancel()
        #expect(touch.move(to: CGPoint(x: 100, y: 322), eligible: true) == nil)
    }

    @Test func touchAndTrackpadAgreeOnDirectionalIntentIncludingNaturalScrolling() {
        let paths: [[CGPoint]] = [
            [.init(x: -12, y: 1), .init(x: -12, y: -1), .init(x: -50, y: -50)],
            [.init(x: 1, y: -12), .init(x: -1, y: -12), .init(x: -50, y: -50)],
            [.init(x: 40, y: 0)], [.init(x: 0, y: 40)], [.init(x: -30, y: -30)],
            [.init(x: 30, y: 0), .init(x: -20, y: -10)]
        ]
        for path in paths {
            for inverted in [false, true] {
                var touch = NativeMokuTouchSwipeSequence(), trackpad = NativeMokuSwipeSequence()
                var point = CGPoint(x: 160, y: 322)
                #expect(touch.begin(at: point, eligible: true, inside: true) == true)
                for (index, delta) in path.enumerated() {
                    point.x += delta.x; point.y += delta.y
                    let expected = trackpad.route(x: inverted ? delta.x : -delta.x,
                        y: inverted ? delta.y : -delta.y, phase: index == 0 ? .began : .changed,
                        momentum: [], precise: true, inverted: inverted, eligible: true, inside: true)
                    #expect(touch.move(to: point, eligible: true) == expected.action)
                }
            }
        }
    }

    @Test func wrongDirectionTouchDragsCannotFallBackToAButtonTap() {
        let start = CGPoint(x: 160, y: 322)
        for offset in [CGPoint(x: 24, y: 0), CGPoint(x: 0, y: 24), CGPoint(x: -20, y: -20)] {
            var touch = NativeMokuTouchSwipeSequence()
            #expect(touch.begin(at: start, eligible: true, inside: true) == true)
            #expect(touch.move(to: CGPoint(x: 166, y: 325), eligible: true) == nil)
            #expect(!touch.hasClaimedDrag)
            #expect(touch.move(to: CGPoint(x: start.x + offset.x, y: start.y + offset.y), eligible: true) == nil)
            #expect(touch.hasClaimedDrag)
            #expect(touch.move(to: start, eligible: true) == nil)
            #expect(touch.hasClaimedDrag)
            touch.cancel()
            #expect(!touch.hasClaimedDrag && !touch.isTracking)
        }
    }

    @Test func contractProjectsAbsentValidAndEmptyNotes() throws {
        #expect(NativeMokuNote.current(in: try thread(note: nil)) == nil)
        let projected = try #require(NativeMokuNote.current(in: try thread(note: noteJSON(
            text: "# Milestones\n\n- merged", revision: 4, updatedAt: 1_700_000_000_000))))
        #expect(projected.id == "note-incarnation")
        #expect(projected.text == "# Milestones\n\n- merged")
        #expect(projected.revision == 4)
        #expect(projected.updatedAt == 1_700_000_000_000)
        #expect(projected.date.timeIntervalSince1970 == 1_700_000_000)
        // The empty clear hides the panel body but retains its text revision.
        let empty = try ThreadNote(json: noteJSON(text: "", revision: 9))
        #expect(empty.isEmpty && empty.revision == 9)
        #expect(NativeMokuNote.current(in: try thread(note: noteJSON(text: "", revision: 9))) == nil)
    }

    @Test func malformedNotesAreRejectedAtTheContractBoundary() throws {
        #expect(throws: PluginContractError.self) { try ThreadNote(json: noteJSON(text: "ok", revision: 0)) }
        #expect(throws: PluginContractError.self) { try ThreadNote(json: noteJSON(text: "a\u{0}b")) }
        #expect(throws: PluginContractError.self) { try ThreadNote(json: noteJSON(text: " \n\t")) }
        #expect(throws: PluginContractError.self) { try ThreadNote(json: noteJSON(
            text: JSONText(String(repeating: "界", count: ThreadNote.maximumCodePoints + 1)))) }
        #expect(throws: PluginContractError.self) { try ThreadNote(json: noteJSON(text: "ok", extra: ["pattern": .text("x")])) }
        #expect(throws: PluginContractError.self) { try ThreadNote(json: .object(["text": .text("ok"),
            "revision": .integer(1), "updatedAt": .number(3), "readingRevision": .integer(0)])) }
        #expect(throws: PluginContractError.self) { try ThreadNote(json: noteJSON(text: "ok", id: "not an id")) }
        #expect(throws: PluginContractError.self) { try ThreadNote(json: noteJSON(text: "ok", extra: ["readingRevision": .integer(-1)])) }
        let exposure: JSONValue = .object(["revision": .integer(2), "text": .text("exact earlier text"),
            "recordedAt": .number(4), "signal": .text("complete-viewport-coverage-v1")])
        let valid = try ThreadNote(json: noteJSON(text: "new text", revision: 3, extra: [
            "readingRevision": .integer(1), "lastExposure": exposure]))
        #expect(valid.lastExposure?.text == "exact earlier text")
        #expect(valid.readingRevision == 1)
        #expect(throws: PluginContractError.self) { try ThreadNote(json: noteJSON(text: "new text", revision: 1,
            extra: ["readingRevision": .integer(1), "lastExposure": exposure])) }
        #expect(throws: PluginContractError.self) { try ThreadNote(json: noteJSON(text: "", revision: 3,
            extra: ["readingRevision": .integer(1), "lastExposure": exposure])) }
        // Only a Moku thread may publish a note.
        #expect(throws: PluginContractError.self) { _ = try thread(note: noteJSON(text: "ok"), moku: false) }
        #expect(ThreadNote.maximumCodePoints == 1200)
    }

    @Test func unreadStateComesFromAuthoritativeExposure() throws {
        let state = NativeMokuSceneState()
        let note = NativeMokuNote(id: "first-incarnation", text: "first", revision: 2, updatedAt: 1)
        #expect(state.noteUnread(note))
        #expect(!state.noteUnread(NativeMokuNote(id: "first-incarnation", text: "", revision: 2, updatedAt: 1)))
        #expect(!state.noteUnread(NativeMokuNote(id: "first-incarnation", text: "copied", revision: 2,
                                                 updatedAt: 9, lastExposureRevision: 2)))
        #expect(state.noteUnread(NativeMokuNote(id: "first-incarnation", text: "newer", revision: 3, updatedAt: 9)))
        // Opening is not evidence. Even an accepted sender does not change the
        // indicator until a catalog record carries that exact revision.
        state.openNotePanelFromUser()
        #expect(state.noteUnread(note))
    }

    @Test func composerAndInteractionPanelsTakePriority() {
        let state = NativeMokuSceneState()
        state.setWindowVisible(true)
        state.setNotePanelOpen(true)
        #expect(state.notePanelOpen)
        state.setInputOpen(true)
        #expect(!state.notePanelOpen && state.inputOpen)
        state.setInputOpen(false)
        state.setNotePanelOpen(true)
        state.setDockInteractionVisible(true, question: false)
        #expect(!state.notePanelOpen)
        state.setDockInteractionVisible(false, question: false)

        state.setNotePanelOpen(true)
        state.setMokuOpen(true)
        #expect(!state.notePanelOpen)
        state.setMokuOpen(false)
        state.setNotePanelOpen(true)
        state.setSearchActive(true)
        #expect(!state.notePanelOpen)
        state.setSearchActive(false)
        state.setNotePanelOpen(true)
        state.overviewVisible = false
        #expect(!state.notePanelOpen)
    }

    @Test(.requiresDisplay, arguments: [false, true], [236.0, 600.0])
    func expandedDockOpensHistoryWithoutConsumingDraftOrNote(hasNote: Bool, width: Double) async throws {
        let app = NSApplication.shared
        let enableAX = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        if app.responds(to: enableAX) { _ = app.perform(enableAX, with: true, with: "AXEnhancedUserInterface") }
        func frame(_ item: NSObject) throws -> CGRect {
            if let accessible = item as? any NSAccessibilityProtocol { return accessible.accessibilityFrame() }
            // SwiftUI.AccessibilityNode implements accessibilityFrame without
            // declaring NSAccessibilityProtocol, and -perform: boxes the CGRect
            // return incorrectly. Invoke the IMP with its declared signature.
            let frameSelector = NSSelectorFromString("accessibilityFrame")
            if let method = class_getInstanceMethod(type(of: item), frameSelector) {
                typealias FrameFunction = @convention(c) (AnyObject, Selector) -> CGRect
                let frame = unsafeBitCast(method_getImplementation(method), to: FrameFunction.self)(item, frameSelector)
                if frame.width > 0 && frame.height > 0 { return frame }
            }
            let selector = NSSelectorFromString("accessibilityAttributeValue:")
            let position = try #require(item.perform(selector, with: "AXPosition")?.takeUnretainedValue() as? NSValue)
            let size = try #require(item.perform(selector, with: "AXSize")?.takeUnretainedValue() as? NSValue)
            return CGRect(origin: position.pointValue, size: size.sizeValue)
        }
        for mode in ["idle", "voice", "voiceMessage", "running"] {
            let withMessage = mode == "voiceMessage"
            let withVoice = mode == "voice" || withMessage
            let state = NativeMokuSceneState()
            state.setWindowVisible(true)
            state.setNotePanelOpen(true)
            let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
            draft.text = "Keep this draft"
            let note = hasNote ? NativeMokuNote(id: "history-entry", text: "Still unread", revision: 1, updatedAt: 1) : nil
            let window = SwiftUIReplay.window(NativeMokuDock(state: state, draft: draft, cwd: "/tmp",
                running: mode == "running",
                voiceControls: AnyView(Button("Voice") {}.accessibilityIdentifier("history-test-voice")), voiceStatusVisible: withVoice, voiceModeActive: withVoice,
                voiceTranscript: withMessage ? NativeMokuTalkMessage(id: "history-long",
                    text: String(repeating: "Long message ", count: 30)) : nil,
                note: note, onSend: { _ in Issue.record("History must not send the draft") }, onCancel: {})
                .environment(\.locale, Locale(identifier: "en")), width: width, height: 500)
            defer { window.close(); state.settle() }
            let root = try #require(window.contentView)
            try await SwiftUIReplay.wait { element(id: "moku-note-history", in: root) != nil }
            let button = try #require(element(id: "moku-note-history", in: root))
            #expect(SwiftUIReplay.text(in: root).contains("View Moku conversation history"))
            try await Task.sleep(for: .milliseconds(600))
            let bounds = try frame(button)
            let rootScreen = window.convertToScreen(root.convert(root.bounds, to: nil))
            #expect(bounds.width > 60 && bounds.height >= 28)
            if withMessage {
                let message = try #require(element(id: "moku-voice-transcript", in: root))
                let messageBounds = try frame(message)
                #expect(messageBounds.minY >= bounds.maxY || messageBounds.maxX <= bounds.minX)
            }
            if withVoice || mode == "running" {
                let control = try #require(element(id: withVoice ? "history-test-voice" : "moku-stop", in: root))
                let controlBounds = try frame(control)
                #expect(bounds.maxX <= controlBounds.minX)
                #expect(abs(bounds.midY - controlBounds.midY) < 2, "Actions share one row")
            } else {
                #expect(abs(rootScreen.minX + state.capsuleFrame.maxX - bounds.maxX - 18) < 3)
            }
            _ = button.perform(NSSelectorFromString("accessibilityPerformPress"))
            try await SwiftUIReplay.wait { state.mokuOpen && !state.notePanelOpen }
            #expect(draft.text == "Keep this draft")
            #expect((note?.hasUnexposedUpdate ?? false) == hasNote)
            state.setMokuOpen(false)
            #expect(!state.mokuOpen && !state.notePanelOpen)
        }
    }

    @Test(.requiresDisplay, arguments: [64.0, 360.0]) func panelRendersSelectableProductionMarkdown(height: Double) async throws {
        let note = NativeMokuNote(id: "panel-incarnation", text: "# Milestones\n\n- Dispatched the migration\n- Waiting for review",
                                  revision: 3, updatedAt: 1_700_000_000_000)
        let window = SwiftUIReplay.window(NativeMokuNoteContent(note: note, width: height < 100 ? 188 : 480, height: height, availableHeight: height,
                                                              openExternal: nil), width: 600, height: 500)
        defer { window.close() }
        let content = try #require(window.contentView)
        try await SwiftUIReplay.wait { selectableText(content).contains { $0.string.contains("Milestones") } }
        let views = selectableText(content)
        #expect(views.contains { $0.string.contains("Dispatched the migration") })
        #expect(views.allSatisfy { !$0.isEditable })
        let text = try #require(views.first)
        var ancestor = text.superview
        var clip: NSClipView?
        while let view = ancestor {
            if let candidate = view as? NSClipView { clip = candidate; break }
            ancestor = view.superview
        }
        #expect(try #require(clip).bounds.height >= 44)

        // The empty state is a hint rather than a dead panel; no note Markdown
        // document is mounted for it.
        let empty = SwiftUIReplay.window(NativeMokuNoteContent(note: nil, width: 480, height: 360, availableHeight: 360,
                                                            openExternal: nil), width: 600, height: 500)
        defer { empty.close() }
        let emptyContent = try #require(empty.contentView)
        emptyContent.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        #expect(selectableText(emptyContent).isEmpty)
    }
}
