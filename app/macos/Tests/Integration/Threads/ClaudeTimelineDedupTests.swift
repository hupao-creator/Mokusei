import Foundation
import Testing
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
@testable import MokuseiHarnessClaude

@Suite struct ClaudeTimelineDedupTests {
    @Test func referenceTimelineProjectsCurrentEntitiesOnce() throws {
        let fixture = try fixture()
        let state = try ClaudeState(try #require(fixture["state"]))
        let turn = try #require(state.turns.first)

        let rawActivities = turn.timeline.filter { $0.claudeKind == "activity" }
        #expect(rawActivities.count == 3)
        #expect(Set(rawActivities.map { $0.claudeID("activityId") }) == ["command-ok", "command-fail", "hook-1"])
        #expect(rawActivities.allSatisfy { $0["activity"] == nil })
        let interactions = turn.timeline.filter { $0.claudeKind == "interaction" }
        #expect(interactions.map { $0.claudeID("interactionId") } == ["ask-question", "ask-permission"])
        #expect(interactions.allSatisfy { $0["interaction"] == nil })
        let notices = turn.timeline.filter { $0.claudeKind == "notice" }
        #expect(notices.map { $0.claudeID("noticeId") } == ["notice-1"])
        #expect(notices.allSatisfy { $0["notice"] == nil })

        let current = Dictionary(uniqueKeysWithValues: turn.activities.map { ($0.claudeID("id"), $0) })
        #expect(current["command-ok"]?["detail"]?.stringValue == "success output\nsuccess output\n")
        #expect(current["command-ok"]?["status"]?.stringValue == "completed")
        #expect(current["command-fail"]?["detail"]?.stringValue == "permission denied")
        #expect(current["command-fail"]?["status"]?.stringValue == "failed")
        #expect(current["hook-1"]?["status"]?.stringValue == "completed")

        let projected = claudeProjectTimeline(turn)
        #expect(projected.map(\.claudeKind) == [
            "user-message", "reasoning", "assistant", "activity", "interaction",
            "activity", "activity", "interaction", "notice", "review", "assistant",
        ])
        let activities = projected.filter { $0.claudeKind == "activity" }
        #expect(activities.map { $0["activity"]?.claudeID("id") } == ["command-ok", "command-fail", "hook-1"])
        #expect(activities.map { $0["activity"]?["status"]?.stringValue } == ["completed", "failed", "completed"])
        #expect(activities[0]["activity"]?["detail"]?.stringValue == "success output\nsuccess output\n")
        #expect(activities[1]["activity"]?["detail"]?.stringValue == "permission denied")
        #expect(projected.filter { $0.claudeKind == "review" }.map { $0["content"]?.stringValue } == ["review final"])
        #expect(projected.filter { $0.claudeKind == "interaction" }.map { $0["interaction"]?["title"]?.stringValue } == ["Pick the target", "Allow the next command"])

        let starts = claudeActivityRunStarts(turn)
        #expect(starts == Set([activities[0].claudeID("id"), activities[1].claudeID("id")]))
        let summaries = activities.compactMap { claudeExecutionSummary($0, presence: ThreadExecutionPresence()) }
        #expect(summaries.map(\.toolCalls) == [1, 1, 1])
        #expect(summaries.map(\.hasContent) == [true, true, true])
    }

    @Test func assistantAndReasoningHaveSingleRepresentation() throws {
        let fixture = try fixture()
        let state = try ClaudeState(try #require(fixture["state"]))
        let turn = try #require(state.turns.first)
        #expect(turn.assistantText == "First answer.Final answer.")
        #expect(turn.lastAssistantText == "Final answer.")
        let stateValue = try #require(fixture["state"])
        let object = try #require(stateValue.objectValue)
        let turns = try #require(object["turns"]?.arrayValue)
        let rawTurn = try #require(turns.first?.objectValue)
        for key in ["text", "reasoning", "lastAssistantMessage", "diff", "review"] {
            #expect(rawTurn[JSONText(key)] == nil)
        }
        #expect(turn.timeline.filter { $0.claudeKind == "assistant" }.count == 2)
        #expect(turn.timeline.filter { $0.claudeKind == "reasoning" }.count == 1)
    }

    @Test func pendingInteractionsKeepPublicAuthority() throws {
        let fixture = try fixture()
        let state = try ClaudeState(try #require(fixture["state"]))
        let observation = try ThreadPublicObservation(json: try #require(fixture["observation"]))
        #expect(observation.latestExecution?.status == .waitingForUser)
        let bindings = claudePublicInteractions(state, observation)
        let question = try #require(bindings["ask-question"])
        #expect(question.title == "Pick the target")
        #expect(question.kind == .question)
        #expect(question.questions.map(\.prompt.string) == ["Choose"])
        let firstQuestion = try #require(question.questions.first)
        #expect(firstQuestion.options.map(\.label.string) == ["A", "B"])
        let permission = try #require(bindings["ask-permission"])
        #expect(permission.title == "Allow the next command")
        #expect(permission.kind == .permission)
        #expect(permission.actions.map(\.id) == ["allow", "allow-session", "deny", "cancel"])
    }

    @Test func explicitMessageTargetsAndForkHistoryFollowStableIDs() throws {
        let fixture = try fixture()
        let state = try ClaudeState(try #require(fixture["state"]))
        let turn = try #require(state.turns.first)
        let expected = turn.timeline.last { $0.claudeKind == "assistant" && $0.claudeID("messageId") == "assistant-2" }?.claudeID("id")
        let anchor = claudeReplyAnchor(state, message: .object(["executionId": .text("execution-timeline"), "messageId": .text("assistant-2")]))
        #expect(anchor == expected)
        #expect(claudeReplyAnchor(state, message: .object(["executionId": .text("execution-timeline"), "messageId": .text("missing")])) == nil)

        let fork = try ClaudeState(try #require(fixture["fork"]))
        #expect(fork.history.count == 11)
        let activities = fork.history.filter { $0.claudeKind == "activity" }
        #expect(activities.count == 3)
        #expect(activities.allSatisfy { $0["activity"] != nil && $0["activityId"] == nil })
        #expect(activities[1]["activity"]?["detail"]?.stringValue == "permission denied")
        let interactions = fork.history.filter { $0.claudeKind == "interaction" }
        #expect(interactions.map { $0["interaction"]?["status"]?.stringValue } == ["cancelled", "cancelled"])
        #expect(fork.history.filter { $0.claudeKind == "notice" }.first?["notice"]?["message"]?.stringValue == "Fixture warning")
        #expect(fork.history.allSatisfy { !["plan", "usage", "diff"].contains($0.claudeKind) })
    }

    private func fixture() throws -> JSONValue {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("internal/plugins/harness/claude/testdata/timeline-reader.golden.json")
        return try JSONValue(data: Data(contentsOf: file))
    }
}
