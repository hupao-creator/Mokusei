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

extension NativeOpenCodeProjectionTests {
    @Test func compactPreviewCoexistsWithReasoningPart() throws {
        let state = try state(.object([
            "id": .text("assistant"),
            "executionId": .text("execution"),
            "role": .text("assistant"),
            "status": .text("complete"),
            "text": .text("bounded preview"),
            "parts": .array([.object(["type": .text("reasoning"), "ordinal": .number(0), "text": .text("reason")])]),
        ]))
        let message = try #require(state.messages.first)
        #expect(message.text == "bounded preview")
        #expect(message.thinking == "reason")
    }

    @Test func rejectsNonemptyPreviewWithTextPart() {
        let message = JSONValue.object([
            "id": .text("assistant"),
            "executionId": .text("execution"),
            "role": .text("assistant"),
            "text": .text("duplicate"),
            "parts": .array([.object(["type": .text("text"), "ordinal": .number(0), "text": .text("duplicate")])]),
        ])
        #expect(throws: OpenCodeError.self) { try state(message) }
    }

    @Test func emptyAggregateDoesNotShadowAssistantParts() throws {
        let state = try state(.object([
            "id": .text("assistant"),
            "executionId": .text("execution"),
            "role": .text("assistant"),
            "status": .text("complete"),
            "text": .text(""),
            "parts": .array([.object(["type": .text("text"), "ordinal": .number(0), "text": .text("answer")])]),
        ]))
        let message = try #require(state.messages.first)
        #expect(message.text == "answer")
    }
}

extension NativeOpenCodeProjectionTests {
    @Test func compactOverviewPrefersTextPreviewOverReasoningPart() throws {
        let message = try OpenCodeMessage(.object([
            "id": .text("assistant"),
            "executionId": .text("execution"),
            "role": .text("assistant"),
            "status": .text("complete"),
            "text": .text("bounded preview"),
            "parts": .array([.object(["type": .text("reasoning"), "ordinal": .number(0), "text": .text("reason")])]),
        ]))
        let selected = try #require(ocOverviewMessage([message], sessionID: nil, status: .completed))
        #expect(selected.text == "bounded preview")
        // The aggregate preview has no text part ordinal; it must not borrow the
        // reasoning part's ordinal and point the anchor at a different row.
        #expect(selected.id == ocJSONStringID([.string("execution"), .text("assistant"), .string("assistant"), .text("text"), .null]))
    }

    @Test func compactOverviewReasoningKeepsItsOrdinal() throws {
        let message = try OpenCodeMessage(.object([
            "id": .text("assistant"),
            "executionId": .text("execution"),
            "role": .text("assistant"),
            "status": .text("complete"),
            "parts": .array([.object(["type": .text("reasoning"), "ordinal": .number(3), "text": .text("reason")])]),
        ]))
        let selected = try #require(ocOverviewMessage([message], sessionID: nil, status: .completed))
        #expect(selected.text == "reason")
        #expect(selected.id == ocJSONStringID([.string("execution"), .text("assistant"), .string("assistant"), .text("reasoning"), .number(3)]))
    }
}
