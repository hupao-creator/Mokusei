import Foundation
import Observation
import MokuseiCore
import MokuseiPluginAPI

struct NativeCatalogChanges: Sendable {
    var reset = false
    var threadIDs = Set<JSONText>()
    var applicationIDs = Set<JSONText>()
    var fields = Set<String>()
    var threadStructureIDs = Set<JSONText>()
    var applicationStructureIDs = Set<JSONText>()
    var threadOrderChanged = false
    var applicationOrderChanged = false
}

/// Only the public catalog lives here. Full histories belong to independently
/// observed content handles, and Harnesses retain their private interpretation.
@MainActor @Observable
public final class NativeWorkspaceCatalog {
    private var threadRecords = RuntimeRecordCollection<HarnessThread>()
    private var applicationRecords = RuntimeRecordCollection<JSONValue>()
    @ObservationIgnored private var byID = RuntimeRecordCollection<HarnessThread>()
    public var threads: [HarnessThread] { threadRecords.filter { $0.moku != true } }
    public var applicationThreads: [JSONValue] { Array(applicationRecords) }
    public private(set) var moku: HarnessThread?
    public private(set) var hasMoku = false
    public private(set) var settings: JSONValue = .object([:])
    public private(set) var settingsRevision = 0
    public private(set) var searchRevision = 0
    public private(set) var defaultCwd = ""
    public private(set) var plugins: [JSONValue] = []
    public private(set) var tagRedirects: JSONValue = .object([:])
    public private(set) var executions: [JSONValue] = []
    public private(set) var agentRuns: [JSONValue] = []
    public private(set) var revision = -1
    @ObservationIgnored private(set) var installGeneration: UInt64 = 0
    @ObservationIgnored private(set) var applicationAdmissionCount = 0
    @ObservationIgnored private(set) var changes = NativeCatalogChanges(reset: true)
    @ObservationIgnored private var applicationEntries: [ApplicationThreadRef: (JSONValue, Result<ApplicationThreadCatalogEntry<JSONValue>, Error>)] = [:]
    @ObservationIgnored private var observers: [UUID: (NativeCatalogChanges) -> Void] = [:]

    public init() {}

    public func thread(_ id: JSONText) -> HarnessThread? { byID[id] }
    func applicationJSON(_ id: JSONText) -> JSONValue? { applicationRecords[id] }
    var applicationIDs: [JSONText] { applicationRecords.ids }
    func threadPosition(_ id: JSONText) -> Int? { byID.position(of: id) }
    func applicationPosition(_ id: JSONText) -> Int? { applicationRecords.position(of: id) }

    func applicationEntry(_ ref: ApplicationThreadRef) throws -> ApplicationThreadCatalogEntry<JSONValue> {
        guard let raw = applicationRecords[ref.threadID], raw["ref"]?["typeId"] == .string(ref.typeID) else {
            throw PluginContractError("This application thread is no longer available")
        }
        return try applicationEntry(json: raw)
    }

    func applicationEntry(json raw: JSONValue) throws -> ApplicationThreadCatalogEntry<JSONValue> {
        guard case .string(let id)? = raw["ref"]?["threadId"], case .string(let type)? = raw["ref"]?["typeId"] else {
            return try ApplicationThreadCatalogEntry<JSONValue>(json: raw)
        }
        let ref = ApplicationThreadRef(threadID: id, typeID: type)
        if let cached = applicationEntries[ref], cached.0 == raw { return try cached.1.get() }
        applicationAdmissionCount += 1
        let result = Result { try ApplicationThreadCatalogEntry<JSONValue>(json: raw) }
        applicationEntries[ref] = (raw, result)
        return try result.get()
    }

    func invalidateApplicationEntries() { applicationEntries.removeAll() }

    func observeChanges(_ callback: @escaping (NativeCatalogChanges) -> Void) -> () -> Void {
        let id = UUID(); observers[id] = callback
        return { [weak self] in self?.observers[id] = nil }
    }

    public func install(_ snapshot: JSONValue) throws {
        install(try NativePreparedCatalog(snapshot: snapshot, previous: threadRecords))
    }

    func install(_ prepared: NativePreparedCatalog) {
        let snapshot = prepared.snapshot, change = prepared.changes
        // Admission completes off-actor before any observable fact is published.
        if change.reset {
            applicationEntries = applicationEntries.filter {
                prepared.applications[$0.key.threadID] == $0.value.0
            }
        } else {
            for id in change.applicationIDs {
                if case .string(let type)? = applicationRecords[id]?["ref"]?["typeId"] {
                    applicationEntries.removeValue(forKey: .init(threadID: id, typeID: type))
                }
            }
        }
        byID = prepared.records
        if !threadRecords.sharesStorage(with: prepared.records) { threadRecords = prepared.records }
        if !applicationRecords.sharesStorage(with: prepared.applications) { applicationRecords = prepared.applications }
        installGeneration &+= 1
        changes = change
        if change.reset || moku.map({ change.threadIDs.contains($0.id) }) == true || prepared.moku.map({ change.threadIDs.contains($0.id) }) == true {
            if moku != prepared.moku { moku = prepared.moku }
        }
        if hasMoku != (prepared.moku != nil) { hasMoku = prepared.moku != nil }
        if change.reset || change.fields.contains("settings") { settings = snapshot["settings"]! }
        if change.reset || change.fields.contains("settingsRevision") { settingsRevision = snapshot["settingsRevision"]!.intValue! }
        if change.reset || change.fields.contains("searchRevision") { searchRevision = snapshot["searchRevision"]?.intValue ?? 0 }
        if change.reset || change.fields.contains("defaultCwd") { defaultCwd = snapshot["defaultCwd"]!.stringValue! }
        if change.reset || change.fields.contains("plugins") { plugins = snapshot["plugins"]?.arrayValue ?? [] }
        if change.reset || change.fields.contains("tagRedirects") { tagRedirects = snapshot["tagRedirects"] ?? .object([:]) }
        if change.reset || change.fields.contains("executions") { executions = snapshot["executions"]!.arrayValue! }
        if change.reset || change.fields.contains("agentRuns") { agentRuns = snapshot["agentRuns"]?.arrayValue ?? [] }
        revision = snapshot["revision"]!.intValue!
        for callback in Array(observers.values) { callback(change) }
    }
}

/// Immutable admitted records cross actors without copying the unmodified catalog.
struct NativePreparedCatalog: Sendable {
    let snapshot: JSONValue
    let records: RuntimeRecordCollection<HarnessThread>
    let applications: RuntimeRecordCollection<JSONValue>
    let moku: HarnessThread?
    let changes: NativeCatalogChanges

    init(snapshot: JSONValue, previous: RuntimeRecordCollection<HarnessThread>) throws {
        let snapshot = try RuntimeState.admittingSnapshot(snapshot)
        var next = RuntimeRecordCollection<HarnessThread>()
        var nextMoku: HarnessThread?
        for value in snapshot["threads"]!.catalogValue! {
            guard case let .string(id) = value["id"] else { throw PluginContractError("Runtime thread has no identity") }
            let thread: HarnessThread
            if let existing = previous[id], existing.json == value { thread = existing }
            else { thread = try HarnessThread(json: value) }
            next.updateValue(thread, forKey: id)
            if thread.moku == true {
                guard nextMoku == nil else { throw PluginContractError("Runtime contains more than one Moku thread") }
                nextMoku = thread
            }
        }
        let applications = snapshot["applicationThreads"]!.catalogValue!
        for raw in applications { try Self.validateApplicationIdentity(raw) }
        self.snapshot = snapshot; records = next; self.applications = applications; moku = nextMoku
        changes = .init(reset: true)
    }

    init(snapshot: JSONValue, mutation: JSONValue, previous: Self) throws {
        var change = NativeCatalogChanges()
        change.fields = Set(["settings", "settingsRevision", "searchRevision", "defaultCwd", "plugins", "tagRedirects", "executions", "agentRuns"].filter { mutation[$0] != nil })
        let source = snapshot["threads"]!.catalogValue!
        let applications = snapshot["applicationThreads"]!.catalogValue!
        var next = previous.records
        let removedThreads = mutation["threads"]?["removedIds"]?.arrayValue ?? []
        let upsertThreads = mutation["threads"]?["upserts"]?.arrayValue ?? []
        let upsertThreadIDs = Set(upsertThreads.compactMap { raw -> JSONText? in
            guard case .string(let id) = raw["id"] else { return nil }; return id
        })
        for raw in removedThreads {
            guard case .string(let id) = raw else { throw PluginContractError("Invalid removed thread identity") }
            if next[id] != nil { change.threadIDs.insert(id); change.threadStructureIDs.insert(id) }
            if !upsertThreadIDs.contains(id) { next.removeValue(forKey: id) }
        }
        for raw in upsertThreads {
            guard case .string(let id) = raw["id"], let value = source[id] else { throw PluginContractError("Invalid admitted thread identity") }
            if next[id]?.json == value { continue }
            if next[id] == nil { change.threadStructureIDs.insert(id) }
            next.updateValue(try HarnessThread(json: value), forKey: id)
            change.threadIDs.insert(id)
        }
        if mutation["threads"]?["order"] != nil {
            let order = source.ids
            let removed = Set(removedThreads.compactMap { raw -> JSONText? in
                guard case .string(let id) = raw else { return nil }; return id
            })
            var position = -1
            for id in order where !removed.contains(id) {
                if let previousPosition = previous.records.position(of: id) {
                    if previousPosition < position { change.threadOrderChanged = true }
                    position = previousPosition
                }
            }
            try next.reorder(order)
        }
        var nextMoku = previous.moku.flatMap { next[$0.id] }.flatMap { $0.moku == true ? $0 : nil }
        for id in change.threadIDs {
            guard let thread = next[id], thread.moku == true else { continue }
            guard nextMoku == nil || nextMoku?.id == id else { throw PluginContractError("Runtime contains more than one Moku thread") }
            nextMoku = thread
        }
        for raw in mutation["applicationThreads"]?["removedIds"]?.arrayValue ?? [] {
            guard case .string(let id) = raw else { throw PluginContractError("Invalid removed application identity") }
            if previous.applications[id] != nil { change.applicationIDs.insert(id); change.applicationStructureIDs.insert(id) }
        }
        for raw in mutation["applicationThreads"]?["upserts"]?.arrayValue ?? [] {
            guard case .string(let id) = raw["id"], let value = applications[id] else { throw PluginContractError("Invalid admitted application identity") }
            if previous.applications[id] == value { continue }
            try Self.validateApplicationIdentity(value)
            change.applicationIDs.insert(id)
            if previous.applications[id] == nil { change.applicationStructureIDs.insert(id) }
        }
        if mutation["applicationThreads"]?["order"] != nil {
            let removed = Set((mutation["applicationThreads"]?["removedIds"]?.arrayValue ?? []).compactMap { raw -> JSONText? in
                guard case .string(let id) = raw else { return nil }; return id
            })
            var position = -1
            for id in applications.ids where !removed.contains(id) {
                if let previousPosition = previous.applications.position(of: id) {
                    if previousPosition < position { change.applicationOrderChanged = true }
                    position = previousPosition
                }
            }
        }
        self.snapshot = snapshot; records = next; self.applications = applications; moku = nextMoku; changes = change
    }

    private static func validateApplicationIdentity(_ raw: JSONValue) throws {
        guard case .string(let id) = raw["id"], raw["ref"]?["threadId"] == .string(id),
              raw["ref"]?["typeId"]?.stringValue != nil else { throw PluginContractError("Invalid application thread identity") }
    }
}

actor NativeCatalogPreparation {
    private var previous: NativePreparedCatalog?
    private var authority: UUID?
    func prepare(_ snapshot: JSONValue, event: RuntimeClientEvent) throws -> NativePreparedCatalog {
        let next: NativePreparedCatalog
        if case .mutation(let mutation, _, let authority) = event,
           self.authority == authority, let previous,
           mutation["type"]?.stringValue == "state-patched", mutation["baseRevision"] == previous.snapshot["revision"],
           snapshot["threads"]?.catalogValue != nil, snapshot["applicationThreads"]?.catalogValue != nil {
            next = try NativePreparedCatalog(snapshot: snapshot, mutation: mutation, previous: previous)
        } else { next = try NativePreparedCatalog(snapshot: snapshot, previous: previous?.records ?? .init()) }
        switch event {
        case .snapshot(_, let authority), .mutation(_, _, let authority): self.authority = authority
        default: break
        }
        previous = next
        return next
    }
}

/// Concrete plugin imports are restricted to the executable composition root.
@MainActor
public struct NativePluginComposition {
    public let harnesses: HarnessPluginRegistry
    public let sidecards: SidecardPluginRegistry
    public let applications: ApplicationPluginRegistry

    public init(harnesses: [AnyHarnessPlugin], sidecards: [AnySidecardPlugin], applications: [ApplicationPluginModule]) throws {
        self.harnesses = try HarnessPluginRegistry(harnesses)
        self.sidecards = try SidecardPluginRegistry(sidecards)
        self.applications = try ApplicationPluginRegistry(applications)
    }
}
