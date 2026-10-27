import Foundation
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
import MokuseiPluginAPI
@testable import MokuseiUI

@MainActor @Suite(.serializedNative)
struct NativeMokuDispatchTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOKU_STATUS_NATIVE_FIXTURE"] != nil, "Requires Go dispatch snapshots in MOKU_STATUS_NATIVE_FIXTURE; see tools/verification/moku"))
    func runtimeSnapshotsKeepSuccessfulDispatchAndFailureReason() throws {
        let path = try #require(ProcessInfo.processInfo.environment["MOKU_STATUS_NATIVE_FIXTURE"])
        let records = try #require(JSONValue(data: Data(contentsOf: URL(fileURLWithPath: path))).arrayValue)
        try #require(records.count == 3)
        let success = try #require(NativeMokuTalkMessage.latest(in: HarnessThread(json: records[0])))
        #expect(success.dispatch?.phase == .started)
        #expect(success.text == "Thread 已启动")
        #expect(success.dispatch?.threadID != nil)
        let followupThread = try HarnessThread(json: records[1])
        let followup = try #require(NativeMokuTalkMessage.latest(in: followupThread))
        #expect(followup == success) // Sending again must not leave a false failed dispatch bubble.
        let send = try #require(NativeOverviewMokuOperation.project(transcript: followupThread.transcript).last)
        #expect(send.kind == .send && send.phase == .completed)
        let failure = try #require(NativeMokuTalkMessage.latest(in: HarnessThread(json: records[2])))
        #expect(failure.dispatch?.phase == .failed)
        #expect(failure.text == "派发失败")
        #expect(failure.dispatch?.error?.contains("worktree") == true)
    }

    private let prompt = "  原始输入\n不生成标题 👩🏽‍💻  "
    private func operation(id: JSONText = "dispatch", options: JSONValue = .object([
        "model": .text("gpt-6.1-sol"), "thinking": .object(["mode": .text("effort"), "effort": .text("xhigh")])
    ]), completed: Bool = false, result: JSONValue? = nil,
       error: Bool = false, execution: JSONText = "execution") -> JSONValue {
        let arguments: [JSONText: JSONValue] = ["harnessId": .text("codex"), "prompt": .text(prompt),
            "options": options, "worktree": .bool(false)]
        var item: [JSONText: JSONValue] = ["type": .text("tool-operation"), "id": .string(id),
            "executionId": .string(execution), "name": .text("create_thread"), "arguments": .object(arguments)]
        if completed { item["completedAt"] = .number(2) }
        if let result { item["result"] = result }
        if error { item["isError"] = .bool(true) }
        return .object(item)
    }
    private func thread(_ items: [JSONValue], id: JSONText = "moku", execution: JSONText = "execution",
                        status: PublicExecution.Status = .running, moku: Bool = true) throws -> HarnessThread {
        try HarnessThread(id: id, harnessID: "codex", revision: 1, sessionState: .null,
            observation: .init(latestExecution: try .init(executionID: execution, status: status, startedAt: 1,
                finishedAt: status == .running ? nil : 2)),
            cwd: "/tmp", settings: .object([:]), createdAt: 1, updatedAt: 2,
            title: "Moku", tags: [], moku: moku ? true : nil, transcript: .array(items))
    }

    @Test func auditLifecycleRequiresExplicitSuccessAndKeepsOriginalInputInDetails() throws {
        let pending = try #require(NativeMokuTalkMessage.latest(in: thread([operation()])))
        #expect(pending.dispatch?.phase == .dispatching)
        #expect(pending.text == "正在派发任务" && !pending.text.contains(prompt))
        #expect(pending.dispatch?.prompt == prompt)
        #expect(pending.dispatch?.model == "gpt-6.1-sol" && pending.dispatch?.thinking == "xhigh")
        #expect(pending.dispatch?.threadID == nil)
        let success: JSONValue = .object(["ok": .bool(true), "threadId": .text("child"), "title": .text("ignored")])
        let started = try #require(NativeMokuTalkMessage.latest(in: thread([operation(completed: true, result: success)])))
        #expect(started.id == pending.id && started.dispatch?.phase == .started)
        #expect(started.text == "Thread 已启动" && started.dispatch?.threadID == "child")
        for result in [JSONValue.null, .object(["ok": .bool(false)]), .object(["ok": .bool(true)]),
                       .object(["threadId": .text("child")])] {
            #expect(NativeMokuTalkMessage.latest(in: try thread([operation(completed: true, result: result)]))?.dispatch?.phase == .failed)
        }
        let failed = try #require(NativeMokuTalkMessage.latest(in: thread([operation(completed: true,
            result: .object(["error": .text("provider unavailable")]), error: true)])))
        #expect(failed.dispatch?.phase == .failed && failed.dispatch?.error == "provider unavailable")
        #expect(failed.dispatch?.threadID == nil)
        #expect(NativeMokuTalkMessage.latest(in: try thread([operation()], status: .interrupted))?.dispatch?.phase == .failed)
    }

    @Test func providerIdentityAndThinkingModesNeverInventDefaults() throws {
        let value = try #require(NativeMokuTalkMessage.latest(in: thread([operation(options: .object([
            "provider": .text("deepseek"), "model": .text("deepseek-v4.1-flash"), "thinking": .object(["mode": .text("effort"), "effort": .text("high")])
        ]))]))?.dispatch)
        #expect(value.model == "deepseek-v4.1-flash" && value.provider == "deepseek" && value.thinking == "high")
        for mode in ["fixed", "on", "off"] {
            let dispatch = NativeMokuTalkMessage.latest(in: try thread([operation(options: .object([
                "thinking": .object(["mode": .text(mode)])
            ]))]))?.dispatch
            #expect(dispatch?.model == nil && dispatch?.thinking == mode)
        }
        let unknown = NativeMokuTalkMessage.latest(in: try thread([operation(options: .object([:]))]))?.dispatch
        #expect(unknown?.model == nil && unknown?.thinking == nil && unknown?.configuration == "")
    }

    @Test func resultUpdatesVisibleOrDeferredCallWithoutResurrectingDismissedCall() throws {
        let pending = try #require(NativeMokuTalkMessage.latest(in: thread([operation()])))
        let started = try #require(NativeMokuTalkMessage.latest(in: thread([operation(completed: true,
            result: .object(["ok": .bool(true), "threadId": .text("child")]))])))
        var state = NativeMokuTalkState()
        state.receive(pending); state.setPresented(true); state.receive(started)
        #expect(state.message == started && state.presented)
        state.dismiss(); state.receive(pending); state.receive(started)
        #expect(state.message == nil)
        state.receive(nil); state.receive(started)
        #expect(state.message == nil)
        let scene = NativeMokuSceneState()
        scene.setInputOpen(true); scene.receiveTalk(pending); scene.receiveTalk(started)
        #expect(scene.inputOpen && scene.talkPresentation.message == started && !scene.talkPresentation.presented)
        scene.setInputOpen(false)
        #expect(scene.talkPresentation.message == started)
    }

    @Test func scopedLatestMessageSharesTalkOrderingWithoutUsingTitles() throws {
        let talk: JSONValue = .object(["type": .text("tool-operation"), "id": .text("talk"),
            "executionId": .text("execution"), "name": .text("talk"), "completedAt": .number(2),
            "arguments": .object(["text": .text("真实 talk")])])
        #expect(NativeMokuTalkMessage.latest(in: try thread([operation(), talk]))?.text == "真实 talk")
        #expect(NativeMokuTalkMessage.latest(in: try thread([talk, operation()]))?.dispatch != nil)
        #expect(NativeMokuTalkMessage.latest(in: try thread([operation(execution: "old")])) == nil)
        #expect(NativeMokuTalkMessage.latest(in: try thread([operation()], moku: false)) == nil)
        #expect(NativeMokuTalkMessage.latest(in: try thread([operation()], id: "replacement"))?.id !=
                NativeMokuTalkMessage.latest(in: try thread([operation()]))?.id)
    }

    @Test func talkBudgetDoesNotTruncateDispatchInputOrReplaceItWithOversizedTalk() throws {
        let original = String(repeating: "输入 👩🏽‍💻\n", count: 80)
        #expect(original.unicodeScalars.count > NativeMokuTalkMessage.maximumCodePoints)
        var dispatch = operation().objectValue!, arguments = dispatch["arguments"]!.objectValue!
        arguments["prompt"] = .text(original); dispatch["arguments"] = .object(arguments)
        let expected = try #require(NativeMokuTalkMessage.latest(in: thread([.object(dispatch)])))
        #expect(expected.dispatch?.prompt == original && !expected.text.contains(original))
        let oversizedTalk: JSONValue = .object(["type": .text("tool-operation"), "id": .text("oversized-talk"),
            "executionId": .text("execution"), "name": .text("talk"), "completedAt": .number(2),
            "arguments": .object(["text": .text(String(repeating: "😀", count: 161))])])
        #expect(NativeMokuTalkMessage.latest(in: try thread([.object(dispatch), oversizedTalk])) == expected)
    }

    @Test func selectedDispatchUpdatesAfterNewerMessagesWithoutCrossingOwners() throws {
        let a = operation(id: "a"), b = operation(id: "b")
        let selected = try #require(NativeMokuTalkMessage.latest(in: thread([a])))
        let failed = operation(id: "a", completed: true,
            result: .object(["error": .text("A failed after B arrived")]), error: true)
        let current = try thread([failed, b])
        #expect(NativeMokuTalkMessage.latest(in: current)?.id != selected.id)
        let detail = try #require(NativeMokuTalkMessage.dispatch(id: selected.id, in: current))
        #expect(detail.dispatch?.phase == .failed && detail.dispatch?.error == "A failed after B arrived")
        #expect(NativeMokuTalkMessage.dispatch(id: selected.id, in: try thread([failed, b], id: "replacement")) == nil)
        let talk: JSONValue = .object(["type": .text("tool-operation"), "id": .text("new-talk"),
            "executionId": .text("execution"), "name": .text("talk"), "completedAt": .number(3),
            "arguments": .object(["text": .text("B feedback")])])
        #expect(NativeMokuTalkMessage.dispatch(id: selected.id, in: try thread([failed, talk])) == detail)
    }
}
