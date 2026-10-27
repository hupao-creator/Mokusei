import Foundation
import Testing
import MokuseiCore
import MokuseiPluginAPI
@testable import MokuseiHarnessClaude

@Suite struct ClaudeErrorSurfacingTests {
    private let balanceError = "API Error: 402 Insufficient Balance (request_id: 68a5eff6-527f-4980-89bd-c4d8ab853418)"

    @Test func goldenGoEncoderStateWithThinkingObjectDecodes() throws {
        let state = try ClaudeState(try goldenState())
        let author = try #require(state.turns.first?.raw["author"])
        #expect(author["model"]?.stringValue == "claude-sonnet-4-5")
        #expect(author["thinking"]?["mode"]?.stringValue == "effort")
        #expect(author["effort"]?.stringValue == "high")
    }

    @Test func legacyAuthorEffortStringStillDecodes() throws {
        var state = try goldenState()
        var turns = try #require(state["turns"]?.arrayValue)
        var turn = try #require(turns.first?.objectValue)
        turn["author"] = .object([
            "model": .text("claude-sonnet-4-5"),
            "effort": .text("high")
        ])
        turns[0] = .object(turn)
        state = state.claudeReplacing("turns", .array(turns))
        let decoded = try ClaudeState(state)
        #expect(decoded.turns.first?.raw["author"]?["effort"]?.stringValue == "high")
    }

    @Test func malformedAuthorThinkingNamesTheRejectedKey() throws {
        var state = try goldenState()
        var turns = try #require(state["turns"]?.arrayValue)
        var turn = try #require(turns.first?.objectValue)
        var author = try #require(turn["author"]?.objectValue)
        var thinking = try #require(author["thinking"]?.objectValue)
        thinking["mode"] = .object(["unexpected": .bool(true)])
        author["thinking"] = .object(thinking)
        turn["author"] = .object(author)
        turns[0] = .object(turn)
        state = state.claudeReplacing("turns", .array(turns))

        do {
            _ = try ClaudeState(state)
            Issue.record("Expected malformed author.thinking to fail decoding")
        } catch {
            #expect(error.localizedDescription.contains("author.thinking.mode"))
        }
    }

    @Test func harnessFailureOutranksStateDecodeFailure() throws {
        let input = try threadInput(failure: balanceError)
        let failure = claudeFailurePresentation(input, decodeError: PluginContractError("Claude author.thinking 无效"))

        #expect(failure.message == balanceError)
        #expect(failure.message.contains("402"))
        #expect(failure.message.contains("request_id: 68a5eff6-527f-4980-89bd-c4d8ab853418"))
        #expect(failure.message.contains("sessionState") == false)
        #expect(failure.detail?.contains("author.thinking") == true)
    }

    @Test func decodeFailureAloneReportsTheRejectedKey() throws {
        let input = try threadInput(failure: nil)
        let failure = claudeFailurePresentation(input, decodeError: PluginContractError("Claude author.thinking.mode 无效"))

        #expect(failure.message.contains("author.thinking.mode"))
        #expect(failure.detail == nil)
    }

    @Test func surfacedFailureRedactsSecretMaterial() throws {
        let secret = "sk-ant-api03-SECRETKEY1234567890"
        let message = "API Error: 401 Unauthorized\nAuthorization: Bearer \(secret)\nrequest_id: req_123"
        let failure = claudeFailurePresentation(try threadInput(failure: message), decodeError: PluginContractError("Claude sessionState 无效"))

        #expect(failure.message.contains("API Error: 401 Unauthorized"))
        #expect(failure.message.contains("request_id: req_123"))
        #expect(failure.message.contains("[REDACTED]"))
        #expect(failure.message.contains(secret) == false)
        #expect(failure.message.contains("Bearer \(secret)") == false)
        #expect(claudeRedacted("ANTHROPIC_API_KEY=sk-ant-api03-SECRETKEY1234567890").contains("SECRETKEY") == false)
    }

    private func threadInput(failure: String?) throws -> HarnessThreadInput {
        let execution = try PublicExecution(
            executionID: "execution-402", status: .failed, startedAt: 1_000, finishedAt: 2_000,
            error: failure.map { JSONText($0) }
        )
        let thread = try HarnessThread(
            id: "thread-402", harnessID: "claude", revision: 1,
            sessionState: try goldenState(), observation: ThreadPublicObservation(latestExecution: execution),
            cwd: "/tmp", settings: .object([:]), createdAt: 1_000, updatedAt: 2_000,
            title: "Claude failure", tags: []
        )
        return HarnessThreadInput(thread: thread)
    }

    private func goldenState() throws -> JSONValue {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("internal/plugins/harness/claude/testdata/state-author-thinking.golden.json")
        return try JSONValue(data: Data(contentsOf: file))
    }
}
