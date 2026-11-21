import AppKit
import ChiefPluginUI
@testable import ChiefUI

private struct ReplayFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor final class PendingSendReplay {
    private let scope = CommandLine.arguments.first { $0.hasPrefix("--scope=") }
        .map { String($0.dropFirst("--scope=".count)) } ?? UUID().uuidString
    lazy var persistence = NativeComposerDraftPersistence(
        storageDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath), scope: .init(scope))
    private var receipt: CheckedContinuation<Void, Error>?
    private var sent: [NativeComposerSubmission] = []
    private var rejectAfterEdit: (() -> Void)?

    func receive(_ submission: NativeComposerSubmission) async throws {
        sent.append(submission)
        if let edit = rejectAfterEdit {
            rejectAfterEdit = nil
            edit()
            throw ReplayFailure(description: "fixture rejection")
        }
        guard receipt == nil else { throw ReplayFailure(description: "Concurrent submission") }
        try await withCheckedThrowingContinuation { receipt = $0 }
    }

    private func child(_ phase: String, scope: String) throws {
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["--replay-send", phase, "--scope=" + scope]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ReplayFailure(description: "Failed child " + phase) }
    }

    /// Continue from the capture's focused Agent to test a receipt across the recorded route handoff.
    func verifyHandoff(window: NSWindow, scene: NativeMokuSceneState, agent: NativeComposerDraft,
                       overview: NativeComposerDraft, closeAgent: () -> Void) async throws {
        guard !window.canBecomeKey, window.ignoresMouseEvents, !NSApp.isActive,
              scene.ownsComposer(agent), let editor = window.firstResponder as? NSTextView,
              editor.isEditable else { throw ReplayFailure(description: "Missing focused Agent input") }
        let overviewText = overview.text
        let insertion = NSRange(location: NSNotFound, length: 0)
        editor.insertText("A", replacementRange: insertion)
        let send = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36)!
        editor.keyDown(with: send)
        editor.insertText("B", replacementRange: insertion)
        editor.setMarkedText("pin", selectedRange: NSRange(location: 3, length: 0), replacementRange: insertion)
        guard sent.map(\.text) == ["A"], receipt != nil, agent.submitting, editor.hasMarkedText(),
              editor.string == "Bpin", window.firstResponder === editor else {
            throw ReplayFailure(description: "Pending send interrupted the Agent's next edit")
        }
        editor.insertText("拼", replacementRange: insertion)
        guard !editor.hasMarkedText(), agent.text == "B拼" else {
            throw ReplayFailure(description: "Agent composition failed to commit during send")
        }
        closeAgent()
        let deadline = ContinuousClock.now + .seconds(4)
        while !scene.overviewVisible && .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard scene.overviewVisible, scene.ownsComposer(overview), !scene.inputOpen,
              let pending = receipt else { throw ReplayFailure(description: "Pending send lost on return to Overview") }
        receipt = nil
        pending.resume(throwing: ReplayFailure(description: "late fixture rejection"))
        let settlementDeadline = ContinuousClock.now + .seconds(4)
        while agent.submitting && .now < settlementDeadline { try await Task.sleep(for: .milliseconds(10)) }
        guard !agent.submitting, agent.error != nil, agent.text == "A\n\nB拼", sent.map(\.text) == ["A"],
              !scene.inputOpen, scene.ownsComposer(overview), overview.text == overviewText,
              !(window.firstResponder is NSTextView), !NSApp.isActive else {
            throw ReplayFailure(description: "Late rejection changed the replacement input or lost the Agent draft")
        }
        print("Passed Agent Return, continued typing and composition, Overview return and late rejection with preserved focus and drafts.")
    }

    func run(window: NSWindow, scene: NativeMokuSceneState, draft: NativeComposerDraft) async throws {
        try require(!window.canBecomeKey && window.ignoresMouseEvents, "Replay panel accepts session input")
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        scene.readingPanelVisible = true
        scene.overviewVisible = false
        scene.setComposerContext(draft, opensInput: true, keepsInputOpen: true, autofocus: false)

        func find<T: NSView>(_ view: NSView, _ type: T.Type, where matches: (T) -> Bool) -> T? {
            if let found = view as? T, matches(found) { return found }
            for child in view.subviews {
                if let found = find(child, type, where: matches) { return found }
            }
            return nil
        }
        func waitFor(_ description: String, _ ready: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(4))
            while !ready() {
                guard ContinuousClock.now < deadline else { throw ReplayFailure(description: description) }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        func require(_ condition: Bool, _ description: String) throws {
            guard condition else { throw ReplayFailure(description: description) }
        }
        guard let content = window.contentView else { throw ReplayFailure(description: "Missing replay content") }
        func textView() -> NSTextView? { find(content, NSTextView.self) { $0.isEditable } }
        try await waitFor("Pinned editor did not mount") { textView() != nil }
        let editor = textView()!
        try require(window.makeFirstResponder(editor), "Editor could not acquire local focus")
        func trace(_ event: String) {
            print(event, editor.string.debugDescription, editor.selectedRange(), editor.hasMarkedText(), draft.text.debugDescription, sent.map(\.text))
        }
        func type(_ text: String) {
            editor.insertText(text, replacementRange: editor.selectedRange())
            trace("type " + text)
        }
        func replace(_ text: String) { editor.selectAll(nil); type(text) }
        func pressReturn(repeating: Bool = false) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: repeating, keyCode: 36)!
            editor.keyDown(with: event)
            trace("Return")
        }
        func sendButton() async throws -> NSButton {
            func button() -> NSButton? { find(content, NSButton.self) { $0.identifier?.rawValue == "moku-send" && $0.isEnabled } }
            try await waitFor("Send button did not become available") { button() != nil }
            let control = button()!
            func target() -> NSView? {
                let center = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: content.superview)
                return content.hitTest(center)
            }
            try await waitFor("Send hit target: " + String(describing: target())) { target() === control }
            return control
        }
        func checkText(_ expected: String) throws {
            let disk = try persistence.loadText()?.textValue.string
            try require(editor.string == expected && draft.text == expected && disk == expected,
                "Expected \(expected.debugDescription), native=\(editor.string.debugDescription) model=\(draft.text.debugDescription) disk=\(String(describing: disk))")
        }
        func settle(_ result: Result<Void, Error>) async throws {
            guard let pending = receipt else { throw ReplayFailure(description: "Missing receipt") }
            receipt = nil
            pending.resume(with: result)
            try await waitFor("Receipt did not settle") { !draft.submitting }
        }
        let args = CommandLine.arguments
        if args.contains("--stage-pending") {
            type("A")
            pressReturn()
            type("B")
            try checkText("B")
            try require(sent.map(\.text) == ["A"] && receipt != nil, "Missing pre-admission suspension")
            print("Writer pid \(ProcessInfo.processInfo.processIdentifier) exits before fixture admission.")
            // Simulate process loss without running draft disposal or AppKit teardown.
            fflush(nil)
            Darwin._exit(EXIT_SUCCESS)
        }
        if args.contains("--restore-pending") || args.contains("--keep-next") {
            try require(draft.interruptedInput?.text == "A", "Cold open lost original A")
            try checkText("B")
            pressReturn()
            try require(sent.isEmpty && !draft.canSubmit, "Cold open dispatched before review")
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            let restore = args.contains("--restore-pending")
            await draft.reviewInterruptedSend(restore: restore)
            type("C")
            try checkText(restore ? "A\n\nBC" : "BC")
            try require(sent.isEmpty && !draft.hasInterruptedSend, "Local review dispatched")
            print("Reader pid \(ProcessInfo.processInfo.processIdentifier) recovered A and B, restore=\(restore), deliveries=0.")
            return
        }

        // A real mounted button receives mouse tracking and its own window's
        // mouse-up event. The next insert runs as soon as tracking returns.
        @discardableResult func click(_ button: NSButton, doubleClickAt first: NSPoint? = nil) throws -> NSPoint {
            let count = first == nil ? 1 : 2
            let center = first ?? button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            if first == nil {
                let point = content.superview!.convert(center, from: nil)
                try require(content.hitTest(point) === button, "Pointer missed Send")
            }
            func mouse(_ kind: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: kind, location: center, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: 1)!
            }
            let up = mouse(.leftMouseUp)
            NSApp.postEvent(up, atStart: true)
            window.sendEvent(mouse(.leftMouseDown))
            // An ignored press skips AppKit tracking and leaves its paired up in the queue.
            if NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: false) === up {
                _ = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
                window.sendEvent(up)
            }
            return center
        }

        type("A")
        let button = try await sendButton()
        let firstClick = try click(button)
        type("B")
        try click(button, doubleClickAt: firstClick)
        pressReturn()
        try checkText("B")
        try require(editor.isEditable && window.firstResponder === editor, "Send lost the pinned input seat")
        let successor = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }),
            persistence: persistence)
        try require(successor.interruptedInput?.text == "A" && successor.text == "B", "Reconstructed owner lost input")
        await successor.reviewInterruptedSend(restore: true)
        try require(successor.hasInterruptedSend && successor.error != nil, "Reopened owner consumed a live send")
        successor.inputText = "B+"
        try await settle(.success(()))
        try checkText("B+")
        try require(sent.map(\.text) == ["A"] && successor.text == "B+" && !successor.hasInterruptedSend,
                    "Acceptance or a duplicate press consumed the successor")
        print("Send → B before redraw, duplicate click/Return, live-owner review and later acceptance passed.")

        replace("A")
        let rejectButton = try await sendButton()
        // Both the input during send and the input after rejection precede
        // the next SwiftUI pass. No receipt/text convergence polling here.
        rejectAfterEdit = { type("B") }
        try click(rejectButton)
        type("C")
        try checkText("A\n\nBC")
        pressReturn(repeating: true)
        try require(sent.map(\.text) == ["A", "A"] && draft.error != nil, "Held Return retried the rejection")
        print("Send → B → reject → C on one event stack retained the prefix and caret.")

        replace("A")
        pressReturn()
        type("A")
        pressReturn()
        try await settle(.failure(ReplayFailure(description: "delayed rejection")))
        type("C")
        try checkText("A\n\nAC")
        try require(sent.map(\.text) == ["A", "A", "A"], "Duplicate Return submitted the next draft")

        replace("A")
        let markedButton = try await sendButton()
        let currentSelection = NSRange(location: NSNotFound, length: 0)
        func mark(_ pinyin: String, _ range: NSRange) {
            editor.setMarkedText(pinyin, selectedRange: NSRange(location: pinyin.utf16.count, length: 0), replacementRange: range)
        }
        mark("cao", NSRange(location: 0, length: 1))
        try click(markedButton)
        try require(sent.count == 3 && editor.hasMarkedText() && !draft.canSubmit, "Send committed or submitted marked pinyin")
        editor.insertText("草", replacementRange: currentSelection)
        pressReturn()
        mark("pin", currentSelection)
        try await settle(.failure(ReplayFailure(description: "rejection during composition")))
        try require(editor.hasMarkedText() && editor.string == "pin" && draft.text == "草\n\npin", "Failure disrupted composition")
        editor.insertText("拼", replacementRange: currentSelection)
        type("C")
        try checkText("草\n\n拼C")
        try require(sent.map(\.text) == ["A", "A", "A", "草"], "IME submitted unfinished input")
        print("Return, repeated equal drafts, marked Send, rejection during composition and immediate post-commit C passed.")

        enum PeerEdit: CaseIterable { case directory, attachment, differentText, sameText }
        let folder = NativeComposerDirectory(name: "docs", path: "/fixture/docs")
        let file = NativeComposerStoredAttachment(id: .init(UUID().uuidString.lowercased()), path: "/fixture/note.txt",
            name: "note.txt", mimeType: "text/plain", size: 4, kind: .file)
        let services = NativeComposerServices(chooseFiles: { _, _, _ in
            [.init(data: Data("note".utf8), name: "note.txt", mimeType: "text/plain")]
        }, stageFiles: { _, _ in [file] }, discardAttachments: { _ in })
        func checkPeerEdit(_ edit: PeerEdit, reject: Bool, unmark: Bool = false) async throws {
            let deliveries = sent.count
            replace("A")
            pressReturn()
            try require(sent.count == deliveries + 1 && sent.last?.text == "A", "First Return did not send A once")
            mark("pin", currentSelection)
            let peer = NativeComposerDraft(services: services, persistence: persistence)
            let peerPanel = makePeerComposerPanel(draft: peer, replay: self)
            defer { peerPanel.close() }
            func peerEditor() -> NSTextView? { find(peerPanel.contentView!, NSTextView.self) { $0.isEditable } }
            try await waitFor("Second native editor did not mount") { peerEditor() != nil }
            let other = peerEditor()!
            try require(other.string == "pin", "Second editor did not inherit the marked buffer")
            var independent: String?
            switch edit {
            case .directory: try require(peer.insertDirectory(folder), "Could not add directory")
            case .attachment: await peer.chooseFiles(cwd: "/fixture")
            case .differentText, .sameText:
                let replacement = edit == .sameText ? "pin" : "B"
                other.selectAll(nil)
                other.insertText(replacement, replacementRange: other.selectedRange())
                independent = replacement
            }
            let directories = edit == .directory ? [folder] : []
            let attachments = edit == .attachment ? [file] : []
            func checkChips(_ owner: NativeComposerDraft) throws {
                try require(owner.inputDirectories == directories &&
                    owner.inputAttachments.compactMap(\.attachment) == attachments &&
                    owner.inputAttachments.count == attachments.count, "Wrong chips for " + String(describing: edit))
            }
            try checkChips(peer)
            try require(try persistence.loadText()?.textValue.string == (independent ?? "pin") && editor.hasMarkedText(),
                "Missing overlapping edit")
            if reject { try await settle(.failure(ReplayFailure(description: "rejected during composition"))) }
            else { try await settle(.success(())) }
            let settledText = [reject ? "A" : nil, independent ?? "pin"].compactMap { $0 }.joined(separator: "\n\n")
            try require(editor.hasMarkedText() && editor.string == "pin" && other.string == settledText,
                "Settlement lost the marked range or peer text")
            if unmark { editor.unmarkText() }
            else { editor.insertText("拼", replacementRange: currentSelection) }
            type("C")
            let expected = [reject ? "A" : nil, independent, unmark ? "pinC" : "拼C"]
                .compactMap { $0 }.joined(separator: "\n\n")
            try checkText(expected)
            try checkChips(draft)
            let reopened = NativeComposerDraft(services: services, persistence: persistence)
            try checkChips(reopened)
            try require(editor.selectedRange() == NSRange(location: expected.utf16.count, length: 0) &&
                reopened.text == expected && sent.count == deliveries + 1,
                "Composition settlement changed the caret, deliveries or the saved draft")
            pressReturn()
            try require(sent.count == deliveries + 2 && sent.last?.text == expected &&
                sent.last?.directories == directories && sent.last?.attachments == attachments, "Wrong subsequent payload")
            try await settle(.success(()))
            print("Peer edit", edit, "rejected", reject, "unmark", unmark, "result", expected.debugDescription,
                  "directories", directories.count, "attachments", attachments.count)
        }
        for reject in [false, true] {
            for edit in PeerEdit.allCases { try await checkPeerEdit(edit, reject: reject) }
        }
        try await checkPeerEdit(.differentText, reject: false, unmark: true)

        // Record the originating AppKit stack if an unsolicited lowercase c
        // enters storage between the IME commit and directory re-selection.
        let trace = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
            object: editor.textStorage, queue: nil) { [weak editor] _ in
                MainActor.assumeIsolated {
                    if let storage = editor?.textStorage, storage.string.contains("c") {
                        print("Unexpected directory edit:", storage.string.debugDescription, storage.editedRange,
                              Thread.callStackSymbols.joined(separator: "\n"))
                    }
                }
            }
        defer { NotificationCenter.default.removeObserver(trace) }
        replace("@Des")
        pressReturn()
        let directory = "/fixture/Design"
        try require(draft.inputDirectories.map { $0.path.string } == [directory] && draft.text == "", "First @ selection failed")
        type("A")
        pressReturn()
        type("@Des")
        pressReturn()
        type("B")
        try require(draft.inputDirectories.map { $0.path.string } == [directory], "Second @ selection lost directory")
        try await settle(.success(()))
        try checkText("B")
        pressReturn()
        try await settle(.success(()))
        try require(sent.suffix(2).map(\.text) == ["A", "B"] &&
            sent.suffix(2).allSatisfy { $0.directories.map { $0.path.string } == [directory] }, "Both submissions must own Design")
        print("Two explicit messages each captured the same @Design directory once.")

        type("R")
        pressReturn()
        type("N")
        try await settle(.failure(ReplayFailure(description: "retry after review")))
        pressReturn(repeating: true)
        try require(!draft.submitting, "Held Return retried recovered text")
        pressReturn()
        try await settle(.success(()))
        try require(sent.suffix(2).map(\.text) == ["R", "R\n\nN"], "Explicit retry used the wrong payload")
        try checkText("")

        for decision in ["--restore-pending", "--keep-next"] {
            let scope = UUID().uuidString
            try child("--stage-pending", scope: scope)
            try child(decision, scope: scope)
        }
        try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground, "Foreground application changed")
    }
}
