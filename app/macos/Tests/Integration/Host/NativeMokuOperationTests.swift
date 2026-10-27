import Testing
import MokuseiCore
import MokuseiUI

struct NativeMokuOperationTests {
    @Test func sendAcknowledgementDoesNotRequireANewExecution() {
        for started in [false, true] {
            let pending: JSONValue = .object([
                "type": .text("tool-operation"), "id": .text("send"),
                "executionId": .text("moku-execution"), "name": .text("send_to_thread"),
                "arguments": .object(["threadId": .text("target"), "prompt": .text("continue")])
            ])
            var completed = pending.objectValue!
            completed["completedAt"] = .number(2)
            completed["result"] = .object([
                "ok": .bool(true), "threadId": .text("target"), "executionId": .text("target-execution"),
                "startedNewExecution": .bool(started),
                "hint": .text("Execution completion, failure, and interruption are delivered automatically.")
            ])
            let running = NativeOverviewMokuOperation.project(transcript: .array([pending]))
            let sent = NativeOverviewMokuOperation.project(transcript: .array([.object(completed)]))
            #expect(running == [.init(id: "send", kind: .send, phase: .running, threadID: "target")])
            #expect(sent == [.init(id: "send", kind: .send, phase: .completed, threadID: "target")])

            completed["isError"] = .bool(true)
            completed["result"] = .object(["error": .text("thread is archived")])
            let rejected = NativeOverviewMokuOperation.project(transcript: .array([.object(completed)]))
            #expect(rejected == [.init(id: "send", kind: .send, phase: .failed, threadID: "target")])
        }
    }

    @Test func batchInterruptShowsEachTargetAndItsOutcome() {
        var item: [JSONText: JSONValue] = [
            "type": .text("tool-operation"), "id": .text("batch"),
            "executionId": .text("execution"), "name": .text("interrupt_thread"),
            "arguments": .object(["threadIds": .array([.text("first"), .text("second")])])
        ]
        let running = NativeOverviewMokuOperation.project(transcript: .array([.object(item)]))
        #expect(running.map(\.threadID) == ["first", "second"])
        #expect(running.map(\.phase) == [.running, .running])
        #expect(Set(running.map(\.id)).count == 2)

        item["completedAt"] = .number(2)
        item["result"] = .object(["ok": .bool(false), "results": .array([
            .object(["threadId": .text("first"), "ok": .bool(true)]),
            .object(["threadId": .text("second"), "ok": .bool(false), "error": .text("unavailable")])
        ])])
        let completed = NativeOverviewMokuOperation.project(transcript: .array([.object(item)]))
        #expect(completed.map(\.id) == running.map(\.id))
        #expect(completed.map(\.threadID) == ["first", "second"])
        #expect(completed.map(\.phase) == [.completed, .failed])

        item["isError"] = .bool(true)
        item["result"] = .object(["error": .text("tool execution cancelled")])
        let failed = NativeOverviewMokuOperation.project(transcript: .array([.object(item)]))
        #expect(failed.map(\.phase) == [.failed, .failed])
    }
}
