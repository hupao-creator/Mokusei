import Foundation
import MokuseiCore
import Testing
@testable import MokuseiHarnessOpenCode

/// The native decoder consumes the producer's single-authority projection:
/// assistant bodies come from ordered parts and tool payloads are display-only.
struct NativeOpenCodeProjectionTests {
    @Test func readsAssistantPartsAndToolDisplaysWithoutRawCopies() throws {
        let state = try OpenCodeState(.object([
            "version": .number(1),
            "messages": .array([
                .object([
                    "id": .text("assistant"),
                    "executionId": .text("execution"),
                    "role": .text("assistant"),
                    "status": .text("complete"),
                    "parts": .array([
                        .object(["type": .text("reasoning"), "ordinal": .number(0), "text": .text("reason")]),
                        .object(["type": .text("text"), "ordinal": .number(0), "text": .text("answer")]),
                    ]),
                ]),
                .object([
                    "id": .text("assistant:tool:read"),
                    "executionId": .text("execution"),
                    "role": .text("tool"),
                    "toolCallId": .text("read"),
                    "toolName": .text("read"),
                    "status": .text("complete"),
                    "argumentsDisplay": .text("{\n  \"2\": 2,\n  \"z\": \"<>&\u{2028}\"\n}"),
                    "resultDisplay": .text("plain output"),
                ]),
            ]),
            "executions": .array([]),
            "latestExecutionId": .null,
            "interactions": .array([]),
        ]))
        let assistant = try #require(state.messages.first { $0.role == "assistant" })
        #expect(assistant.text == "answer")
        #expect(assistant.thinking == "reason")
        #expect(assistant.raw["text"] == nil)
        #expect(assistant.raw["thinking"] == nil)
        let tool = try #require(state.messages.first { $0.role == "tool" })
        #expect(tool.text.isEmpty)
        #expect(tool.toolDisplay("arguments")?.string == "{\n  \"2\": 2,\n  \"z\": \"<>&\u{2028}\"\n}")
        #expect(tool.toolDisplay("result")?.string == "plain output")
        #expect(tool.raw["arguments"] == nil)
        #expect(tool.raw["result"] == nil)
        #expect(tool.raw["metadata"] == nil)
    }

    @Test func rejectsRemovedAggregateThinkingField() {
        let assistant = JSONValue.object([
            "id": .text("assistant"),
            "executionId": .text("execution"),
            "role": .text("assistant"),
            "thinking": .text("duplicate"),
        ])
        #expect(throws: OpenCodeError.self) { try state(assistant) }
    }

    @Test func rejectsRawAndDisplayToolCopies() {
        let tool = JSONValue.object([
            "id": .text("tool"),
            "executionId": .text("execution"),
            "role": .text("tool"),
            "arguments": .text("raw"),
            "argumentsDisplay": .text("display"),
        ])
        #expect(throws: OpenCodeError.self) { try state(tool) }
    }

    private func state(_ message: JSONValue) throws -> OpenCodeState {
        try OpenCodeState(.object([
            "version": .number(1),
            "messages": .array([message]),
            "executions": .array([]),
            "latestExecutionId": .null,
            "interactions": .array([]),
        ]))
    }
}
