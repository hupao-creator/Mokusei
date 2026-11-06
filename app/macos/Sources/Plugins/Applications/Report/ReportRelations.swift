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
    // Current Thread status is separate from the cited execution's evidence.
    var currentStatus: (chinese: String, english: String) {
        switch current?.status {
        case .running: return backgroundRunning ? ("运行中 · 后台运行中", "Running · Background running") : ("运行中", "Running")
        case .waitingForUser: return backgroundRunning ? ("等待你的响应 · 后台运行中", "Waiting for your response · Background running") : ("等待你的响应", "Waiting for your response")
        case .completed where backgroundRunning: return ("后台运行中", "Background running")
        case .completed: return ("已完成", "Completed")
        case .failed: return backgroundRunning ? ("执行失败 · 后台运行中", "Failed · Background running") : ("执行失败", "Failed")
        case .interrupted: return backgroundRunning ? ("已中断 · 后台运行中", "Interrupted · Background running") : ("已中断", "Interrupted")
        case nil: return backgroundRunning ? ("后台运行中", "Background running") : ("状态未知", "Status unavailable")
        }
    }

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
    static var relations: ApplicationOperation<JSONText, NativeReportRelations> {
        .init(id: "report.relations", ownerPluginID: "report", kind: .query,
            input: .init(decode: { try NativeApplicationRecord($0, path: "report identity", keys: ["reportId"]).identifier("reportId") },
                encode: { .object(["reportId": .string($0)]) }),
            output: .init(decode: NativeReportRelations.init, encode: { $0.json }))
    }
}
