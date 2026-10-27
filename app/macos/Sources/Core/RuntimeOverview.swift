import Foundation

extension RuntimeClient {
    public func updateOverviewContext(_ context: JSONValue?) async throws {
        try assertOpen()
        try saveOverviewContext(context)
        if clientID != nil { try await publishOverviewContext(context) }
    }
    func publishOverviewContext(_ context: JSONValue?) async throws {
        _ = try await sessionPost("/overview/context", fields: ["context": context ?? .null])
    }
    public func claimOverviewFilter(_ requestId: String) async throws -> Bool {
        try assertOpen()
        guard overviewRequest?["requestId"]?.stringValue == requestId, let expected = streamID else { return false }
        do {
            let value = try await sessionPost("/overview/claim", fields: ["requestId": .text(requestId)])
            guard let claimed = value.boolValue else { throw RuntimeError("INVALID_RESPONSE", "Runtime returned an invalid overview claim") }
            return claimed
        } catch { if streamID != expected { return false }; throw error }
    }
    public func acknowledgeOverviewFilter(_ acknowledgement: JSONValue) async throws {
        try assertOpen()
        guard let requestID = acknowledgement["requestId"]?.stringValue,
              let status = acknowledgement["status"]?.stringValue,
              ["applied", "unchanged", "stale", "unavailable"].contains(status),
              let context = acknowledgement["context"] else { throw RuntimeError("INVALID_REQUEST", "Invalid overview acknowledgement") }
        try validateOverviewContext(context)
        guard let request = overviewRequest, request["requestId"]?.stringValue == requestID, clientID != nil else {
            throw RuntimeError("OVERVIEW_UNAVAILABLE", "Overview request belongs to an expired subscription")
        }
        if status == "applied" || status == "unchanged" {
            let scopeMatches = request["scope"] == nil || request["scope"] == .null || context["selectedScope"] == request["scope"]
            guard context["contextId"] == request["contextId"], context["selectedTag"] == request["tag"], scopeMatches else {
                throw RuntimeError("INVALID_REQUEST", "Overview acknowledgement does not confirm the requested filter")
            }
        }
        if let previous = overviewContext, context["contextId"] == previous["contextId"],
           context["revision"]!.intValue! >= previous["revision"]!.intValue! { try saveOverviewContext(context) }
        overviewRequest = nil
        _ = try await sessionPost("/overview/ack", fields: ["acknowledgement": acknowledgement])
    }
    private func saveOverviewContext(_ context: JSONValue?) throws {
        if let context { try validateOverviewContext(context) }
        let body = try runtimeObject(["clientId": .text("00000000-0000-0000-0000-000000000000"), "context": context ?? .null]).encodedData()
        guard body.count <= RuntimeProtocol.maxOverviewBytes else { throw RuntimeError("REQUEST_TOO_LARGE", "Overview context exceeds the 2 MiB limit") }
        if let context, case .string(let id) = context["contextId"] {
            guard !retiredContexts.contains(id) else { throw RuntimeError("STALE_CONTEXT", "Overview context has been revoked") }
            if let previous = overviewContext, previous["contextId"] == context["contextId"] {
                guard context["revision"]!.intValue! >= previous["revision"]!.intValue!,
                      context["revision"] != previous["revision"] || context == previous else {
                    throw RuntimeError("STALE_CONTEXT", "Overview revision must increase when presentation changes")
                }
            } else if let previous = overviewContext, case .string(let old) = previous["contextId"] {
                guard retiredContexts.count < 4096 else { throw RuntimeError("CONTEXT_CAPACITY", "Reopen this client after too many overview context rotations") }
                retiredContexts.insert(old)
            }
        } else if let previous = overviewContext, case .string(let old) = previous["contextId"] {
            guard retiredContexts.count < 4096 else { throw RuntimeError("CONTEXT_CAPACITY", "Reopen this client after too many overview context rotations") }
            retiredContexts.insert(old)
        }
        overviewContext = context
    }

    private func validateOverviewContext(_ value: JSONValue) throws {
        let required = Set(["contextId", "revision", "overviewVisible", "focused", "documentVisible", "mokuOpen", "settingsOpen", "selectedThread", "followUpThread", "view", "selectedTag", "filters", "recentActions"].map { JSONText($0) })
        let allowed = required.union([JSONText("selectedScope")])
        guard let object = value.objectValue, required.isSubset(of: Set(object.keys)), Set(object.keys).isSubset(of: allowed),
              validText(value["contextId"], limit: 256), let revision = value["revision"]?.intValue, (0...RuntimeProtocol.maximumSafeInteger).contains(revision),
              ["overviewVisible", "focused", "documentVisible", "mokuOpen", "settingsOpen"].allSatisfy({ value[$0]?.boolValue != nil }),
              validThreadRef(value["selectedThread"], nullable: true), validThreadRef(value["followUpThread"], nullable: true),
              ["default", "archived"].contains(value["view"]?.stringValue ?? ""),
              value["selectedTag"] == .null || validText(value["selectedTag"], limit: 4096),
              value["selectedScope"] == nil || value["selectedScope"] == .null || validText(value["selectedScope"], limit: 4096),
              let filters = value["filters"]?.arrayValue, filters.count <= 2048,
              let actions = value["recentActions"]?.arrayValue, actions.count <= 32 else {
            throw RuntimeError("INVALID_REQUEST", "Invalid overview context")
        }
        var tags = Set<String>()
        for filter in filters {
            let keys = Set(filter.objectValue?.keys.map { $0.string } ?? [])
            guard validText(filter["tag"], limit: 4096), case .string(let tag) = filter["tag"],
                  filter["scope"] == nil || filter["scope"] == .null || validText(filter["scope"], limit: 4096),
                  tags.insert((filter["scope"]?.stringValue ?? "") + "\u{0}" + tag.string).inserted,
                  keys.isSuperset(of: ["tag", "kind", "aliases", "count", "threads"]), keys.isSubset(of: ["tag", "kind", "aliases", "count", "threads", "scope"]),
                  ["directory", "semantic"].contains(filter["kind"]?.stringValue ?? ""),
                  let count = filter["count"]?.intValue, count >= 0,
                  let aliases = filter["aliases"]?.arrayValue, aliases.count <= 2048,
                  aliases.allSatisfy({ validText($0, limit: 4096) }),
                  let threads = filter["threads"]?.arrayValue, threads.count <= 20000,
                  threads.allSatisfy({ validThreadRef($0, nullable: false) }) else { throw RuntimeError("INVALID_REQUEST", "Invalid overview filter") }
        }
        for action in actions {
            guard let object = action.objectValue, Set(object.keys.map { $0.string }).isSubset(of: Set(["kind", "at", "tag", "view", "thread", "text"])),
                  ["filter", "view", "open-thread", "moku-input", "thread-input"].contains(action["kind"]?.stringValue ?? ""),
                  let at = action["at"]?.numberValue, at.isFinite, at >= 0 else { throw RuntimeError("INVALID_REQUEST", "Invalid overview action") }
            if let tag = action["tag"], tag != .null, !validText(tag, limit: 4096) { throw RuntimeError("INVALID_REQUEST", "Invalid action tag") }
            if let view = action["view"], !["default", "archived"].contains(view.stringValue ?? "") { throw RuntimeError("INVALID_REQUEST", "Invalid action view") }
            if let thread = action["thread"], !validThreadRef(thread, nullable: false) { throw RuntimeError("INVALID_REQUEST", "Invalid action thread") }
            if let text = action["text"], text.stringValue == nil || text.stringValue!.utf16.count > 16000 { throw RuntimeError("INVALID_REQUEST", "Invalid action text") }
        }
    }
    private func validText(_ value: JSONValue?, limit: Int) -> Bool {
        guard let string = value?.stringValue else { return false }; return !string.isEmpty && string.utf16.count <= limit
    }
    private func validThreadRef(_ value: JSONValue?, nullable: Bool) -> Bool {
        if nullable && value == .null { return true }
        guard let object = value?.objectValue, Set(object.keys.map { $0.string }) == Set(["threadId", "typeId"]) else { return false }
        return validText(value?["threadId"], limit: 256) && validText(value?["typeId"], limit: 256)
    }
}
