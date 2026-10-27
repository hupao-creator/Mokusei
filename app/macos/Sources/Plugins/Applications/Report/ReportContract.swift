import MokuseiCore
import MokuseiPluginAPI

struct NativeReportView: Hashable, Sendable {
    let previewText: JSONText
    let contentRevision: JSONText
    let relatedExecutions: [ApplicationExecutionRef]
    init(json: JSONValue) throws {
        let r = try NativeApplicationRecord(json, path: "report view", keys: ["previewText", "contentRevision", "relatedExecutions"])
        previewText = try r.text("previewText"); contentRevision = try r.identifier("contentRevision")
        relatedExecutions = try r.array("relatedExecutions").map { value in
            let reference = try NativeApplicationRecord(value, path: "report execution", keys: ["thread", "executionId"])
            let thread = try NativeApplicationRecord(reference.require("thread"), path: "report thread", keys: ["threadId", "typeId"])
            guard try thread.text("typeId") == "agent" else { throw PluginContractError("Report execution must reference an Agent thread") }
            return try ApplicationExecutionRef(thread: ApplicationThreadRef(threadID: thread.identifier("threadId"), typeID: "agent"), executionID: reference.identifier("executionId"))
        }
        guard relatedExecutions.count <= 256, Set(relatedExecutions.map(\.thread.threadID)).count == relatedExecutions.count else {
            throw PluginContractError("Report execution references must be unique and contain at most 256 threads")
        }
    }
    var json: JSONValue {
        .object(["previewText": .string(previewText), "contentRevision": .string(contentRevision),
                 "relatedExecutions": .array(relatedExecutions.map { .object(["thread": $0.thread.json, "executionId": .string($0.executionID)]) })])
    }
}

struct NativeReportCardProjection {
    let previewText: JSONText
    let relatedThreadCount: Int
}

@MainActor enum NativeReportContracts {
    static var thread: ApplicationValueKey<NativeReportView> {
        .init(id: "report.document", ownerPluginID: "report", codec: .init(decode: NativeReportView.init, encode: { $0.json }))
    }
    static var html: ApplicationOperation<JSONText, ApplicationHTMLDocument> {
        .init(id: "report.html", ownerPluginID: "report", kind: .query,
              input: .init(decode: { try NativeApplicationRecord($0, path: "report identity", keys: ["reportId"]).identifier("reportId") },
                           encode: { .object(["reportId": .string($0)]) }),
              output: .init(decode: { json in
                  let r = try NativeApplicationRecord(json, path: "report HTML", keys: ["html", "contentRevision"])
                  let html = try r.text("html")
                  guard html.string.unicodeScalars.count <= 1_000_000 else { throw PluginContractError("Report HTML exceeds the document limit") }
                  return try ApplicationHTMLDocument(html: html, contentRevision: r.identifier("contentRevision"))
              }, encode: { .object(["html": .string($0.html), "contentRevision": .string($0.contentRevision)]) }))
    }
}
