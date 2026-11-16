import Foundation
import Testing
import MokuseiCore
import MokuseiPluginAPI
@testable import MokuseiHarnessOpenCode

@Suite struct OpenCodeProjectionFallbackTests {
    @Test func decodesMinimalFallbackProjection() throws {
        let value = JSONValue.object([
            "version": .number(1),
            "messages": .array([]),
            "executions": .array([]),
            "latestExecutionId": .null,
            "interactions": .array([]),
            "contentTruncated": .bool(true),
        ])
        let state = try OpenCodeState(value)
        #expect(state.contentTruncated)
        #expect(state.messages.isEmpty)
        #expect(state.executions.isEmpty)
    }

    @Test func decodesConditionalNativeFormFallback() throws {
        let value = JSONValue.object([
            "version": .number(1),
            "messages": .array([]),
            "executions": .array([]),
            "latestExecutionId": .null,
            "interactions": .array([
                .object([
                    "id": .text("interaction"),
                    "executionId": .text("execution"),
                    "sessionId": .text("session"),
                    "kind": .text("form"),
                    "title": .text("Conditional form"),
                    "status": .text("pending"),
                    "fields": .array([
                        .object([
                            "type": .text("string"),
                            "key": .text("mode"),
                            "required": .bool(true),
                            "title": .text("Mode"),
                        ]),
                        .object([
                            "type": .text("string"),
                            "key": .text("detail"),
                            "required": .bool(false),
                            "when": .array([
                                .object([
                                    "key": .text("mode"),
                                    "op": .text("eq"),
                                    "value": .text("a"),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
            "contentTruncated": .bool(true),
        ])
        let state = try OpenCodeState(value)
        #expect(state.interactions.count == 1)
    }

    @Test func truncationNoticeHasOneSurface() {
        // Reader and history pages both re-enter the main presentation, so
        // they share exactly one surface notice. Execution detail owns one
        // inline notice instead. Overview owns one separate indicator.
        let reader = HarnessConversationPresentation.main(excludedExecutionIDs: [])
        let history = HarnessConversationPresentation.main(excludedExecutionIDs: [])
        #expect(openCodeTruncationPlacement(truncated: true, presentation: reader) == .surface)
        #expect(openCodeTruncationPlacement(truncated: true, presentation: history) == .surface)
        #expect(openCodeTruncationPlacement(truncated: true, presentation: .execution("execution")) == .inline)
        #expect(openCodeTruncationPlacement(truncated: false, presentation: reader) == .none)
        #expect(openCodeOverviewShowsTruncation(true))
        #expect(!openCodeOverviewShowsTruncation(false))
    }
}
