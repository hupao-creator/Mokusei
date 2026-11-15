import Foundation
import Testing
import MokuseiCore
import MokuseiPluginAPI
@testable import MokuseiUI

@MainActor
struct ExecutionContentContractTests {
    @Test func fullContentEnvelopeCarriesOnlyExactTitles() throws {
        let content = try HarnessThreadContent(.object([
            "version": .integer(1),
            "state": .object(["body": .text("complete state")]),
            "executionTitles": .object(["execution": .text("Exact title")])
        ]))
        #expect(content.state == .object(["body": .text("complete state")]))
        #expect(content.executionTitles[JSONText("execution")] == JSONText("Exact title"))
        #expect(throws: (any Error).self) {
            _ = try HarnessThreadContent(.object([
                "version": .integer(1), "state": .null,
                "executionTitles": .object(["": .text("blank identity")])
            ]))
        }
    }

    @Test func previewKeepsCitedIdentityAndTiming() throws {
        let preview = try NativeExecutionPreview(json: .object([
            "threadId": .text("thread"), "executionId": .text("execution"),
            "title": .text("First execution"), "status": .text("completed"),
            "startedAt": .integer(10), "finishedAt": .integer(20), "excerpt": .text("First reply")
        ]))
        #expect(preview.thread == "thread" && preview.executionID == "execution")
        #expect(preview.title == "First execution")
        #expect(preview.preview.startedAt == 10 && preview.preview.finishedAt == 20)
        #expect(!preview.preview.running && preview.preview.excerpt == "First reply")
    }

    @Test func previewTruncatesAtSixHundredCodePoints() throws {
        let text = String(repeating: "e\u{301}👩🏽‍💻", count: 200)
        let preview = try HarnessExecutionPreview(startedAt: 1, finishedAt: 2, running: false,
                                                  excerpt: JSONText(text))
        #expect(preview.excerpt.string.unicodeScalars.count == 600)
        #expect(preview.excerpt.string.utf16.count > 600)
    }

    @Test func previewRejectsRunningFinishAndMismatchedFields() throws {
        #expect(throws: (any Error).self) {
            _ = try NativeExecutionPreview(json: .object([
                "threadId": .text("thread"), "executionId": .text("execution"),
                "status": .text("running"), "startedAt": .integer(10),
                "finishedAt": .integer(20), "excerpt": .text("reply")
            ]))
        }
        #expect(throws: (any Error).self) {
            _ = try NativeExecutionPreview(json: .object([
                "threadId": .text("thread"), "executionId": .text("execution"),
                "status": .text("completed"), "startedAt": .integer(10),
                "finishedAt": .integer(9), "excerpt": .text("reply")
            ]))
        }
    }
}
