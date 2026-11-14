import Foundation
import Testing
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
@testable import MokuseiHarnessClaude

@MainActor @Suite struct ClaudeTimelineDedupTests {
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

    @Test func versionOneAndMalformedTimelinesAreRejected() throws {
        let versionOne = try stateWithTimelineMutation { _, _ in }
        var versionObject = try #require(versionOne.objectValue)
        versionObject["version"] = .number(1)
        #expect(throws: (any Error).self) { try ClaudeState(.object(versionObject)) }

        let cases: [(String, (inout [JSONText: JSONValue], inout [JSONValue]) -> Void)] = [
            ("missing reference", { _, timeline in
                var item = timeline[3].objectValue!
                item.removeValue(forKey: "activityId")
                timeline[3] = .object(item)
            }),
            ("missing entity", { _, timeline in
                var item = timeline[3].objectValue!
                item["activityId"] = .text("missing")
                timeline[3] = .object(item)
            }),
            ("unknown kind", { _, timeline in
                var item = timeline[3].objectValue!
                item["kind"] = .text("mystery")
                timeline[3] = .object(item)
            }),
            ("inline snapshot", { turn, timeline in
                var item = timeline[3].objectValue!
                item.removeValue(forKey: "activityId")
                item["activity"] = turn["activities"]?.arrayValue?.first
                timeline[3] = .object(item)
            }),
            ("duplicate reference", { _, timeline in
                var duplicate = timeline[3].objectValue!
                duplicate["id"] = .text("duplicate-activity")
                timeline.append(.object(duplicate))
            }),
        ]
        for (name, mutate) in cases {
            let state = try stateWithTimelineMutation(mutate)
            do {
                _ = try ClaudeState(state)
                Issue.record("\(name) timeline accepted")
            } catch {}
        }
    }

    @Test func threadProjectionRetainsAssistantSummaryForEveryExecution() throws {
        let fixture = try fixture("thread-reader.golden.json")
        let projected = try ClaudeState(try #require(fixture["thread"]))
        #expect(projected.turns.map(\.assistantText) == [String(repeating: "T", count: 600), "SECOND EXECUTION ANSWER"])
        for turn in projected.turns {
            #expect(turn.timeline.filter { $0.claudeKind == "assistant" }.count == 1)
            #expect(turn.timeline.filter { $0.claudeKind == "activity" }.isEmpty)
        }
    }

    @Test func checkpointForkDecodesWithCurrentEntitiesAndLatestMarkers() throws {
        let fixture = try fixture("checkpoint-fork.golden.json")
        let fork = try ClaudeState(try #require(fixture["fork"]))
        let activities = fork.history.filter { $0.claudeKind == "activity" }
        #expect(activities.map { $0["activity"]?["status"]?.stringValue } == ["completed", "cancelled"])
        let interactions = fork.history.filter { $0.claudeKind == "interaction" }
        #expect(interactions.map { $0["interaction"]?["status"]?.stringValue } == ["resolved", "cancelled"])
        #expect(fork.history.allSatisfy { !["review", "error"].contains($0.claudeKind) })
    }

    @Test func terminalOverviewAndExecutionPreviewKeepAssistant() throws {
        let fixture = try fixture("terminal-reader.golden.json")
        for (name, expected, unexpected) in [
            ("failed", "FAILED ASSISTANT", "LATER REASONING"),
            ("interrupted", "INTERRUPTED ASSISTANT", "LATER REASONING"),
            ("completed", "COMPLETED ASSISTANT", "LATER REASONING"),
        ] {
            let entry = try #require(fixture[name])
            let overview = try ClaudeState(try #require(entry["overview"]))
            let observation = try ThreadPublicObservation(json: try #require(entry["observation"]))
            let id = try #require(overview.turns.first?.id)
            let thread = try HarnessThread(id: JSONText("terminal-\(name)"), harnessID: "claude", revision: 1,
                sessionState: try #require(entry["overview"]), observation: observation, cwd: "/tmp", settings: .object([:]),
                createdAt: 1_000, updatedAt: 2_000, title: "Terminal", tags: [])
            let plugin = ClaudeHarnessPlugin()
            let projection = try plugin.projectOverview(input: .init(thread: thread), availableColumns: 3)
            #expect(projection.view.summary.contains(expected))
            #expect(!projection.view.summary.contains(unexpected))
            let preview = try #require(try plugin.executionPreview(thread: thread, executionID: id))
            #expect(preview.excerpt.string == expected)
            #expect(!preview.excerpt.string.contains(unexpected))
        }
    }

    @Test func elicitationOverviewBindsPublicInteraction() throws {
        let fixture = try fixture("elicitation-reader.golden.json")
        let overview = try ClaudeState(try #require(fixture["overview"]))
        let observation = try ThreadPublicObservation(json: try #require(fixture["observation"]))
        let binding = claudePublicInteractions(overview, observation)
        let interaction = try #require(binding["ask-elicitation"])
        #expect(interaction.title == "MCP form")
        #expect(interaction.kind == .question)
        #expect(interaction.actions.map(\.id) == ["submit", "deny", "cancel"])
        #expect(interaction.questions.count == 1)
        #expect(interaction.questions[0].answerFormat == .jsonObject)
        #expect(interaction.questions[0].prompt.string.contains("& < >"))
        #expect(interaction.questions[0].prompt.string.contains("\u{2028}"))
        let thread = try HarnessThread(id: JSONText("elicitation"), harnessID: "claude", revision: 1,
            sessionState: try #require(fixture["overview"]), observation: observation, cwd: "/tmp", settings: .object([:]),
            createdAt: 1_000, updatedAt: 2_000, title: "Elicitation", tags: [])
        let projection = try ClaudeHarnessPlugin().projectOverview(input: .init(thread: thread), availableColumns: 3)
        #expect(projection.view.pendingPublicInteraction == interaction)
    }

    private func fixture(_ name: String = "timeline-reader.golden.json") throws -> JSONValue {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("internal/plugins/harness/claude/testdata/" + name)
        return try JSONValue(data: Data(contentsOf: file))
    }

    private func stateWithTimelineMutation(_ mutate: (inout [JSONText: JSONValue], inout [JSONValue]) -> Void) throws -> JSONValue {
        let fixture = try fixture()
        var state = try #require(fixture["state"]?.objectValue)
        var turns = try #require(state["turns"]?.arrayValue)
        var turn = try #require(turns.first?.objectValue)
        var timeline = try #require(turn["timeline"]?.arrayValue)
        mutate(&turn, &timeline)
        turn["timeline"] = .array(timeline)
        turns[0] = .object(turn)
        state["turns"] = .array(turns)
        return .object(state)
    }
}
