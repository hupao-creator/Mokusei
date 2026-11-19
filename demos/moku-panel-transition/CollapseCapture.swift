import AppKit
import AVFoundation
import MokuseiPluginUI
import ScreenCaptureKit
@testable import MokuseiUI

private struct CollapseCaptureError: Error, CustomStringConvertible {
    let description: String
}

@MainActor func captureCollapse(window: NSWindow, scene: NativeMokuSceneState, agentDraft: NativeComposerDraft,
                                selectOverviewDraft: (NativeComposerDraft) -> Void) async throws {
    let destination = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("collapse")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let overviewDraft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
    let text = "草稿 🦉 stays in Overview.\nThe second line stays too."
    let selection = NSRange(location: 3, length: 2)
    let talk = NativeMokuTalkMessage(id: "collapse-fixture-talk", text: "Moku reply stays readable after closing input.")
    let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
    func pause(_ milliseconds: Int) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }
    func editors(in view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { editors(in: $0) }
    }
    func require(_ condition: Bool, _ failure: String) throws {
        guard condition else { throw CollapseCaptureError(description: failure) }
    }

    scene.readingPanelVisible = true
    scene.overviewVisible = false
    scene.setComposerContext(agentDraft, opensInput: true, keepsInputOpen: true, autofocus: false)
    try await pause(650)
    let shareable = try await SCShareableContent.currentProcess
    guard let ownWindow = shareable.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }),
          let content = window.contentView else { throw CollapseCaptureError(description: "Replay window unavailable") }
    let config = SCStreamConfiguration()
    config.width = Int(window.frame.width * 2)
    config.height = Int(window.frame.height * 2)
    config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    config.showsCursor = false
    config.ignoreShadowsSingleWindow = true
    let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: ownWindow), configuration: config, delegate: nil)
    let recordingConfig = SCRecordingOutputConfiguration()
    recordingConfig.outputURL = destination.appendingPathComponent("window.mp4")
    let recordingDelegate = CollapseRecordingDelegate()
    let recording = SCRecordingOutput(configuration: recordingConfig, delegate: recordingDelegate)
    try stream.addRecordingOutput(recording)
    try await stream.startCapture()
    let start = ContinuousClock.now
    var events: [[String: Any]] = []
    func event(_ name: String) {
        let elapsed = start.duration(to: .now).components
        events.append(["event": name, "seconds": Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                       "inputOpen": scene.inputOpen, "inputLeaving": scene.inputLeaving,
                       "editorText": editors(in: content).map(\.string), "editorSelection": editors(in: content).map {
                           NSStringFromRange($0.selectedRange())
                       }, "talkPresented": scene.talkPresentation.presented])
    }

    var failure: String?
    do {
        try await pause(350)
        event("agent-open")
        try require(scene.inputOpen && editors(in: content).count == 1, "Agent editor did not mount")
        scene.overviewVisible = true
        scene.readingPanelVisible = false
        selectOverviewDraft(overviewDraft)
        scene.setComposerContext(overviewDraft, opensInput: false)
        event("return-to-overview")
        try await pause(650)
        event("overview-closed")
        try require(!scene.inputOpen && !scene.inputLeaving, "Return did not close Agent input")

        scene.toggleInput()
        try await pause(650)
        guard let editor = editors(in: content).first(where: { $0.isEditable }),
              window.makeFirstResponder(editor) else {
            throw CollapseCaptureError(description: "Overview editor unavailable")
        }
        // Exercise NSTextInputClient across a SwiftUI update before closing.
        // The system input-source picker and candidate window are outside this replay.
        let currentSelection = NSRange(location: NSNotFound, length: 0)
        editor.setMarkedText("cao", selectedRange: NSRange(location: 3, length: 0), replacementRange: currentSelection)
        try await pause(100)
        try require(editor.hasMarkedText() && editor.string == "cao" && scene.inputOpen,
                    "A composer update interrupted native marked text")
        event("marked-text")
        editor.insertText("草稿", replacementRange: currentSelection)
        editor.insertText(" 🦉 stays in Overview.\nThe second line stays too.", replacementRange: currentSelection)
        try require(!editor.hasMarkedText() && editor.string == text && overviewDraft.text == text,
                    "Committing marked text or subsequent typing lost the draft")
        editor.setSelectedRange(selection)
        event("draft-open")
        try require(scene.dismissInputForOutsideClick(), "Outside dismissal was rejected")
        event("draft-close")
        try await pause(85)
        event("draft-leaving")
        try require(scene.inputLeaving && editors(in: content).contains(where: { $0 === editor }) && !editor.isEditable,
                    "Closing did not retain a noneditable editor")
        scene.toggleInput()
        event("draft-reopen")
        try await pause(650)
        event("draft-reopened")
        try require(scene.inputOpen && !scene.inputLeaving && editors(in: content).contains(where: { $0 === editor })
                    && editor.isEditable && editor.string == text && editor.selectedRange() == selection,
                    "Rapid reopening lost the editor, draft or UTF-16 selection")

        scene.receiveTalk(talk)
        try await pause(120)
        try require(!scene.talkPresentation.presented, "Talk covered the open draft")
        try require(scene.dismissInputForOutsideClick(), "Second outside dismissal was rejected")
        event("close-to-talk")
        try await pause(650)
        event("talk-visible")
        try require(!scene.inputOpen && !scene.inputLeaving && overviewDraft.text == text
                    && scene.talkPresentation.presented && scene.talkPresentation.message == talk,
                    "Closing lost the draft or failed to present queued Talk")
    } catch {
        failure = String(describing: error)
    }
    try stream.removeRecordingOutput(recording)
    for try await _ in recordingDelegate.completion {}
    try await stream.stopCapture()
    let foregroundUnchanged = foreground == NSWorkspace.shared.frontmostApplication?.processIdentifier
    if failure == nil && !foregroundUnchanged { failure = "Foreground application changed during capture" }
    try JSONSerialization.data(withJSONObject: ["events": events, "foregroundUnchanged": foregroundUnchanged,
        "failure": failure as Any? ?? NSNull()], options: [.prettyPrinted, .sortedKeys])
        .write(to: destination.appendingPathComponent("observations.json"), options: .atomic)
    if let failure { throw CollapseCaptureError(description: failure) }
}

private final class CollapseRecordingDelegate: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    let (completion, continuation) = AsyncThrowingStream<Void, Error>.makeStream()

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        continuation.finish()
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        continuation.finish(throwing: error)
    }
}
