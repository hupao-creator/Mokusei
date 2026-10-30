import Observation
import MokuseiCore
import MokuseiPluginAPI

/// Only the public catalog lives here. Full histories belong to independently
/// observed content handles, and Harnesses retain their private interpretation.
@MainActor @Observable
public final class NativeWorkspaceCatalog {
    public private(set) var threads: [HarnessThread] = []
    public private(set) var moku: HarnessThread?
    public private(set) var hasMoku = false
    public private(set) var applicationThreads: [JSONValue] = []
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
    @ObservationIgnored private var applicationJSON: [ApplicationThreadRef: JSONValue] = [:]
    @ObservationIgnored private var applicationEntries: [ApplicationThreadRef: (JSONValue, Result<ApplicationThreadCatalogEntry<JSONValue>, Error>)] = [:]
    @ObservationIgnored private var byID: [JSONText: HarnessThread] = [:]

    public init() {}

    public func thread(_ id: JSONText) -> HarnessThread? { byID[id] }

    func applicationEntry(_ ref: ApplicationThreadRef) throws -> ApplicationThreadCatalogEntry<JSONValue> {
        guard let raw = applicationJSON[ref] else { throw PluginContractError("This application thread is no longer available") }
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

    public func install(_ snapshot: JSONValue) throws {
        install(try NativePreparedCatalog(snapshot: snapshot, previous: byID))
    }

    func install(_ prepared: NativePreparedCatalog) {
        let snapshot = prepared.snapshot
        let next = prepared.byID, ordered = prepared.threads, nextMoku = prepared.moku
        // Decode the complete transaction before publishing any observable fact.
        byID = next
        applicationJSON = prepared.applicationJSON
        applicationEntries = applicationEntries.filter { applicationJSON[$0.key] == $0.value.0 }
        installGeneration &+= 1
        if threads != ordered { threads = ordered }
        if moku != nextMoku { moku = nextMoku }
        if hasMoku != (nextMoku != nil) { hasMoku = nextMoku != nil }
        let applications = snapshot["applicationThreads"]!.arrayValue!
        if applicationThreads != applications { applicationThreads = applications }
        if settings != snapshot["settings"]! { settings = snapshot["settings"]! }
        settingsRevision = snapshot["settingsRevision"]!.intValue!
        searchRevision = snapshot["searchRevision"]?.intValue ?? 0
        defaultCwd = snapshot["defaultCwd"]!.stringValue!
        plugins = snapshot["plugins"]?.arrayValue ?? []
        tagRedirects = snapshot["tagRedirects"] ?? .object([:])
        executions = snapshot["executions"]!.arrayValue!
        agentRuns = snapshot["agentRuns"]?.arrayValue ?? []
        revision = snapshot["revision"]!.intValue!
    }
}

/// Only fully admitted immutable transactions can cross back to the UI.
struct NativePreparedCatalog: Sendable {
    let snapshot: JSONValue
    let threads: [HarnessThread]
    let byID: [JSONText: HarnessThread]
    let moku: HarnessThread?
    let applicationJSON: [ApplicationThreadRef: JSONValue]

    init(snapshot: JSONValue, previous: [JSONText: HarnessThread]) throws {
        try RuntimeState.validateSnapshot(snapshot)
        var ordered: [HarnessThread] = []
        var next: [JSONText: HarnessThread] = [:]
        var nextMoku: HarnessThread?
        for value in snapshot["threads"]!.arrayValue! {
            guard case let .string(id) = value["id"] else {
                throw PluginContractError("Runtime thread has no identity")
            }
            let thread: HarnessThread
            if let existing = previous[id], existing.json == value { thread = existing }
            else { thread = try HarnessThread(json: value) }
            guard next[id] == nil else { throw PluginContractError("Runtime thread identity is duplicated") }
            next[id] = thread
            if thread.moku == true {
                guard nextMoku == nil else { throw PluginContractError("Runtime contains more than one Moku thread") }
                nextMoku = thread
            } else { ordered.append(thread) }
        }
        var applications: [ApplicationThreadRef: JSONValue] = [:]
        for value in snapshot["applicationThreads"]!.arrayValue! {
            if case .string(let thread)? = value["ref"]?["threadId"],
               case .string(let type)? = value["ref"]?["typeId"] {
                let ref = ApplicationThreadRef(threadID: thread, typeID: type)
                if applications[ref] == nil { applications[ref] = value }
            }
        }
        applicationJSON = applications
        self.snapshot = snapshot; threads = ordered; byID = next; moku = nextMoku
    }
}

actor NativeCatalogPreparation {
    private var previous: [JSONText: HarnessThread] = [:]
    func prepare(_ snapshot: JSONValue) throws -> NativePreparedCatalog {
        let next = try NativePreparedCatalog(snapshot: snapshot, previous: previous)
        previous = next.byID
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
