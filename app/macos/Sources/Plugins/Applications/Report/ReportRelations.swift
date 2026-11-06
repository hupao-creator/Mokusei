import Foundation
import MokuseiCore
import MokuseiPluginAPI

struct NativeReportExecutionFacts: Hashable, Sendable {
    let id: JSONText
    let status: PublicExecution.Status
    let startedAt: Double
    let finishedAt: Double?

    init(_ json: JSONValue) throws {
        let r = try NativeApplicationRecord(json, path: "related execution", keys: ["executionId", "status", "startedAt", "finishedAt", "summary"])
        id = try r.identifier("executionId")
        guard let status = try PublicExecution.Status(rawValue: r.text("status").string) else { throw PluginContractError("Invalid related execution status") }
        self.status = status
        startedAt = Double(try r.integer("startedAt"))
        finishedAt = try r.fields["finishedAt"].map { _ in Double(try r.integer("finishedAt")) }
        guard finishedAt.map({ $0 >= startedAt }) ?? true,
              (status == .running || status == .waitingForUser) == (finishedAt == nil) else {
            throw PluginContractError("Invalid related execution timing")
        }
    }
}

struct NativeReportRelation: Hashable, Sendable {
    let reference: ApplicationExecutionRef
    let threadTitle: JSONText?
    let current: NativeReportExecutionFacts?
    let execution: NativeReportExecutionFacts?
    let backgroundRunning: Bool
    let archived: Bool
    let unavailable: String
    let bindingCount: Int
    var historical: Bool { current.map { $0.id != reference.executionID } ?? false }

    init(_ json: JSONValue) throws {
        let r = try NativeApplicationRecord(json, path: "report relation", keys: ["reference", "thread", "execution", "unavailable", "bindingCount"])
        let ref = try NativeApplicationRecord(r.require("reference"), path: "reference", keys: ["thread", "executionId"])
        let thread = try NativeApplicationRecord(ref.require("thread"), path: "reference thread", keys: ["typeId", "threadId"])
        guard try thread.text("typeId") == "agent" else { throw PluginContractError("Expected ordinary Thread") }
        reference = try .init(thread: .init(threadID: thread.identifier("threadId"), typeID: "agent"), executionID: ref.identifier("executionId"))
        unavailable = try r.text("unavailable").string
        guard ["", "thread-missing", "execution-missing", "outside-scope"].contains(unavailable) else { throw PluginContractError("Invalid relation availability") }
        bindingCount = try r.integer("bindingCount")
        if try r.require("thread") == .null {
            threadTitle = nil; current = nil; backgroundRunning = false; archived = false
        } else {
            let source = try NativeApplicationRecord(r.require("thread"), path: "related Thread", keys: ["title", "harnessId", "cwd", "executionCwd", "archived", "currentExecution", "backgroundRunning"])
            threadTitle = try source.text("title")
            archived = try source.bool("archived")
            backgroundRunning = try source.bool("backgroundRunning")
            current = try source.require("currentExecution") == .null ? nil : NativeReportExecutionFacts(source.require("currentExecution"))
        }
        execution = try r.require("execution") == .null ? nil : NativeReportExecutionFacts(r.require("execution"))
        guard bindingCount >= 1, execution.map({ $0.id == reference.executionID }) ?? true,
              (unavailable.isEmpty == (execution != nil)) else { throw PluginContractError("Mismatched report execution") }
    }
}

struct NativeReportRelations: Sendable {
    let json: JSONValue
    let reportID: JSONText
    let revision: Int
    let items: [NativeReportRelation]
    init(json: JSONValue) throws {
        let r = try NativeApplicationRecord(json, path: "report relations", keys: ["reportId", "revision", "items"])
        reportID = try r.identifier("reportId"); revision = try r.integer("revision")
        items = try r.array("items").map(NativeReportRelation.init)
        guard items.count <= 256, Set(items.map(\.reference.thread.threadID)).count == items.count else { throw PluginContractError("Duplicate report relations") }
        self.json = json
    }
}

extension NativeReportContracts {
    static var unlink: ApplicationOperation<NativeReportUnlink, JSONValue> {
        .init(id: "report.unlink", ownerPluginID: "report", kind: .command,
            input: .init(decode: NativeReportUnlink.init, encode: { $0.json }),
            output: .init(decode: { $0 }, encode: { $0 }))
    }
    static var relations: ApplicationOperation<JSONText, NativeReportRelations> {
        .init(id: "report.relations", ownerPluginID: "report", kind: .query,
            input: .init(decode: { try NativeApplicationRecord($0, path: "report identity", keys: ["reportId"]).identifier("reportId") },
                encode: { .object(["reportId": .string($0)]) }),
            output: .init(decode: NativeReportRelations.init, encode: { $0.json }))
    }
}

struct NativeReportUnlink {
    let reportID: JSONText
    let reference: ApplicationExecutionRef
    let revision: Int
    init(reportID: JSONText, reference: ApplicationExecutionRef, revision: Int) {
        self.reportID = reportID; self.reference = reference; self.revision = revision
    }
    init(json: JSONValue) throws {
        let r = try NativeApplicationRecord(json, path: "report unlink", keys: ["reportId", "threadId", "executionId", "expectedRevision"])
        reportID = try r.identifier("reportId"); revision = try r.integer("expectedRevision")
        reference = try .init(thread: .init(threadID: r.identifier("threadId"), typeID: "agent"), executionID: r.identifier("executionId"))
    }
    var json: JSONValue {
        .object(["reportId": .string(reportID), "threadId": .string(reference.thread.threadID),
            "executionId": .string(reference.executionID), "expectedRevision": .integer(revision)])
    }
}
