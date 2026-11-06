import Testing
import MokuseiCore
@testable import MokuseiApplications

struct NativeReportStatusTests {
    private func relation(status: String?, background: Bool = false) throws -> NativeReportRelation {
        let reference: JSONValue = .object([
            "thread": .object(["typeId": .text("agent"), "threadId": .text("thread")]),
            "executionId": .text("historical")
        ])
        func execution(_ id: String, _ status: String, finished: Bool) -> JSONValue {
            var fields: [JSONText: JSONValue] = ["executionId": .text(id), "status": .text(status), "startedAt": .number(1)]
            if finished { fields["finishedAt"] = .number(2) }
            return .object(fields)
        }
        return try NativeReportRelation(.object([
            "reference": reference,
            "thread": .object(["title": .text("Thread"), "harnessId": .text("codex"),
                "cwd": .text(""), "executionCwd": .text(""), "archived": .bool(false),
                "backgroundRunning": .bool(background),
                "currentExecution": status.map { execution("current", $0, finished: !["running", "waiting-for-user"].contains($0)) } ?? .null]),
            "execution": execution("historical", "completed", finished: true),
            "unavailable": .text(""), "bindingCount": .number(1)
        ]))
    }

    @Test func currentStatusDoesNotReplaceHistoricalEvidence() throws {
        let running = try relation(status: "running")
        #expect(running.historical)
        #expect(running.currentStatus.english == "Running")
        #expect(running.execution?.id == "historical")
        #expect(running.execution?.status == .completed)
        #expect(running.execution?.finishedAt == 2)
        #expect(try relation(status: "waiting-for-user").currentStatus.english == "Waiting for your response")
        #expect(try relation(status: "waiting-for-user", background: true).currentStatus.english == "Waiting for your response · Background running")
        #expect(try relation(status: "completed", background: true).currentStatus.english == "Background running")
        #expect(try relation(status: "completed").currentStatus.english == "Completed")
        #expect(try relation(status: "failed").currentStatus.english == "Failed")
        #expect(try relation(status: "interrupted").currentStatus.english == "Interrupted")
        #expect(try relation(status: nil).currentStatus.english == "Status unavailable")
        #expect(try relation(status: nil, background: true).currentStatus.english == "Background running")
    }
}
