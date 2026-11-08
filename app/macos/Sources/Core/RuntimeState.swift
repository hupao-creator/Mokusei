import Foundation

/// Runtime records stay lossless JSON: provider-owned session envelopes are never flattened.
public enum RuntimeState {
    private static func validateFields(_ value: JSONValue) throws {
        guard let revision = value["revision"]?.intValue, (0...RuntimeProtocol.maximumSafeInteger).contains(revision),
              value["defaultCwd"]?.stringValue != nil,
              value["threads"]?.isArray == true,
              value["executions"]?.arrayValue != nil,
              value["applicationThreads"]?.isArray == true,
              value["settings"]?.objectValue != nil,
              let settingsRevision = value["settingsRevision"]?.intValue, (0...RuntimeProtocol.maximumSafeInteger).contains(settingsRevision) else {
            throw RuntimeError("INVALID_SNAPSHOT", "Runtime returned an incomplete state snapshot")
        }
        if let searchRevision = value["searchRevision"],
           searchRevision.intValue.map({ (0...RuntimeProtocol.maximumSafeInteger).contains($0) }) != true {
            throw RuntimeError("INVALID_SNAPSHOT", "Invalid search settings revision")
        }
    }

    public static func validateSnapshot(_ value: JSONValue) throws {
        try validateFields(value)
        for field in ["threads", "applicationThreads"] {
            if value[field]?.catalogValue != nil { continue }
            var ids = Set<JSONText>()
            for record in value[field]!.arrayValue! {
                guard case .string(let id) = record["id"], ids.insert(id).inserted else {
                    throw RuntimeError("INVALID_SNAPSHOT", "Runtime collection has missing or duplicate identities")
                }
            }
        }
    }

    /// Full snapshots cross the identity-validation boundary once. Later
    /// transactions retain immutable indexed roots, including buffered replays.
    public static func admittingSnapshot(_ value: JSONValue) throws -> JSONValue {
        try validateSnapshot(value)
        var fields = value.objectValue!
        for field in ["threads", "applicationThreads"] where value[field]?.catalogValue == nil {
            var records = RuntimeRecordCollection<JSONValue>()
            for record in value[field]!.arrayValue! {
                guard case .string(let id) = record["id"] else { preconditionFailure("Validated catalog identity missing") }
                records.updateValue(record, forKey: id)
            }
            fields[JSONText(field)] = .catalog(records)
        }
        return .object(fields)
    }

    public static func hasStateChanges(_ mutation: JSONValue) -> Bool {
        ["threads", "applicationThreads", "tagRedirects", "defaultCwd", "executions", "agentRuns",
         "settings", "settingsRevision", "searchRevision", "plugins"].contains { mutation[$0] != nil }
    }

    public static func applying(_ mutation: JSONValue, to current: JSONValue) throws -> JSONValue {
        guard let revision = mutation["revision"]?.intValue, let base = mutation["baseRevision"]?.intValue,
              (0...RuntimeProtocol.maximumSafeInteger).contains(revision), (0...RuntimeProtocol.maximumSafeInteger).contains(base),
              let oldRevision = current["revision"]?.intValue, mutation["type"]?.stringValue == "state-patched",
              current.objectValue != nil else { throw RuntimeError("INVALID_EVENT", "Runtime state mutation is malformed") }
        if revision <= oldRevision { return current }
        guard base == oldRevision, revision > base else { throw RuntimeError("REVISION_GAP", "Runtime state requires a fresh snapshot") }
        let current = try admittingSnapshot(current)
        var next = current.objectValue!
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
        try validateFields(result)
        return result
    }

    private enum RecordKind { case thread, applicationThread }

    private static func collection(_ current: JSONValue?, patch: JSONValue, kind: RecordKind) throws -> JSONValue {
        guard let current, current.isArray, let upserts = patch["upserts"]?.arrayValue,
              let removed = patch["removedIds"]?.arrayValue else { throw RuntimeError("INVALID_EVENT", "Invalid runtime collection patch") }
        var records: RuntimeRecordCollection<JSONValue>
        if let indexed = current.catalogValue { records = indexed }
        else {
            records = .init()
            for record in current.arrayValue! {
                guard case .string(let id) = record["id"], records[id] == nil else {
                    throw RuntimeError("INVALID_EVENT", "Missing or duplicate runtime record identity")
                }
                records.updateValue(record, forKey: id)
            }
        }
        let identifiedUpserts = try upserts.map { record -> (JSONText, JSONValue) in
            guard case .string(let id) = record["id"] else { throw RuntimeError("INVALID_EVENT", "Invalid upsert identity") }
            return (id, record)
        }
        let upsertIDs = Set(identifiedUpserts.map(\.0))
        var replacements = Set<JSONText>()
        for value in removed {
            guard case .string(let id) = value else { throw RuntimeError("INVALID_EVENT", "Invalid removed record identity") }
            // A same-transaction remove+upsert invalidates admission, not the
            // original order slot. The publisher uses it for same-revision
            // replacements; a supplied order remains the final authority.
            if upsertIDs.contains(id) { replacements.insert(id) }
            else { records.removeValue(forKey: id) }
        }
        for (id, record) in identifiedUpserts {
            // Consume the bypass once: duplicate later upserts still obey the
            // normal per-record revision guard.
            let previous = replacements.remove(id) == nil ? records[id] : nil
            let keep: Bool
            switch kind {
            case .thread:
                guard let revision = record["revision"]?.intValue, (0...RuntimeProtocol.maximumSafeInteger).contains(revision) else { throw RuntimeError("INVALID_EVENT", "Missing or invalid record revision") }
                keep = (previous?["revision"]?.intValue).map { $0 >= revision } ?? false
            case .applicationThread:
                keep = previous != nil && previous?["revision"] == record["revision"] && previous?["ref"]?["typeId"] == record["ref"]?["typeId"]
            }
            if !keep { records.updateValue(record, forKey: id) }
        }
        if let supplied = patch["order"] {
            guard let array = supplied.arrayValue else { throw RuntimeError("INVALID_EVENT", "Invalid collection ordering") }
            let order = try array.map { value -> JSONText in
                guard case .string(let id) = value else { throw RuntimeError("INVALID_EVENT", "Invalid collection ordering") }
                return id
            }
            try records.reorder(order)
        }
        return .catalog(records)
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
