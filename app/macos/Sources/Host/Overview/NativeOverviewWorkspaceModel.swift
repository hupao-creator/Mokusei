import Foundation
import Observation
import MokuseiCore
import MokuseiPluginAPI
import SwiftUI

@MainActor
public struct NativeOverviewApplicationFactories {
    public let gitStatus: (HarnessThread) -> HarnessGitStatus?
    public let projectionCapabilities: (AnyApplicationThreadPlugin, ApplicationThreadCatalogEntry<JSONValue>) throws -> ApplicationCapabilityAccess<ApplicationProjectionPhase>
    public let rendererContext: (AnyApplicationThreadPlugin, ApplicationThreadCatalogEntry<JSONValue>, PluginLifetime) throws -> ApplicationRendererContext
    public init(projectionCapabilities: @escaping (AnyApplicationThreadPlugin, ApplicationThreadCatalogEntry<JSONValue>) throws -> ApplicationCapabilityAccess<ApplicationProjectionPhase>,
                rendererContext: @escaping (AnyApplicationThreadPlugin, ApplicationThreadCatalogEntry<JSONValue>, PluginLifetime) throws -> ApplicationRendererContext,
                gitStatus: @escaping (HarnessThread) -> HarnessGitStatus? = { _ in nil }) {
        self.gitStatus = gitStatus
        self.projectionCapabilities = projectionCapabilities; self.rendererContext = rendererContext
    }
}

public struct NativeOverviewPresentationFacts: Equatable, Sendable {
    public var overviewVisible: Bool
    public var mokuOpen: Bool
    public var settingsOpen: Bool
    public var selectedThread: ApplicationThreadRef?
    public var followUpThread: ApplicationThreadRef?
    public var focused: Bool
    public var documentVisible: Bool
    public var available: Bool
    public init(overviewVisible: Bool = true, mokuOpen: Bool = false, settingsOpen: Bool = false,
                selectedThread: ApplicationThreadRef? = nil, followUpThread: ApplicationThreadRef? = nil,
                focused: Bool = true, documentVisible: Bool = true, available: Bool = true) {
        self.overviewVisible = overviewVisible; self.mokuOpen = mokuOpen; self.settingsOpen = settingsOpen
        self.selectedThread = selectedThread; self.followUpThread = followUpThread
        self.focused = focused; self.documentVisible = documentVisible; self.available = available
    }
}

@MainActor
public enum NativeOverviewCardSnapshot {
    case harness(HarnessOverviewSnapshot)
    case application(AnyApplicationThreadPlugin, ApplicationOverviewSnapshot)
}

/// Owns public catalog selection and the committed presentation session. Call receive
/// synchronously after EACH runtime transaction has been installed in the workspace;
/// observing SwiftUI renders instead would lose A → B → A structural transitions.
@MainActor @Observable
public final class NativeOverviewWorkspaceModel {
    public let workspace: NativeWorkspaceModel
    public let canvasState: NativeOverviewCanvasState
    public let applicationFactories: NativeOverviewApplicationFactories
    public let chromeInteractions = NativeOverviewChromeInteractions()
    public private(set) var tagSelection: NativeOverviewTagSelection?
    public private(set) var selectedTag = ""
    public private(set) var selectedScope = ""
    public private(set) var selectedFilter: NativeOverviewFilter?
    public private(set) var filters: [NativeOverviewFilter] = []
    public var visibleFilters: [NativeOverviewFilter] { filters.filter { $0.count > 0 } }
    public private(set) var sceneKey = "\u{0}default"
    public private(set) var items: [NativeOverviewItem] = []
    /// Global eligible cards, before tags/search and report coverage. Nil means
    /// no catalog has been projected yet; an unloaded workspace is not empty.
    public private(set) var globalConversationCount: Int?
    public private(set) var hasEstablishedConversation = false
    public private(set) var revisions: [NativeOverviewLayoutRevision] = []
    public private(set) var recoveryEpoch: UInt64 = 0
    public private(set) var operations: [NativeOverviewMokuOperation] = []
    public var featuredOperation: NativeOverviewMokuOperation? { operations.last(where: { $0.phase == .running }) ?? operations.last }
    public private(set) var error: String?
    public private(set) var isSearching = false
    public private(set) var searchQuery = ""
    public private(set) var searchFocusRequest = 0
    public private(set) var searchMode = "keyword"
    public private(set) var searchReason = "disabled"
    public private(set) var searchIndexing = false
    @ObservationIgnored private var semanticRequest: Task<Void, Never>?
    @ObservationIgnored private var semanticRequestKey: String?
    @ObservationIgnored private var semanticContextKey: String?
    @ObservationIgnored private var semanticRanks: [String: Int]?
    @ObservationIgnored private var searchCameraBookmark: (sceneKey: String, view: NativeOverviewCameraState)?
    @ObservationIgnored private let searchRequest: ((JSONValue) async throws -> JSONValue)?
    public private(set) var focusFilterRequestKey = 0
    public private(set) var facts = NativeOverviewPresentationFacts()
    @ObservationIgnored private var snapshots: [String: NativeOverviewCardSnapshot] = [:]
    @ObservationIgnored private var harnessCache: [JSONText: HarnessOverviewSnapshot] = [:]
    @ObservationIgnored private var applicationCache: [JSONText: (JSONValue, ApplicationOverviewSnapshot)] = [:]
    @ObservationIgnored private(set) var membershipBuildCount = 0
    @ObservationIgnored private var catalogGeneration: UInt64?
    @ObservationIgnored private var membershipFacts: NativeOverviewMembershipFacts?
    @ObservationIgnored private(set) var filterContextFacts: [JSONValue] = []
    @ObservationIgnored private var filterMembers: [String: NativeOverviewMembership] = [:]
    @ObservationIgnored private var allMembers = NativeOverviewMembership()
    @ObservationIgnored private var globalThreadIDs = Set<JSONText>()
    @ObservationIgnored private var overviewEntries: [ApplicationThreadRef: (JSONValue, NativeOverviewApplicationEntry)] = [:]
    @ObservationIgnored private var operationProjectionReady = false
    @ObservationIgnored private var operationTranscript: JSONValue?
    @ObservationIgnored private var catalogThreads: [HarnessThread] = []
    @ObservationIgnored private var catalogApplications: [NativeOverviewApplicationEntry] = []
    @ObservationIgnored private var applicationsByRef: [ApplicationThreadRef: NativeOverviewApplicationEntry] = [:]
    @ObservationIgnored private var catalogApplicationJSON: [JSONText: JSONValue] = [:]
    @ObservationIgnored private var directoryTags = NativeOverviewDirectoryTagCache()
    @ObservationIgnored private var retainedPresentationIDs = Set<String>()
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var snapshotAuthority: UUID?
    @ObservationIgnored private var contextID = UUID().uuidString
    @ObservationIgnored private var contextRevision = 0
    @ObservationIgnored private var committedContext: JSONValue?
    @ObservationIgnored private var committedFacts: JSONValue?
    @ObservationIgnored private var actions: [JSONValue] = []
    @ObservationIgnored private var actionSequence = 0
    @ObservationIgnored private var publication: Task<Void, Never>?
    @ObservationIgnored private var active = true

    public init(workspace: NativeWorkspaceModel, applications: NativeOverviewApplicationFactories,
                canvasState: NativeOverviewCanvasState = .init(),
                searchRequest: ((JSONValue) async throws -> JSONValue)? = nil) {
        self.searchRequest = searchRequest
        self.workspace = workspace; applicationFactories = applications; self.canvasState = canvasState
    }

    public func receive(_ event: RuntimeClientEvent) {
        guard active else { return }
        switch event {
        case .snapshot(_, let authority):
            acceptAuthority(authority)
            // Observer overflow replays the same authority's current catalog.
            // Refresh its content without invalidating an already issued filter
            // request or discarding the structural stages still in flight.
            reconcile(captureMutation: false)
        case .mutation(_, _, let authority):
            acceptAuthority(authority)
            reconcile(captureMutation: true)
        case .connection, .synchronizing: publishContext()
        case .overviewFilter(let request): receiveFilter(request)
        case .failure, .threadContent: break
        }
    }

    private func acceptAuthority(_ authority: UUID) {
        if snapshotAuthority != authority {
            snapshotAuthority = authority
            catalogGeneration = nil; membershipFacts = nil
            overviewEntries.removeAll()
            operationTranscript = nil; operationProjectionReady = false
            recoveryEpoch += 1
            contextID = UUID().uuidString
            committedFacts = nil
            revisions.removeAll()
        }
    }

    /// Also useful after a host factory or plugin registry changes at startup.
    public func refresh() { catalogGeneration = nil; membershipFacts = nil; operationTranscript = nil; operationProjectionReady = false; reconcile(captureMutation: false) }

    /// Host observations can change card geometry without changing catalog membership.
    public func refreshCardExtensions() { reconcile(captureMutation: true) }

    public func setPresentation(_ value: NativeOverviewPresentationFacts) {
        guard facts != value else { return }
        if facts.overviewVisible != value.overviewVisible {
            revisions.removeAll()
            // Leaving retains the committed canvas as the reading backdrop.
            // Recover hidden structural changes when Overview becomes active.
            if value.overviewVisible { recoveryEpoch += 1 }
        }
        facts = value
        if isSearching {
            if searchAvailable { reconcile(captureMutation: false) }
            else { invalidateSemanticSearch() }
        }
        pruneSnapshots()
        publishContext()
    }

    public func selectTag(_ filter: NativeOverviewFilter?) {
        let tag = filter?.tag ?? ""
        appendAction(["kind": .text("filter"), "tag": tag.isEmpty ? .null : .text(tag)])
        selectTagValue(tag, scope: filter?.scope ?? "",
                       kind: filter.map { $0.isDirectory ? .directory : .semantic })
    }

    private var browseSceneKey: String {
        (selectedFilter?.selectionKey.nonEmpty ?? (selectedScope.isEmpty ? selectedTag : "\(selectedScope)\u{0}\(selectedTag)"))
            + "\u{0}default"
    }

    public func beginSearch() {
        if !isSearching { invalidateSemanticSearch() }
        isSearching = true
        searchFocusRequest += 1
        reconcile(captureMutation: false)
    }
    public func updateSearch(_ query: String) {
        guard isSearching, query != searchQuery else { return }
        let wasEmpty = NativeOverviewSearch(searchQuery).terms.isEmpty
        let willBeEmpty = NativeOverviewSearch(query).terms.isEmpty
        if wasEmpty && !willBeEmpty {
            // Capture at first query, after any scrolling in the empty search.
            searchCameraBookmark = canvasState.pendingSearchCameraRestoration
                ?? canvasState.camera.live.map { (sceneKey, $0) }
            canvasState.pendingSearchCameraRestoration = nil
        } else if !wasEmpty && willBeEmpty { restoreSearchCamera() }
        searchQuery = query
        reconcile(captureMutation: false)
    }
    public func endSearch() {
        guard isSearching else { return }
        invalidateSemanticSearch()
        restoreSearchCamera()
        isSearching = false
        searchQuery = ""
        reconcile(captureMutation: false)
        focusFilterRequestKey += 1
    }
    public func requestFilterFocus() { endSearch(); focusFilterRequestKey += 1 }
    public func searchRank(for id: String) -> Int? { isSearching ? semanticRanks?[id] : nil }
    public func consumeFilterFocus() { focusFilterRequestKey = 0 }
    private func restoreSearchCamera() {
        if let bookmark = searchCameraBookmark {
            // Catalog membership may change while searching. Restore into the
            // current tag's browse scene, not its obsolete membership key.
            let browseScene = browseSceneKey
            canvasState.pendingSearchCameraRestoration = (browseScene, bookmark.view)
        }
        searchCameraBookmark = nil
    }
    public func consumeRevisions(through value: UInt64) {
        revisions.removeAll { $0.revision <= value }
        pruneSnapshots()
    }
    public func retainPresentations(_ values: Set<String>) {
        retainedPresentationIDs = values
        pruneSnapshots()
    }
    public func operation(for threadID: String) -> NativeOverviewMokuOperation? { operations.last { $0.threadID == threadID } }
    public func snapshot(for item: NativeOverviewItem) -> NativeOverviewCardSnapshot? { snapshots[item.presentationID] }

    /// Await this before a user submission so its intent has crossed the runtime
    /// boundary. UTF-16 truncation matches JS slice(0, 4000), including surrogates.
    public func recordUserAction(kind: String, thread: ApplicationThreadRef? = nil, text: JSONText? = nil) async {
        var fields: [JSONText: JSONValue] = ["kind": .text(kind)]
        fields["thread"] = thread?.json
        fields["text"] = text.map { .string(JSONText(codeUnits: Array($0.codeUnits.prefix(4000)))) }
        appendAction(fields)
        publishContext()
        await publication?.value
    }

    private func selectTagValue(_ tag: String, scope: String = "", kind: NativeOverviewTagKind? = nil) {
        searchCameraBookmark = nil
        canvasState.pendingSearchCameraRestoration = nil
        let filter = matchingFilter(tag: tag, scope: scope, kind: kind)
        let resolvedKind = kind ?? (filter?.isDirectory == true ? .directory : .semantic)
        tagSelection = tag.isEmpty ? nil : .init(tag: tag, kind: resolvedKind, scope: filter?.scope ?? scope)
        reconcile(captureMutation: false)
    }

    private var allFilters: [NativeOverviewFilter] {
        filters + filters.flatMap(\.children)
    }

    private func matchingFilter(tag: String, scope: String = "", kind: NativeOverviewTagKind? = nil) -> NativeOverviewFilter? {
        guard !tag.isEmpty else { return nil }
        return allFilters.first { $0.matches(tag, kind: kind, scope: scope.isEmpty ? nil : scope) }
    }

    private func reconcile(captureMutation: Bool) {
        do {
            let previousCatalogIDs = Set(catalogThreads.map { $0.id.string } + catalogApplications.map { $0.entry.ref.threadID.string })
            let previousItems = items
            let previousScene = sceneKey
            if catalogGeneration != workspace.catalog.installGeneration {
                let nextApplications = try workspace.catalog.applicationThreads.map { raw in
                    guard case .string(let id)? = raw["ref"]?["threadId"], case .string(let type)? = raw["ref"]?["typeId"] else {
                        throw PluginContractError("Invalid application thread identity")
                    }
                    let ref = ApplicationThreadRef(threadID: id, typeID: type)
                    if let cached = overviewEntries[ref], cached.0 == raw { return cached.1 }
                    let entry = try NativeOverviewApplicationEntry(entry: workspace.catalog.applicationEntry(json: raw))
                    overviewEntries[ref] = (raw, entry)
                    return entry
                }
                let liveRefs = Set(nextApplications.map { $0.entry.ref })
                overviewEntries = overviewEntries.filter { liveRefs.contains($0.key) }
                if !operationProjectionReady || operationTranscript != workspace.catalog.moku?.transcript {
                    operationProjectionReady = true
                    operationTranscript = workspace.catalog.moku?.transcript
                    operations = NativeOverviewMokuOperation.project(transcript: operationTranscript)
                }
                catalogThreads = workspace.catalog.threads
                catalogApplications = nextApplications
                applicationsByRef = Dictionary(uniqueKeysWithValues: nextApplications.map { ($0.entry.ref, $0) })
                catalogApplicationJSON = Dictionary(uniqueKeysWithValues: zip(nextApplications, workspace.catalog.applicationThreads).map { ($0.0.entry.ref.threadID, $0.1) })
                directoryTags.update(threads: catalogThreads)
                let nextFacts = NativeOverviewMembershipFacts(threads: catalogThreads, applications: nextApplications)
                if membershipFacts != nextFacts {
                    rebuildMembership()
                    membershipFacts = nextFacts
                }
                catalogGeneration = workspace.catalog.installGeneration
            }
            let nextApplications = catalogApplications
            // Redirects depend on selection too; selecting another tag must not
            // wait for the next catalog transaction.
            if let selection = tagSelection {
                tagSelection = NativeOverviewSelection.resolve(selection, redirects: workspace.catalog.tagRedirects,
                    directoryTags: catalogThreads.map { directoryTags.values[$0.cwd] ?? "" } +
                        catalogApplications.flatMap { $0.entry.tags.directoryTags.map(\.string) })
            }
            // A hidden selection must not leave the user scoped to an empty tag.
            // Keep canonical counts/context intact; search does not affect visibility.
            if let selection = tagSelection,
               !allFilters.contains(where: { $0.count > 0 && $0.matches(selection.tag, kind: selection.kind, scope: selection.scope) }) {
                tagSelection = nil
                searchCameraBookmark = nil
                canvasState.pendingSearchCameraRestoration = nil
            }
            let chosenTag = tagSelection?.tag ?? ""
            selectedTag = filters.isEmpty ? "" : chosenTag
            selectedScope = tagSelection?.scope ?? ""
            selectedFilter = matchingFilter(tag: selectedTag, scope: selectedScope, kind: tagSelection?.kind)
            let selectedTags = selectedFilter.map { [$0.tag] + $0.aliases } ?? (selectedTag.isEmpty ? [] : [selectedTag])
            sceneKey = browseSceneKey
            let search = NativeOverviewSearch(isSearching ? searchQuery : "")
            // Empty search is the same canvas scene: opening/closing the chrome
            // must not replace cards, refit the camera or replay a tag flight.
            if !search.terms.isEmpty { sceneKey += "\u{0}search:" + search.sceneKey }
            let scope = selectedFilter.flatMap { filterMembers[$0.selectionKey] }.map(resolve)
                ?? (selectedTags.isEmpty ? resolve(allMembers) : collection(tags: selectedTags, kind: tagSelection?.kind, scope: selectedScope))
            let keyword = search.filter(scope, directoryTags: directoryTags.values)
            scheduleSemanticSearch(scope: scope, keyword: keyword)
            let keywordIDs = Set(keyword.threads.map { $0.id.string } + keyword.applications.map { $0.entry.ref.threadID.string })
            let selected = NativeOverviewCollection(
                threads: scope.threads.filter { keywordIDs.contains($0.id.string) || semanticRanks?[$0.id.string] != nil },
                applications: scope.applications.filter { keywordIDs.contains($0.entry.ref.threadID.string) || semanticRanks?[$0.entry.ref.threadID.string] != nil })
            let nextItems = try project(selected)
            if sceneKey != previousScene { revisions.removeAll() }
            if captureMutation, facts.overviewVisible, previousScene == sceneKey,
               previousItems.map(\.structuralIdentity) != nextItems.map(\.structuralIdentity) {
                revision += 1
                let inserted = Set((catalogThreads.map { $0.id.string } + nextApplications.map { $0.entry.ref.threadID.string }).filter { !previousCatalogIDs.contains($0) })
                revisions.append(.init(revision: revision, sceneKey: sceneKey, items: nextItems, instantEntryIDs: inserted))
            }
            items = nextItems
            error = nil
            // Plugin caches retain only the current catalog; queued presentation
            // snapshots are pinned separately by revisions and canvas retention.
            let harnessIDs = Set(catalogThreads.map(\.id)), applicationIDs = Set(nextApplications.map { $0.entry.ref.threadID })
            harnessCache = harnessCache.filter { harnessIDs.contains($0.key) }
            applicationCache = applicationCache.filter { applicationIDs.contains($0.key) }
            pruneSnapshots()
            publishContext()
        } catch { self.error = error.localizedDescription; workspace.report(error) }
    }

    private var searchAvailable: Bool {
        isSearching && facts.overviewVisible && !facts.settingsOpen && facts.documentVisible && facts.focused &&
            (workspace.runtimeAvailable || searchRequest != nil) && !NativeOverviewSearch(searchQuery).terms.isEmpty
    }
    private func invalidateSemanticSearch() {
        semanticRequest?.cancel(); semanticRequest = nil; semanticRequestKey = nil; semanticContextKey = nil; semanticRanks = nil
        searchMode = "keyword"; searchReason = "disabled"; searchIndexing = false
    }
    private func scheduleSemanticSearch(scope: NativeOverviewCollection, keyword: NativeOverviewCollection) {
        guard searchAvailable else { invalidateSemanticSearch(); return }
        let refs = scope.threads.map { ApplicationThreadRef(threadID: $0.id, typeID: "agent") } + scope.applications.map { $0.entry.ref }
        let literal = keyword.threads.map { ApplicationThreadRef(threadID: $0.id, typeID: "agent").json } + keyword.applications.map { $0.entry.ref.json }
        let contextKey = NativeOverviewSelection.jsonString(.array([.text(searchQuery), .text(sceneKey),
            .integer(workspace.catalog.searchRevision)]))
        // Live transcript/status revisions do not change the query. Polling
        // already refreshes indexed content; restarting on each revision would
        // repeatedly discard semantic cards while a thread is streaming.
        let key = NativeOverviewSelection.jsonString(.array([.text(contextKey), .array(refs.map(\.json)), .array(literal)]))
        guard semanticRequestKey != key else { return }
        semanticRequest?.cancel(); semanticRequestKey = key
        if semanticContextKey != contextKey {
            semanticRanks = nil
            searchMode = "keyword"; searchReason = "loading"; searchIndexing = false
        }
        semanticContextKey = contextKey
        let input = JSONValue.object(["query": .text(searchQuery), "threads": .array(refs.map(\.json)), "keywordMatches": .array(literal)])
        semanticRequest = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                while !Task.isCancelled {
                    guard let self, self.searchAvailable, self.semanticRequestKey == key else { return }
                    let result: JSONValue
                    if let request = self.searchRequest { result = try await request(input) }
                    else { result = try await self.workspace.client.invoke("search:query", args: [input]) }
                    try Task.checkCancellation()
                    guard self.searchAvailable, self.semanticRequestKey == key else { return }
                    let allowed = Set(refs)
                    var ranks: [String: Int] = [:]
                    for (index, hit) in (result["hits"]?.arrayValue ?? []).enumerated() {
                        guard let ref = hit["ref"], case .string(let id) = ref["threadId"], case .string(let type) = ref["typeId"],
                              allowed.contains(ApplicationThreadRef(threadID: id, typeID: type)) else { continue }
                        ranks[id.string] = index
                    }
                    self.semanticRanks = ranks
                    self.searchMode = result["mode"]?.stringValue == "hybrid" ? "hybrid" : "keyword"
                    self.searchReason = result["reason"]?.stringValue ?? ""
                    self.searchIndexing = result["indexing"]?.boolValue == true
                    self.reconcile(captureMutation: false)
                    // Preparation and retries can finish without a catalog
                    // change. Keep the active query fresh even when its first
                    // response only had keywords; the runtime caches vectors.
                    try await Task.sleep(for: .seconds(3))
                }
            } catch is CancellationError { }
            catch {
                guard let self, !Task.isCancelled, self.semanticRequestKey == key else { return }
                if self.semanticRanks == nil { self.searchMode = "keyword" }
                self.searchReason = "local-unavailable"; self.searchIndexing = false
                self.reconcile(captureMutation: false)
            }
        }
    }

    private func collection(tags: [String], kind: NativeOverviewTagKind?, scope: String? = nil) -> NativeOverviewCollection {
        NativeOverviewSelection.select(threads: catalogThreads, applications: catalogApplications,
            tags: tags, kind: kind, scope: scope, directoryTags: directoryTags.values)
    }

    private func resolve(_ membership: NativeOverviewMembership) -> NativeOverviewCollection {
        .init(threads: membership.threads.map { workspace.catalog.thread($0)! },
              applications: membership.applications.map { applicationsByRef[$0]! })
    }

    private func rebuildMembership() {
        membershipBuildCount += 1
        filterMembers.removeAll(keepingCapacity: true)
        allMembers = NativeOverviewMembership(collection(tags: [], kind: nil))
        let candidates = NativeOverviewSelection.candidates(threads: catalogThreads, applications: catalogApplications)
        globalConversationCount = workspace.catalog.revision >= 0 ? candidates.count : nil
        globalThreadIDs = Set(candidates.threads.map(\.id))
        hasEstablishedConversation = !candidates.applications.isEmpty
            || candidates.threads.contains { $0.observation.latestExecution != nil }
        // The same few labels recur across many cards and child selections.
        // This synchronous rebuild owns the memo; nothing survives a locale,
        // catalog or authority change, and no raw catalog content is retained.
        var tagKeys: [String: String] = [:]
        func normalized(_ tag: String) -> String {
            if let cached = tagKeys[tag] { return cached }
            let value = NativeOverviewSelection.key(tag)
            tagKeys[tag] = value
            return value
        }
        filters = NativeOverviewSelection.filters(candidates, directoryTags: directoryTags.values, key: normalized)
        // Every exposed filter has one canonical scope. Partition once rather
        // than decoding every thread's scope again for every directory/child.
        // Applications still use the full candidate list: an unscoped document
        // can participate by directory label under the existing selection rules.
        let threadsByScope = Dictionary(grouping: candidates.threads, by: NativeOverviewSelection.scope)
        func members(for filter: NativeOverviewFilter) -> NativeOverviewCollection {
            NativeOverviewSelection.select(threads: threadsByScope[filter.scope] ?? [], applications: candidates.applications,
                tags: [filter.tag] + filter.aliases, kind: filter.isDirectory ? .directory : .semantic,
                scope: filter.scope, directoryTags: directoryTags.values, key: normalized)
        }
        for index in filters.indices {
            var filter = filters[index]
            let selected = members(for: filter)
            filterMembers[filter.selectionKey] = NativeOverviewMembership(selected)
            filter.count = selected.count
            for childIndex in filter.children.indices {
                var child = filter.children[childIndex]
                let selected = members(for: child)
                filterMembers[child.selectionKey] = NativeOverviewMembership(selected)
                child.count = selected.count
                filter.children[childIndex] = child
            }
            filters[index] = filter
        }
        filterContextFacts = allFilters.map { filter in
            let members = filterMembers[filter.selectionKey]!
            let threads = members.threads.map { ApplicationThreadRef(threadID: $0, typeID: "agent").json }
                + members.applications.map(\.json)
            return .object(["tag": .text(filter.tag), "kind": .text(filter.isDirectory ? "directory" : "semantic"),
                "scope": filter.scope.isEmpty ? .null : .text(filter.scope),
                "aliases": .array(filter.aliases.map(JSONValue.text)), "count": .integer(filter.count), "threads": .array(threads)])
        }
    }

    func containsGlobalThread(_ id: JSONText) -> Bool { globalThreadIDs.contains(id) }

    private func project(_ collection: NativeOverviewCollection) throws -> [NativeOverviewItem] {
        var entries: [(created: Double, index: Int, item: NativeOverviewItem)] = []
        for thread in collection.threads {
            let input = HarnessThreadInput(thread: thread, git: applicationFactories.gitStatus(thread))
            let projection: HarnessOverviewSnapshot
            let cacheHit = harnessCache[thread.id]?.input == input
            if cacheHit, let cached = harnessCache[thread.id] { projection = cached }
            else { projection = try workspace.harnessHost.overview(input: input, availableColumns: 3); harnessCache[thread.id] = projection }
            #if OVERVIEW_PERF_DIAGNOSTICS
            OverviewPerformanceDiagnostics.harnessProjection(cacheHit)
            #endif
            let token = "agent:\(thread.id.string):\(ObjectIdentifier(projection))"
            snapshots[token] = .harness(projection)
            let completed = !thread.pendingInput && thread.observation.backgroundWork == nil && thread.observation.latestExecution?.status == .completed
            entries.append((thread.createdAt, entries.count, .init(id: thread.id.string,
                columns: projection.envelope.footprint.columns, rows: projection.envelope.footprint.rows,
                structureKey: projection.envelope.structureKey.string,
                carouselEligible: thread.pendingInput || thread.observation.isExecutionActive || thread.observation.backgroundWork?.status == .running,
                needsAttention: thread.observation.latestExecution?.status == .waitingForUser, presentationID: token,
                completed: completed)))
        }
        for application in collection.applications {
            let entry = application.entry
            let plugin = try workspace.plugins.applications.requireThread(entry.ref.typeID)
            let projection: ApplicationOverviewSnapshot
            let json = catalogApplicationJSON[entry.ref.threadID]!
            if let cached = applicationCache[entry.ref.threadID], cached.0 == json { projection = cached.1 }
            else {
                projection = try plugin.projectCard(entry: entry, availableColumns: 3,
                    capabilities: applicationFactories.projectionCapabilities(plugin, entry))
                applicationCache[entry.ref.threadID] = (json, projection)
            }
            let token = "application:\(entry.ref.typeID.string):\(entry.ref.threadID.string):\(ObjectIdentifier(projection))"
            snapshots[token] = .application(plugin, projection)
            entries.append((entry.createdAt, entries.count, .init(id: entry.ref.threadID.string,
                columns: projection.envelope.footprint.columns, rows: projection.envelope.footprint.rows,
                structureKey: projection.envelope.structureKey.string, presentationID: token)))
        }
        let ordered = entries.sorted { a, b in
            if isSearching, let ranks = semanticRanks {
                let left = ranks[a.item.id] ?? Int.max, right = ranks[b.item.id] ?? Int.max
                if left != right { return left < right }
            }
            return a.created == b.created ? a.index < b.index : a.created < b.created
        }.map(\.item)
        return ordered
    }

    private func pruneSnapshots() {
        #if OVERVIEW_PERF_DIAGNOSTICS
        OverviewPerformanceDiagnostics.pruneSnapshotCall()
        #endif
        let used = retainedPresentationIDs.union(items.map(\.presentationID)).union(revisions.flatMap { $0.items.map(\.presentationID) })
        snapshots = snapshots.filter { used.contains($0.key) }
        #if OVERVIEW_PERF_DIAGNOSTICS
        OverviewPerformanceDiagnostics.modelRetained(snapshots: snapshots.count, harnessCache: harnessCache.count,
                                                     revisions: revisions.count)
        #endif
    }

    private func appendAction(_ fields: [JSONText: JSONValue]) {
        var fields = fields
        fields["at"] = .number(Date().timeIntervalSince1970 * 1000)
        actions.append(.object(fields)); actions = Array(actions.suffix(20)); actionSequence += 1
    }

    @discardableResult
    private func publishContext() -> JSONValue? {
        guard active else { return nil }
        var fields: [JSONText: JSONValue] = [
            "overviewVisible": .bool(facts.overviewVisible), "mokuOpen": .bool(facts.mokuOpen), "settingsOpen": .bool(facts.settingsOpen),
            "selectedThread": facts.selectedThread?.json ?? .null, "followUpThread": facts.followUpThread?.json ?? .null,
            "focused": .bool(facts.focused), "documentVisible": .bool(facts.documentVisible), "view": .text("default"),
            "selectedTag": (selectedFilter?.tag ?? selectedTag).nonEmpty.map(JSONValue.text) ?? .null,
            "selectedScope": (selectedFilter?.scope ?? selectedScope).nonEmpty.map(JSONValue.text) ?? .null,
            "filters": .array(filterContextFacts), "recentActions": .array(actions)]
        let factKey = JSONValue.array([.text(contextID), .object(fields), .integer(actionSequence)])
        guard factKey != committedFacts else { return committedContext }
        committedFacts = factKey
        contextRevision += 1
        fields["contextId"] = .text(contextID); fields["revision"] = .integer(contextRevision)
        let context = JSONValue.object(fields)
        committedContext = context
        let previous = publication, client = workspace.client
        publication = Task { await previous?.value; try? await client.updateOverviewContext(context) }
        return context
    }

    public func receiveFilter(_ request: JSONValue) {
        guard active, let requestID = request["requestId"]?.stringValue else { return }
        publishContext()
        Task { [weak self] in
            guard let self, self.active, let before = self.committedContext else { return }
            var status = self.filterStatus(request, context: before)
            if status == nil || status == "unchanged" {
                let claimed = (try? await self.workspace.client.claimOverviewFilter(requestID)) ?? false
                guard self.active else { return }
                self.publishContext()
                status = claimed && self.committedContext != nil ? self.filterStatus(request, context: self.committedContext!) : "unavailable"
                if status == nil {
                    let scope = request["scope"]?.stringValue ?? ""
                    self.selectTagValue(request["tag"]?.stringValue ?? "", scope: scope)
                    status = self.committedContext?["selectedTag"] == request["tag"] && (scope.isEmpty || self.selectedScope == scope)
                        ? "applied" : "unavailable"
                }
            }
            guard let context = self.committedContext else { return }
            try? await self.workspace.client.acknowledgeOverviewFilter(.object([
                "requestId": .text(requestID), "status": .text(status ?? "unavailable"), "context": context]))
        }
    }

    private func filterStatus(_ request: JSONValue, context: JSONValue) -> String? {
        guard facts.available, workspace.connection == .connected,
              let expiry = request["expiresAt"]?.numberValue, Date().timeIntervalSince1970 * 1000 < expiry else { return "unavailable" }
        guard request["contextId"] == context["contextId"], request["revision"] == context["revision"] else { return "stale" }
        let scope = request["scope"]?.stringValue ?? ""
        if request["tag"] != .null {
            guard allFilters.contains(where: { .text($0.tag) == request["tag"] && (scope.isEmpty || $0.scope == scope) }) else {
                return "unavailable"
            }
        }
        return request["tag"] == context["selectedTag"] && (scope.isEmpty || scope == selectedScope) ? "unchanged" : nil
    }

    public func stop() async {
        active = false
        invalidateSemanticSearch()
        await publication?.value
        try? await workspace.client.updateOverviewContext(nil)
        snapshots.removeAll(); revisions.removeAll(); harnessCache.removeAll(); applicationCache.removeAll(); directoryTags.removeAll()
        membershipFacts = nil; filterMembers.removeAll(); allMembers = .init(); applicationsByRef.removeAll()
        globalThreadIDs.removeAll(); globalConversationCount = nil; hasEstablishedConversation = false
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }
