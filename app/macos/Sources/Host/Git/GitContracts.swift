import Foundation
import MokuseiCore
import MokuseiPluginAPI

struct NativeGitSnapshot: Hashable, Sendable {
    let root: JSONText
    let branch: JSONText?
    let head: JSONText?
    let upstream: JSONText?
    let ahead: Int?
    let behind: Int?
    let additions: Int?
    let deletions: Int?
    let lineStatsError: HarnessGitReadError?
    let changed: Int
    let staged: Int
    let unstaged: Int
    let untracked: Int
    let conflicts: Int

    init(_ json: JSONValue) throws {
        let r = try GitRecord(json, "Git snapshot", keys: ["root", "branch", "head", "upstream", "ahead", "behind", "changed", "staged", "unstaged", "untracked", "conflicts", "additions", "deletions", "lineStatsError"])
        root = try r.text("root", minimum: 1, maximum: 32_768)
        branch = try r.nullableText("branch"); head = try r.nullableText("head"); upstream = try r.nullableText("upstream")
        ahead = try r.nullableCount("ahead"); behind = try r.nullableCount("behind")
        additions = try r.nullableCount("additions"); deletions = try r.nullableCount("deletions")
        lineStatsError = try r.nullableEnum("lineStatsError", HarnessGitReadError.self)
        guard (additions == nil) == (deletions == nil), lineStatsError == nil || additions == nil else {
            throw PluginContractError("Inconsistent Git line statistics")
        }
        changed = try r.count("changed"); staged = try r.count("staged"); unstaged = try r.count("unstaged")
        untracked = try r.count("untracked"); conflicts = try r.count("conflicts")
    }
}

typealias NativeGitReadError = HarnessGitReadError
struct NativeGitSync: Hashable, Sendable {
    let attemptedAt: Double
    let observedAt: Double
    let error: NativeGitReadError?
    init(_ json: JSONValue) throws {
        let r = try GitRecord(json, "Git sync", keys: ["attemptedAt", "observedAt", "error"])
        attemptedAt = try r.number("attemptedAt", nonnegative: true)
        observedAt = try r.number("observedAt", nonnegative: true)
        error = try r.nullableEnum("error", NativeGitReadError.self)
    }
}

struct NativeGitView: Hashable, Sendable {
    let json: JSONValue
    let snapshot: NativeGitSnapshot
    let sync: NativeGitSync
    let available: Bool
    init(json: JSONValue) throws {
        let r = try GitRecord(json, "Git view", keys: ["snapshot", "sync", "available"])
        snapshot = try NativeGitSnapshot(r.require("snapshot")); sync = try NativeGitSync(r.require("sync"))
        available = try r.bool("available"); self.json = json
    }
}

private struct GitRecord {
    let object: [JSONText: JSONValue]
    let path: String
    init(_ json: JSONValue, _ path: String, keys: Set<JSONText>) throws {
        guard case .object(let object) = json, Set(object.keys) == keys else { throw PluginContractError("Malformed \(path) fields") }
        self.object = object; self.path = path
    }
    func require(_ key: JSONText) throws -> JSONValue {
        guard let result = object[key] else { throw PluginContractError("Missing \(path).\(key.string)") }; return result
    }
    func text(_ key: JSONText, minimum: Int = 0, maximum: Int = Int.max) throws -> JSONText {
        guard case .string(let value) = try require(key), (minimum...maximum).contains(value.codeUnits.count) else {
            throw PluginContractError("Invalid \(path).\(key.string) text")
        }; return value
    }
    func nullableText(_ key: JSONText, maximum: Int = 4096) throws -> JSONText? { try require(key) == .null ? nil : text(key, maximum: maximum) }
    func number(_ key: JSONText, nonnegative: Bool = false) throws -> Double {
        guard let value = try require(key).numberValue, value.isFinite, !nonnegative || value >= 0 else {
            throw PluginContractError("Invalid \(path).\(key.string) number")
        }; return value
    }
    func count(_ key: JSONText) throws -> Int {
        let value = try number(key, nonnegative: true)
        guard value <= 9_007_199_254_740_991, let count = Int(exactly: value) else { throw PluginContractError("Invalid \(path).\(key.string) count") }
        return count
    }
    func nullableCount(_ key: JSONText) throws -> Int? { try require(key) == .null ? nil : count(key) }
    func bool(_ key: JSONText) throws -> Bool {
        guard case .bool(let value) = try require(key) else { throw PluginContractError("Invalid \(path).\(key.string) boolean") }; return value
    }
    func array(_ key: JSONText) throws -> [JSONValue] {
        guard case .array(let value) = try require(key) else { throw PluginContractError("Invalid \(path).\(key.string) array") }; return value
    }
    func enumeration<T: RawRepresentable & CaseIterable>(_ key: JSONText, _ type: T.Type) throws -> T where T.RawValue == String {
        let text = try text(key)
        guard let result = T.allCases.first(where: { JSONText($0.rawValue) == text }) else { throw PluginContractError("Unknown \(path).\(key.string)") }; return result
    }
    func nullableEnum<T: RawRepresentable & CaseIterable>(_ key: JSONText, _ type: T.Type) throws -> T? where T.RawValue == String {
        try require(key) == .null ? nil : enumeration(key, type)
    }
}

struct NativeGitRepository: Identifiable, Hashable, Sendable {
    let id: JSONText
    let root: JSONText
    let branch: JSONText?
    let available: Bool
    let directories: [JSONText]
    let view: NativeGitView
    init(_ json: JSONValue) throws {
        let r = try GitRecord(json, "Git repository", keys: ["id", "snapshot", "sync", "available", "directories"])
        id = try r.text("id", minimum: 1, maximum: 256)
        let snapshot = try NativeGitSnapshot(r.require("snapshot"))
        root = snapshot.root; branch = snapshot.branch
        available = try r.bool("available")
        directories = try r.array("directories").map { raw in
            guard case .string(let cwd) = raw else { throw PluginContractError("Invalid Git source directory") }; return cwd
        }
        view = try NativeGitView(json: .object(["snapshot": r.require("snapshot"), "sync": r.require("sync"), "available": r.require("available")]))
    }
}
struct NativeGitRepositoryPage: Sendable {
    let repositories: [NativeGitRepository]
    let nextCursor: JSONText?
    init(_ json: JSONValue) throws {
        guard case .object(let fields) = json, Set(fields.keys).isSubset(of: ["items", "nextCursor"]),
              let items = fields["items"]?.arrayValue else { throw PluginContractError("Malformed Git repository page") }
        repositories = try items.map(NativeGitRepository.init)
        if let cursor = fields["nextCursor"] {
            guard case .string(let value) = cursor, !value.codeUnits.isEmpty else { throw PluginContractError("Invalid Git repository cursor") }
            nextCursor = value
        } else { nextCursor = nil }
    }
}
@MainActor enum NativeGitContracts {
    static var repositories: ApplicationOperation<JSONText?, NativeGitRepositoryPage> {
        .init(id: "git.list", ownerPluginID: "git", kind: .query,
              input: .init(decode: { json in json["cursor"]?.stringValue.map { JSONText($0) } },
                           encode: { cursor in
                               var fields: [JSONText: JSONValue] = ["limit": .number(1000)]
                               fields["cursor"] = cursor.map(JSONValue.string)
                               return .object(fields)
                           }),
              output: .init(decode: NativeGitRepositoryPage.init, encode: { _ in throw PluginContractError("Git repository pages are read-only") }))
    }
}
