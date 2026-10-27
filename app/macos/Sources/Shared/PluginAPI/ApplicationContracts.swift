import Foundation
import MokuseiCore

public struct ApplicationThreadRef: Hashable, Sendable {
    public let threadID: JSONText
    public let typeID: JSONText
    public init(threadID: JSONText, typeID: JSONText) { self.threadID = threadID; self.typeID = typeID }
    public var json: JSONValue { .object(["threadId": .string(threadID), "typeId": .string(typeID)]) }
}
public struct ApplicationExecutionRef: Hashable, Sendable {
    public let thread: ApplicationThreadRef
    public let executionID: JSONText
    public init(thread: ApplicationThreadRef, executionID: JSONText) { self.thread = thread; self.executionID = executionID }
}
public struct ApplicationTagProjection: Hashable, Sendable {
    public let tags: [JSONText]
    public let semanticTags: [JSONText]
    public let tagEmojis: [JSONText: JSONText]
    public let directoryTags: [JSONText]
    public init(tags: [JSONText], semanticTags: [JSONText], directoryTags: [JSONText], tagEmojis: [JSONText: JSONText]) {
        self.tagEmojis = tagEmojis
        self.tags = tags; self.semanticTags = semanticTags; self.directoryTags = directoryTags
    }
}
public struct ApplicationThreadPresentation: Hashable, Sendable {
    public let id: JSONText
    public let apiVersion: Int
    public let schemaVersion: Int
    public let value: JSONValue
    public init(id: JSONText, apiVersion: Int, schemaVersion: Int, value: JSONValue) {
        self.id = id; self.apiVersion = apiVersion; self.schemaVersion = schemaVersion; self.value = value
    }
}

public struct ApplicationThreadCatalogEntry<Value> {
    public let scope: JSONText?
    public let ref: ApplicationThreadRef
    public let revision: Int
    public let createdAt: Double
    public let updatedAt: Double
    public let title: JSONText
    public let archived: Bool
    public let tags: ApplicationTagProjection
    public let presentations: [ApplicationThreadPresentation]
    public let view: Value
    public init(ref: ApplicationThreadRef, revision: Int, createdAt: Double, updatedAt: Double,
                title: JSONText, archived: Bool, tags: ApplicationTagProjection,
                presentations: [ApplicationThreadPresentation], view: Value, scope: JSONText? = nil) {
        self.ref = ref; self.revision = revision; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.scope = scope
        self.title = title; self.archived = archived; self.tags = tags; self.presentations = presentations; self.view = view
    }
    public func mapView<Next>(_ transform: (Value) throws -> Next) rethrows -> ApplicationThreadCatalogEntry<Next> {
        try .init(ref: ref, revision: revision, createdAt: createdAt, updatedAt: updatedAt,
                  title: title, archived: archived, tags: tags, presentations: presentations, view: transform(view), scope: scope)
    }
}

extension ApplicationThreadCatalogEntry: Sendable where Value: Sendable {}
extension ApplicationThreadCatalogEntry: Equatable where Value: Equatable {}
extension ApplicationThreadCatalogEntry: Hashable where Value: Hashable {}

extension ApplicationThreadCatalogEntry where Value == JSONValue {
    public init(json: JSONValue) throws {
        try PluginJSONValidation.validate(json)
        let record = try ApplicationRecordReader(json, path: "application thread")
        let reference = try ApplicationRecordReader(record.require("ref"), path: "application thread.ref")
        let tags = try ApplicationRecordReader(record.require("tags"), path: "application thread.tags")
        let presentations = try record.array("presentations").map { item in
            let value = try ApplicationRecordReader(item, path: "application thread.presentation")
            return try ApplicationThreadPresentation(id: value.text("id"), apiVersion: value.integer("apiVersion"),
                schemaVersion: value.integer("schemaVersion"), value: value.require("value"))
        }
        guard Set(presentations.map(\.id)).count == presentations.count else { throw PluginContractError("Duplicate application thread presentations") }
        let created = try record.number("createdAt"), updated = try record.number("updatedAt")
        guard created >= 0, updated >= created else { throw PluginContractError("Invalid application thread timestamps") }
        self.init(ref: try ApplicationThreadRef(threadID: reference.text("threadId"), typeID: reference.text("typeId")),
                  revision: try record.integer("revision"), createdAt: created, updatedAt: updated,
                  title: try record.text("title"), archived: try record.bool("archived"),
                  tags: try ApplicationTagProjection(tags: tags.texts("tags"), semanticTags: tags.texts("semanticTags"), directoryTags: tags.texts("directoryTags"), tagEmojis: SemanticTagLabel.decodeEmojis(tags.require("tagEmojis"), names: tags.texts("semanticTags"))),
                  presentations: presentations, view: try record.require("view"),
                  scope: record.fields["scope"] == nil ? nil : try record.text("scope"))
    }
}

public struct ApplicationPluginManifest: Hashable, Sendable {
    public struct Contributions: Hashable, Sendable {
        public let backgroundAgents: [JSONText]
        public let threadTypes: [JSONText]
        public let settings: [JSONText]
        public let collections: [JSONText]
        public let queries: [JSONText]
        public let commands: [JSONText]
        public init(backgroundAgents: [JSONText] = [], threadTypes: [JSONText] = [],
                    settings: [JSONText] = [], collections: [JSONText] = [],
                    queries: [JSONText] = [], commands: [JSONText] = []) {
            self.backgroundAgents = backgroundAgents; self.threadTypes = threadTypes
            self.settings = settings; self.collections = collections; self.queries = queries; self.commands = commands
        }
        var all: [JSONText] { backgroundAgents + threadTypes + settings + collections + queries + commands }
    }
    public let id: JSONText
    public let displayName: JSONText
    public let apiVersion: Int
    public let contributes: Contributions
    public init(id: JSONText, displayName: JSONText, apiVersion: Int = 1, contributes: Contributions) throws {
        let lower: (UInt16) -> Bool = { (97...122).contains($0) }
        guard let first = id.codeUnits.first, lower(first), id.codeUnits.allSatisfy({ lower($0) || (48...57).contains($0) || $0 == 45 }),
              !displayName.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, apiVersion == 1 else {
            throw PluginContractError("Invalid application plugin manifest")
        }
        let prefix = id.codeUnits + [46]
        guard Set(contributes.all).count == contributes.all.count,
              contributes.all.allSatisfy({ name in
                  name.codeUnits.starts(with: prefix) && name.codeUnits.allSatisfy { lower($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }
              }) else { throw PluginContractError("Application contribution identities must be unique and owned by their plugin") }
        self.id = id; self.displayName = displayName; self.apiVersion = apiVersion; self.contributes = contributes
    }
}

@MainActor
public struct ApplicationValueKey<Value> {
    public let id: JSONText
    public let ownerPluginID: JSONText
    public let schemaVersion: Int
    public let codec: PluginValueCodec<Value>
    public init(id: JSONText, ownerPluginID: JSONText, schemaVersion: Int = 1, codec: PluginValueCodec<Value>) {
        self.id = id; self.ownerPluginID = ownerPluginID; self.schemaVersion = schemaVersion; self.codec = codec
    }
}
@MainActor
public struct ApplicationPresentationKey<Value> {
    public let key: ApplicationValueKey<Value>
    public let apiVersion: Int
    public init(key: ApplicationValueKey<Value>, apiVersion: Int = 1) { self.key = key; self.apiVersion = apiVersion }
    public func read<Entry>(_ entry: ApplicationThreadCatalogEntry<Entry>) throws -> Value? {
        guard let value = entry.presentations.first(where: { $0.id == key.id }) else { return nil }
        guard value.apiVersion == apiVersion, value.schemaVersion == key.schemaVersion else {
            throw PluginContractError("Incompatible application thread presentation: \(key.id.string)")
        }
        return try key.codec.decode(value.value)
    }
}

public enum ApplicationOperationKind: String, Sendable { case query, command }
@MainActor
public struct ApplicationOperation<Input, Output> {
    public let id: JSONText
    public let ownerPluginID: JSONText
    public let kind: ApplicationOperationKind
    public let input: PluginValueCodec<Input>
    public let output: PluginValueCodec<Output>
    public init(id: JSONText, ownerPluginID: JSONText, kind: ApplicationOperationKind,
                input: PluginValueCodec<Input>, output: PluginValueCodec<Output>) {
        self.id = id; self.ownerPluginID = ownerPluginID; self.kind = kind; self.input = input; self.output = output
    }
}

/// Composition binds this client to one plugin and only its declared operations.
/// Callers can supply receipt identity, never a caller identity or batch authority.
@MainActor
public struct ApplicationDomainClient {
    public let pluginID: JSONText
    private let invoke: (ApplicationOperationKind, JSONText, JSONValue, JSONText?, PluginLifetime) async throws -> JSONValue
    public init(pluginID: JSONText,
                invoke: @escaping (ApplicationOperationKind, JSONText, JSONValue, JSONText?, PluginLifetime) async throws -> JSONValue) {
        self.pluginID = pluginID; self.invoke = invoke
    }
    public func query<I, O>(_ key: ApplicationOperation<I, O>, input: I, lifetime: PluginLifetime) async throws -> O {
        try validate(key, kind: .query); try lifetime.checkCancellation()
        let value = try await invoke(.query, key.id, key.input.encode(input), nil, lifetime)
        try lifetime.checkCancellation()
        return try key.output.decode(value)
    }
    public func execute<I, O>(_ key: ApplicationOperation<I, O>, input: I, requestID: JSONText,
                              lifetime: PluginLifetime) async throws -> O {
        try validate(key, kind: .command); try lifetime.checkCancellation()
        guard !requestID.codeUnits.isEmpty else { throw PluginContractError("Application commands require receipt identity") }
        let value = try await invoke(.command, key.id, key.input.encode(input), requestID, lifetime)
        try lifetime.checkCancellation()
        return try key.output.decode(value)
    }
    private func validate<I, O>(_ key: ApplicationOperation<I, O>, kind: ApplicationOperationKind) throws {
        guard key.ownerPluginID == pluginID, key.kind == kind else { throw PluginContractError("Application operation belongs to a different owner or phase") }
    }
}

public struct ApplicationHTMLDocument: Hashable, Sendable {
    public let html: JSONText
    public let contentRevision: JSONText
    public init(html: JSONText, contentRevision: JSONText) { self.html = html; self.contentRevision = contentRevision }
}
public struct ApplicationHTMLSource: Hashable, Sendable {
    public let pluginID: JSONText
    public let queryID: JSONText
    public let input: JSONValue
    public let contentRevision: JSONText
    public init(pluginID: JSONText, queryID: JSONText, input: JSONValue, contentRevision: JSONText) {
        self.pluginID = pluginID; self.queryID = queryID; self.input = input; self.contentRevision = contentRevision
    }
    @MainActor public init<Input>(query: ApplicationOperation<Input, ApplicationHTMLDocument>, input: Input, contentRevision: JSONText) throws {
        guard query.kind == .query else { throw PluginContractError("An HTML source must use a query") }
        self.init(pluginID: query.ownerPluginID, queryID: query.id, input: try query.input.encode(input), contentRevision: contentRevision)
    }
}

struct ApplicationRecordReader {
    let fields: [JSONText: JSONValue]
    let path: String
    init(_ json: JSONValue, path: String) throws {
        guard case .object(let fields) = json else { throw PluginContractError("\(path) must be an object") }
        self.fields = fields; self.path = path
    }
    func require(_ key: String) throws -> JSONValue {
        guard let value = fields[JSONText(key)] else { throw PluginContractError("Missing \(path).\(key)") }; return value
    }
    func text(_ key: String) throws -> JSONText {
        guard case .string(let value) = try require(key) else { throw PluginContractError("\(path).\(key) must be text") }; return value
    }
    func number(_ key: String) throws -> Double {
        guard let value = try require(key).numberValue, value.isFinite else { throw PluginContractError("\(path).\(key) must be finite") }; return value
    }
    func integer(_ key: String) throws -> Int {
        let value = try number(key)
        guard (0...9_007_199_254_740_991).contains(value), let result = Int(exactly: value) else { throw PluginContractError("\(path).\(key) must be a nonnegative safe integer") }; return result
    }
    func bool(_ key: String) throws -> Bool {
        guard case .bool(let value) = try require(key) else { throw PluginContractError("\(path).\(key) must be boolean") }; return value
    }
    func array(_ key: String) throws -> [JSONValue] {
        guard case .array(let value) = try require(key) else { throw PluginContractError("\(path).\(key) must be an array") }; return value
    }
    func texts(_ key: String) throws -> [JSONText] {
        try array(key).map { guard case .string(let value) = $0 else { throw PluginContractError("\(path).\(key) must contain text") }; return value }
    }
}
