import Foundation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
import MokuseiPluginAPI
@testable import MokuseiSidecardBrowser

@MainActor @Suite(.serializedNative, .serialized)
struct NativeBrowserAnnotationTests {
    private func context(stage: @escaping ([URL]) async throws -> [SidecardStagedAttachment],
                         send: @escaping (JSONValue) async throws -> SidecardSendReceipt,
                         discard: @escaping ([JSONText]) async throws -> Void,
                         threadID: JSONText = "t", storageDirectory: URL? = nil,
                         observation: ThreadPublicObservation = .init(), revision: Int = 0) throws -> SidecardContext {
        let thread = try HarnessThread(id: threadID, harnessID: "fixture", revision: revision, sessionState: .null,
            observation: observation, cwd: "/tmp", settings: .object([:]), createdAt: 0, updatedAt: 0, title: "T", tags: [])
        let actions = HarnessThreadActions(interrupt: {}, respond: { _ in }, invokeHarnessExtension: { _, _ in .null },
            forkThread: { _ in "fork" }, openExternal: { _ in }, openFollowUp: { _ in })
        return .init(thread: thread, conversationIndex: nil, actions: actions, readingTarget: nil,
            executionDisabled: false, expanded: true, transitioning: false, suppressed: false,
            conversation: { _, _ in AnyView(EmptyView()) }, voice: nil, open: { 0 }, close: {}, selectionRevision: { 0 },
            onIntent: { _ in {} }, send: send, stageAttachments: stage, discardAttachments: discard, backToOverview: {}, draftStorageDirectory: storageDirectory)
    }
    private func annotations(_ count: Int) throws -> [BrowserPendingAnnotation] {
        let selection = try BrowserSelection(.object(["kind": .text("region"),
            "rect": .object(["x": .number(0), "y": .number(0), "width": .number(10), "height": .number(10)]),
            "viewport": .object(["width": .number(100), "height": .number(100), "scrollX": .number(0), "scrollY": .number(0)])]))
        return (0..<count).map { .init(id: UUID(), comment: "comment-\($0)", url: "https://dummy-user:dummy-pass@fixture.invalid/path?query=1#fragment", title: "Fixture",
                                      selection: selection, png: Data([UInt8($0)])) }
    }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for annotation lifecycle")
    }

    @Test func releaseDuringStageCannotSendAndStillDiscardsStagedIDsAndTemporaryFiles() async throws {
        var continuation: CheckedContinuation<[SidecardStagedAttachment], Error>?
        var urls: [URL] = [], sends = 0, stages = 0, discarded: [JSONText] = []
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let context = try context(stage: { files in
            stages += 1; urls = files
            #expect(try files.map { try Data(contentsOf: $0) } == [Data([0]), Data([1])])
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }, send: { _ in sends += 1; return .init(executionID: "e") }, discard: { discarded += $0 }, storageDirectory: profile)
        let presentation = BrowserSidecardPresentation(context: context, lifetime: PluginLifetime())
        presentation.pending = try annotations(2)
        presentation.supplementalText = "Keep navigation draft"
        presentation.send(); presentation.send()
        try await wait { continuation != nil }
        #expect(stages == 1)
        presentation.release()
        continuation?.resume(returning: [.init(id: "a"), .init(id: "b")]); continuation = nil
        try await wait { !presentation.sending }
        #expect(sends == 0 && discarded == ["a", "b"])
        #expect(urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        let reopened = BrowserSidecardPresentation(context: context, lifetime: PluginLifetime())
        #expect(reopened.pending.map(\.png) == [Data([0]), Data([1])])
        #expect(reopened.supplementalText == "Keep navigation draft")
        reopened.remove(reopened.pending[0].id)
        reopened.remove(reopened.pending[0].id)
        #expect(reopened.pending.isEmpty && reopened.supplementalText == "Keep navigation draft" && reopened.canSend)
        let otherProfile = try self.context(stage: { _ in [] }, send: { _ in .init(executionID: "other") },
            discard: { _ in }, storageDirectory: profile.appendingPathComponent("other"))
        let isolated = BrowserSidecardPresentation(context: otherProfile, lifetime: PluginLifetime())
        #expect(isolated.pending.isEmpty && isolated.supplementalText.isEmpty)
        reopened.release(); isolated.release()
    }

    @Test func twentyAnnotationsSurviveStageFailureAndTextOnlyRetryDoesNotWriteOrStage() async throws {
        var files: [URL] = [], stages = 0, sends: [JSONValue] = []
        let context = try context(stage: { urls in
            stages += 1; files = urls
            throw PluginContractError("fixture stage failed")
        }, send: { input in sends.append(input); return .init(executionID: "e") }, discard: { _ in })
        let presentation = BrowserSidecardPresentation(context: context, lifetime: PluginLifetime())
        let batch = try annotations(20); presentation.pending = batch
        #expect(presentation.annotationDisabled && presentation.canSend)
        presentation.send()
        try await wait { !presentation.sending }
        #expect(stages == 1 && sends.isEmpty && presentation.pending.map(\.id) == batch.map(\.id))
        #expect(!presentation.sendError.isEmpty)
        #expect(files.count == 20 && files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        presentation.send(textOnly: true)
        try await wait { !presentation.sending }
        #expect(stages == 1 && sends.count == 1 && presentation.pending.isEmpty)
        let input = try #require(sends.first)
        #expect(input["annotations"]?.arrayValue?.count == 20)
        #expect(input["annotations"]?.arrayValue?.allSatisfy { $0["url"]?.stringValue == "https://fixture.invalid/path?query=1#fragment" } == true)
        #expect(input["parts"]?.arrayValue?.allSatisfy { part in
            let text = part["text"]?.stringValue ?? ""
            return !text.contains("dummy-user") && !text.contains("dummy-pass")
        } == true)
        #expect(input["parts"]?.arrayValue?.count == 20)
        #expect(input["annotations"]?.arrayValue?.allSatisfy { $0["screenshotId"] == nil } == true)
        presentation.release()
    }


    @Test func lateReceiptUsesTerminalStateObservedByTheReopenedPresentation() async throws {
        for status in [PublicExecution.Status.completed, .failed, .interrupted] {
            let profile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            var continuation: CheckedContinuation<SidecardSendReceipt, Error>?
            let original = try context(stage: { _ in [] }, send: { _ in
                try await withCheckedThrowingContinuation { continuation = $0 }
            }, discard: { _ in }, storageDirectory: profile)
            let presentation = BrowserSidecardPresentation(context: original, lifetime: PluginLifetime())
            presentation.pending = try annotations(1)
            presentation.supplementalText = "Late receipt draft"
            presentation.send(textOnly: true)
            try await wait { continuation != nil }
            presentation.release()
            let execution = try PublicExecution(executionID: "e", status: status, startedAt: 0, finishedAt: 1)
            let terminal = try context(stage: { _ in [] }, send: { _ in .init(executionID: "unused") },
                discard: { _ in }, storageDirectory: profile, observation: .init(latestExecution: execution), revision: 1)
            let reopened = BrowserSidecardPresentation(context: terminal, lifetime: PluginLifetime())
            reopened.update(terminal)
            continuation?.resume(returning: .init(executionID: "e")); continuation = nil
            try await wait { !reopened.sending }
            #expect(reopened.pending.count == (status == .completed ? 0 : 1))
            #expect(reopened.supplementalText == (status == .completed ? "" : "Late receipt draft"))
            #expect(reopened.sendError.isEmpty == (status == .completed))
            reopened.release()
        }
    }

    @Test func changingThreadDuringScreenshotStageCannotSendIntoEitherThread() async throws {
        var continuation: CheckedContinuation<[SidecardStagedAttachment], Error>?
        var urls: [URL] = [], oldSends = 0, nextSends = 0, discarded: [JSONText] = []
        let original = try context(stage: { files in
            urls = files
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }, send: { _ in oldSends += 1; return .init(executionID: "old") }, discard: { discarded += $0 }, threadID: "thread-a")
        let next = try context(stage: { _ in [] }, send: { _ in nextSends += 1; return .init(executionID: "new") },
            discard: { _ in Issue.record("Old thread attachments must not be discarded on a new thread") }, threadID: "thread-b")
        let presentation = BrowserSidecardPresentation(context: original, lifetime: PluginLifetime())
        presentation.pending = try annotations(1)
        presentation.send()
        try await wait { continuation != nil }
        presentation.update(next)
        continuation?.resume(returning: [.init(id: "old-thread-screenshot")]); continuation = nil
        // Discard returns before the file actor removes the temporary batch.
        // A thread switch resets `sending`, so wait for both cleanup effects.
        try await wait {
            discarded == ["old-thread-screenshot"] &&
                urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
        }
        #expect(oldSends == 0 && nextSends == 0)
        #expect(urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(presentation.context.thread.id == "thread-b" && presentation.pending.isEmpty)
        presentation.release()
    }
}
