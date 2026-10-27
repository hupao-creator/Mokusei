import Foundation

/// Runtime records stay lossless JSON: provider-owned session envelopes are never flattened.
public enum RuntimeState {
    public static func validateSnapshot(_ value: JSONValue) throws {
        guard let revision = value["revision"]?.intValue, (0...RuntimeProtocol.maximumSafeInteger).contains(revision),
              value["defaultCwd"]?.stringValue != nil,
              value["threads"]?.arrayValue != nil,
              value["executions"]?.arrayValue != nil,
              value["applicationThreads"]?.arrayValue != nil,
              value["settings"]?.objectValue != nil,
              let settingsRevision = value["settingsRevision"]?.intValue, (0...RuntimeProtocol.maximumSafeInteger).contains(settingsRevision) else {
            throw RuntimeError("INVALID_SNAPSHOT", "Runtime returned an incomplete state snapshot")
        }
        if let searchRevision = value["searchRevision"],
           searchRevision.intValue.map({ (0...RuntimeProtocol.maximumSafeInteger).contains($0) }) != true {
            throw RuntimeError("INVALID_SNAPSHOT", "Invalid search settings revision")
        }
        for field in ["threads", "applicationThreads"] {
            var ids = Set<JSONText>()
            for record in value[field]!.arrayValue! {
                guard case .string(let id) = record["id"], ids.insert(id).inserted else {
                    throw RuntimeError("INVALID_SNAPSHOT", "Runtime collection has missing or duplicate identities")
                }
            }
        }
    }

    public static func applying(_ mutation: JSONValue, to current: JSONValue) throws -> JSONValue {
        guard let revision = mutation["revision"]?.intValue, let base = mutation["baseRevision"]?.intValue,
              (0...RuntimeProtocol.maximumSafeInteger).contains(revision), (0...RuntimeProtocol.maximumSafeInteger).contains(base),
              let oldRevision = current["revision"]?.intValue, mutation["type"]?.stringValue == "state-patched",
              var next = current.objectValue else { throw RuntimeError("INVALID_EVENT", "Runtime state mutation is malformed") }
        if revision <= oldRevision { return current }
        guard base == oldRevision, revision > base else { throw RuntimeError("REVISION_GAP", "Runtime state requires a fresh snapshot") }
        for field in ["threads", "applicationThreads"] {
            if let patch = mutation[field] {
                next[JSONText(field)] = try collection(current[field], patch: patch, kind: field == "threads" ? .thread
                    : .applicationThread)
            }
        }
        for field in ["tagRedirects", "defaultCwd", "executions", "agentRuns", "settings", "settingsRevision", "searchRevision", "plugins"] {
            if let value = mutation[field] { next[JSONText(field)] = value }
        }
        next[JSONText("revision")] = .integer(revision)
        let result = JSONValue.object(next)
        try validateSnapshot(result)
        return result
    }

    private enum RecordKind { case thread, applicationThread }

    private static func collection(_ current: JSONValue?, patch: JSONValue, kind: RecordKind) throws -> JSONValue {
        guard let current = current?.arrayValue, let upserts = patch["upserts"]?.arrayValue,
              let removed = patch["removedIds"]?.arrayValue else { throw RuntimeError("INVALID_EVENT", "Invalid runtime collection patch") }
        var byID: [JSONText: JSONValue] = [:]
        var order: [JSONText] = []
        for record in current {
            guard case .string(let id) = record["id"] else { throw RuntimeError("INVALID_EVENT", "Missing runtime record identity") }
            byID[id] = record; order.append(id)
        }
        for value in removed {
            guard case .string(let id) = value else { throw RuntimeError("INVALID_EVENT", "Invalid removed record identity") }
            byID.removeValue(forKey: id)
        }
        order.removeAll { byID[$0] == nil }
        for record in upserts {
            guard case .string(let id) = record["id"] else { throw RuntimeError("INVALID_EVENT", "Invalid upsert identity") }
            let previous = byID[id]
            let keep: Bool
            switch kind {
            case .thread:
                guard let revision = record["revision"]?.intValue, (0...RuntimeProtocol.maximumSafeInteger).contains(revision) else { throw RuntimeError("INVALID_EVENT", "Missing or invalid record revision") }
                keep = (previous?["revision"]?.intValue).map { $0 >= revision } ?? false
            case .applicationThread:
                keep = previous != nil && previous?["revision"] == record["revision"] && previous?["ref"]?["typeId"] == record["ref"]?["typeId"]
            }
            if previous == nil { order.append(id) }
            if !keep { byID[id] = record }
        }
        if let supplied = patch["order"] {
            guard let array = supplied.arrayValue else { throw RuntimeError("INVALID_EVENT", "Invalid collection ordering") }
            var suppliedOrder: [JSONText] = []; var unique = Set<JSONText>()
            for value in array {
                guard case .string(let id) = value, byID[id] != nil, unique.insert(id).inserted else {
                    throw RuntimeError("REVISION_GAP", "Collection order references missing or duplicate records")
                }
                suppliedOrder.append(id)
            }
            guard unique.count == byID.count else { throw RuntimeError("REVISION_GAP", "Collection order omitted runtime records") }
            order = suppliedOrder
        }
        return .array(order.compactMap { byID[$0] })
    }
}

struct RuntimeMutationCommit: Sendable {
    let mutation: JSONValue
    let state: JSONValue
}

extension RuntimeState {
    /// nil requests the existing bounded refetch on a gap. Each replay retains
    /// its own COW state; pairing all mutations with the final state is invalid.
    static func replaying(_ mutations: [JSONValue], over snapshot: JSONValue) throws -> [RuntimeMutationCommit]? {
        var merged = snapshot
        var applied: [RuntimeMutationCommit] = []
        for mutation in mutations {
            guard let revision = mutation["revision"]?.intValue,
                  let current = merged["revision"]?.intValue else { throw RuntimeError("INVALID_EVENT", "Runtime mutation has no revision") }
            if revision <= current { continue }
            if mutation["baseRevision"]?.intValue != current { return nil }
            merged = try applying(mutation, to: merged)
            applied.append(RuntimeMutationCommit(mutation: mutation, state: merged))
        }
        return applied
    }
}
