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
    case collection(AnyApplicationThreadPlugin, [ApplicationOverviewSnapshot])
}

/// Owns public catalog selection and the committed presentation session. Call receive
/// synchronously after EACH runtime transaction has been installed in the workspace;
/// observing SwiftUI renders instead would lose A → B → A structural transitions.
@MainActor @Observable
public final class NativeOverviewWorkspaceModel {
    public let workspace: NativeWorkspaceModel
    public let canvasState: NativeOverviewCanvasState
    public let content = NativeOverviewContentStore()
    public let applicationFactories: NativeOverviewApplicationFactories
    public let chromeInteractions = NativeOverviewChromeInteractions()
    public private(set) var tagSelection: NativeOverviewTagSelection?
    public private(set) var selectedTag = ""
    public private(set) var selectedScope = ""
    public private(set) var selectedFilter: NativeOverviewFilter?
    public private(set) var filters: [NativeOverviewFilter] = []
    public private(set) var allHasActiveTasks = false
    public var visibleFilters: [NativeOverviewFilter] {
        filters.filter { $0.count > 0 }.map { filter in
            var visible = filter
            visible.children.removeAll { child in
                // Retain an active semantic selection: promoting it to the
                // directory would silently broaden future catalog updates.
                redundantSemanticFilterKeys.contains(child.selectionKey)
                    && tagSelection.map { child.matches($0.tag, kind: $0.kind, scope: $0.scope) } != true
            }
            return visible
        }
    }
    public private(set) var sceneKey = "\u{0}default"
    public var items: [NativeOverviewItem] { content.items }
    /// Global eligible cards, before tags/search and report coverage. Nil means
    /// no catalog has been projected yet; an unloaded workspace is not empty.
    public private(set) var globalConversationCount: Int?
    public private(set) var hasEstablishedConversation = false
    public private(set) var revisions: [NativeOverviewLayoutRevision] = [] {
        didSet { queuedPresentationIDs = Set(revisions.flatMap { $0.items.map(\.presentationID) }) }
    }
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
    @ObservationIgnored private var contentRequest: Task<Void, Never>?
    @ObservationIgnored private var contentRequestKey: String?
    @ObservationIgnored private var contentContextKey: String?
    @ObservationIgnored private var contentRanks: [String: Int]?
    @ObservationIgnored private var searchCameraBookmark: (sceneKey: String, view: NativeOverviewCameraState)?
    @ObservationIgnored private let searchRequest: ((JSONValue) async throws -> JSONValue)?
    public private(set) var focusFilterRequestKey = 0
    public private(set) var facts = NativeOverviewPresentationFacts()
    public private(set) var presentationActive = true
    @ObservationIgnored private var presentationDirty = false
    @ObservationIgnored private var collectionSources: [ApplicationThreadRef: String] = [:]
    @ObservationIgnored private var collectionSelections: [String: ApplicationThreadRef] = [:]
    @ObservationIgnored private var recentApplicationOpens: [ApplicationThreadRef: Date] = [:]
    @ObservationIgnored private var collectionExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var snapshots: [String: NativeOverviewCardSnapshot] = [:]
    @ObservationIgnored private var harnessCache: [JSONText: HarnessOverviewSnapshot] = [:]
    @ObservationIgnored private var applicationCache: [JSONText: (JSONValue, ApplicationOverviewSnapshot)] = [:]
    @ObservationIgnored private(set) var membershipBuildCount = 0
    @ObservationIgnored private(set) var projectionVisitCount = 0
    @ObservationIgnored private(set) var catalogChangeVisitCount = 0
    @ObservationIgnored private var queuedPresentationIDs = Set<String>()
    @ObservationIgnored private var keywordMemberIDs = Set<String>()
    @ObservationIgnored private var catalogIDs = Set<String>()
    @ObservationIgnored private var catalogGeneration: UInt64?
    @ObservationIgnored private var membershipFacts: NativeOverviewMembershipFacts?
    @ObservationIgnored private(set) var filterContextFacts: [JSONValue] = []
    @ObservationIgnored private var membershipIndex = NativeOverviewMembershipIndex()
    private var filterMembers: [String: NativeOverviewMembership] { membershipIndex.members }
    private var redundantSemanticFilterKeys: Set<String> { membershipIndex.redundant }
    var membershipSelectionCount: Int { membershipIndex.selectionCount }
    var membershipApplicationCandidateVisits: Int { membershipIndex.applicationCandidateVisits }
    @ObservationIgnored private var allMembers = NativeOverviewMembership()
    @ObservationIgnored private var allMembersDirty = false
    @ObservationIgnored private var activeThreadIDs = Set<JSONText>()
    @ObservationIgnored private var globalApplicationIDs = Set<JSONText>()
    @ObservationIgnored private var establishedThreadIDs = Set<JSONText>()
    @ObservationIgnored private var pendingInsertedIDs = Set<String>()
    @ObservationIgnored private var globalThreadIDs = Set<JSONText>()
    @ObservationIgnored private var overviewEntries: [ApplicationThreadRef: (JSONValue, NativeOverviewApplicationEntry)] = [:]
    @ObservationIgnored private var operationProjectionReady = false
    @ObservationIgnored private var operationThreadID: JSONText?
    @ObservationIgnored private var operationTranscript: JSONValue?
    private var catalogThreads: [HarnessThread] { workspace.catalog.threads }
    @ObservationIgnored private var applicationRecords = RuntimeRecordCollection<NativeOverviewApplicationEntry>()
    // Whole reads use the runtime's authoritative order. The typed index only
    // owns decoding, so changed-ID Set iteration cannot reorder tied cards.
    private var catalogApplications: [NativeOverviewApplicationEntry] {
        workspace.catalog.applicationIDs.compactMap { applicationRecords[$0] }
    }
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
            operationThreadID = nil; operationTranscript = nil; operationProjectionReady = false
            recoveryEpoch += 1
            contextID = UUID().uuidString
            committedFacts = nil
            revisions.removeAll()
        }
    }

    /// Also useful after a host factory or plugin registry changes at startup.
    public func refresh() { catalogGeneration = nil; membershipFacts = nil; operationThreadID = nil; operationTranscript = nil; operationProjectionReady = false; reconcile(captureMutation: false) }

    /// Host observations can change card geometry without changing catalog membership.
    public func refreshCardExtensions() { reconcile(captureMutation: true) }

    /// The reading stack owns this gate: its parent still participates in opening
    /// and return motion even though the logical route already points at detail.
    public func setPresentationActive(_ value: Bool) {
        guard active, presentationActive != value else { return }
        presentationActive = value
        revisions.removeAll()
        if value {
            recoveryEpoch += 1
            if presentationDirty { reconcile(captureMutation: false) }
        } else {
            presentationDirty = true
            collectionExpiryTask?.cancel(); collectionExpiryTask = nil
            invalidateContentSearch()
        }
    }

    public func setPresentation(_ value: NativeOverviewPresentationFacts) {
        guard facts != value else { return }
        let becameVisible = !facts.overviewVisible && value.overviewVisible
        if facts.overviewVisible != value.overviewVisible {
            revisions.removeAll()
            // Leaving retains the committed canvas as the reading backdrop.
            // Recover hidden structural changes when Overview becomes active.
            if value.overviewVisible { recoveryEpoch += 1 }
        }
        facts = value
        if !value.overviewVisible { collectionExpiryTask?.cancel(); collectionExpiryTask = nil }
        // Direct navigation/recovery can bypass an animated return.
        if value.overviewVisible {
            setPresentationActive(true)
            if presentationDirty || becameVisible { reconcile(captureMutation: false) }
        }
        if isSearching {
            if searchAvailable { reconcile(captureMutation: false) }
            else { invalidateContentSearch() }
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
        if !isSearching { invalidateContentSearch() }
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
        invalidateContentSearch()
        restoreSearchCamera()
        isSearching = false
        searchQuery = ""
        reconcile(captureMutation: false)
        focusFilterRequestKey += 1
    }
    public func requestFilterFocus() { endSearch(); focusFilterRequestKey += 1 }
    public func searchRank(for id: String) -> Int? { isSearching ? contentRanks?[id] : nil }
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
    public func snapshot(for item: NativeOverviewItem) -> NativeOverviewCardSnapshot? { snapshots[item.presentationID] }

    public func sourceCardID(for reference: ApplicationThreadRef) -> String? { collectionSources[reference] }

    public func selectedCollectionMember(for item: NativeOverviewItem) -> ApplicationThreadRef? {
        guard case .collection(_, let members) = snapshot(for: item) else { return nil }
        if let selected = collectionSelections[item.id], members.contains(where: { $0.entry.ref == selected }) { return selected }
        return members.first?.entry.ref
    }

    public func selectCollectionMember(_ reference: ApplicationThreadRef, cardID: String) {
        guard collectionSources[reference] == cardID else { return }
        collectionSelections[cardID] = reference
    }

    /// Called only after the Host has admitted real detail navigation. Rotating a
    /// cover never creates a reading fact. Keep the opening backdrop until return.
    public func recordApplicationOpen(_ reference: ApplicationThreadRef, at date: Date = .now) {
        guard let plugin = try? workspace.plugins.applications.requireThread(reference.typeID),
              plugin.overviewCollection != nil, applicationsByRef[reference] != nil else { return }
        recentApplicationOpens[reference] = date
        do { try workspace.preferences.recordApplicationOpen(key: openHistoryKey(reference), at: date) }
        catch { workspace.report(error) }
        presentationDirty = true
        if facts.overviewVisible && presentationActive { reconcile(captureMutation: true) }
    }

    private func openHistoryKey(_ reference: ApplicationThreadRef) -> String {
        reference.typeID.string + ":" + reference.threadID.string
    }
    private func lastOpened(_ reference: ApplicationThreadRef) -> Date? {
        recentApplicationOpens[reference] ?? workspace.preferences.applicationLastOpened[openHistoryKey(reference)]
            .map { Date(timeIntervalSince1970: $0) }
    }

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

    private func reconcile(captureMutation: Bool, refreshSelection: Bool = true) {
        do {
            if try applyCatalogChanges(captureMutation: captureMutation) { return }
            let previousCatalogIDs = catalogIDs
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
                refreshMokuOperations()
                applicationRecords = .init()
                for item in nextApplications { applicationRecords.updateValue(item, forKey: item.entry.ref.threadID) }
                catalogIDs = Set(catalogThreads.map { $0.id.string } + nextApplications.map { $0.entry.ref.threadID.string })
                applicationsByRef = Dictionary(uniqueKeysWithValues: nextApplications.map { ($0.entry.ref, $0) })
                catalogApplicationJSON = Dictionary(uniqueKeysWithValues: zip(nextApplications, workspace.catalog.applicationThreads).map { ($0.0.entry.ref.threadID, $0.1) })
                directoryTags.update(threads: catalogThreads)
                let nextActiveThreadIDs = Set(catalogThreads.filter { $0.moku != true && $0.observation.isExecutionActive }.map(\.id))
                let changedActivity = activeThreadIDs != nextActiveThreadIDs
                activeThreadIDs = nextActiveThreadIDs
                let nextFacts = NativeOverviewMembershipFacts(threads: catalogThreads, applications: nextApplications)
                if membershipFacts != nextFacts {
                    rebuildMembership()
                    membershipFacts = nextFacts
                } else if changedActivity {
                    refreshFilterActivity(filters)
                }
                let harnessIDs = Set(catalogThreads.map(\.id)), applicationIDs = Set(nextApplications.map { $0.entry.ref.threadID })
                harnessCache = harnessCache.filter { harnessIDs.contains($0.key) }
                applicationCache = applicationCache.filter { applicationIDs.contains($0.key) }
                catalogGeneration = workspace.catalog.installGeneration
            }
            // Redirects depend on selection too; selecting another tag must not
            // wait for the next catalog transaction.
            if refreshSelection, let selection = tagSelection {
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
            guard presentationActive else {
                presentationDirty = true
                publishContext()
                return
            }
            // Scene identity belongs to the retained presentation too. Advancing
            // it while hidden could bookmark the old camera under a new selection.
            let search = NativeOverviewSearch(isSearching ? searchQuery : "")
            let scope: NativeOverviewCollection
            if search.terms.isEmpty {
                // Empty search keeps the browsing scene, tag membership and camera.
                sceneKey = browseSceneKey
                let selectedTags = selectedFilter.map { [$0.tag] + $0.aliases } ?? (selectedTag.isEmpty ? [] : [selectedTag])
                scope = selectedFilter.flatMap { filterMembers[$0.selectionKey] }.map(resolve)
                    ?? (selectedTags.isEmpty ? resolve(allMembership()) : collection(tags: selectedTags, kind: tagSelection?.kind, scope: selectedScope))
            } else {
                // Search every eligible owner, including directory-only documents
                // and tasks covered by reports. Browsing tags and report coverage
                // must not hide metadata or body matches from the query request.
                sceneKey = "\u{0}global-search:" + search.sceneKey
                scope = NativeOverviewSelection.candidates(threads: catalogThreads, applications: catalogApplications)
            }
            let keyword = search.filter(scope, directoryTags: directoryTags.values)
            scheduleContentSearch(scope: scope, keyword: keyword)
            let keywordIDs = Set(keyword.threads.map { $0.id.string } + keyword.applications.map { $0.entry.ref.threadID.string })
            keywordMemberIDs = keywordIDs
            let selected = NativeOverviewCollection(
                threads: scope.threads.filter { keywordIDs.contains($0.id.string) || contentRanks?[$0.id.string] != nil },
                applications: scope.applications.filter { keywordIDs.contains($0.entry.ref.threadID.string) || contentRanks?[$0.entry.ref.threadID.string] != nil })
            let nextItems = try project(selected)
            if sceneKey != previousScene { revisions.removeAll() }
            if captureMutation, facts.overviewVisible, previousScene == sceneKey,
               previousItems.map(\.structuralIdentity) != nextItems.map(\.structuralIdentity) {
                revision += 1
                let inserted = catalogIDs.subtracting(previousCatalogIDs).union(pendingInsertedIDs)
                revisions.append(.init(revision: revision, sceneKey: sceneKey, items: nextItems, instantEntryIDs: inserted))
            }
            content.install(nextItems)
            presentationDirty = false
            error = nil
            pendingInsertedIDs.removeAll()
            pruneSnapshots()
            publishContext()
        } catch { self.error = error.localizedDescription; workspace.report(error) }
    }

    /// A catalog mutation carries its accepted identities all the way to card
    /// slots. Unchanged membership/order leaves every other card and filter alone.
    private func applyCatalogChanges(captureMutation: Bool) throws -> Bool {
        let change = workspace.catalog.changes
        guard error == nil, let generation = catalogGeneration, generation &+ 1 == workspace.catalog.installGeneration,
              !change.reset, let membershipFacts, membershipFacts.localeIsCurrent,
              !change.threadOrderChanged, !change.applicationOrderChanged,
              change.fields.isDisjoint(with: ["tagRedirects", "plugins", "settings", "searchRevision"]) else { return false }
        var changedThreads: [HarnessThread] = []
        var changedApplications: [(id: JSONText, raw: JSONValue?, old: NativeOverviewApplicationEntry?, next: NativeOverviewApplicationEntry?)] = []
        var membershipThreads = Set<JSONText>(), membershipApplications = Set<JSONText>()
        var changedActivity = false
        for id in change.threadIDs {
            catalogChangeVisitCount += 1
            let thread = workspace.catalog.thread(id)
            let ordinary = thread.flatMap { $0.moku == true ? nil : $0 }
            if !membershipFacts.matches(thread, id: id)
                || (change.threadStructureIDs.contains(id) && (ordinary != nil || !membershipFacts.matches(nil, id: id))) {
                membershipThreads.insert(id)
            }
            if let ordinary { changedThreads.append(ordinary) }
        }
        for id in change.applicationIDs {
            catalogChangeVisitCount += 1
            let raw = workspace.catalog.applicationJSON(id), previous = applicationRecords[id]
            let next = try raw.map { try NativeOverviewApplicationEntry(entry: workspace.catalog.applicationEntry(json: $0)) }
            let ref = next?.entry.ref ?? previous?.entry.ref
            if change.applicationStructureIDs.contains(id) || previous?.entry.ref != next?.entry.ref
                || ref.map({ !membershipFacts.matches(next, ref: $0) }) == true { membershipApplications.insert(id) }
            changedApplications.append((id, raw, previous, next))
        }
        let changedMembership = !membershipThreads.isEmpty || !membershipApplications.isEmpty
        let search = NativeOverviewSearch(isSearching ? searchQuery : "")
        var changedSearchMatches = false
        if !search.terms.isEmpty {
            let changed = NativeOverviewSelection.candidates(threads: changedThreads, applications: changedApplications.compactMap(\.next))
            let matches = search.filter(changed, directoryTags: directoryTags.values)
            let matchIDs = Set(matches.threads.map { $0.id.string } + matches.applications.map { $0.entry.ref.threadID.string })
            changedSearchMatches = (change.threadIDs.union(change.applicationIDs)).contains { matchIDs.contains($0.string) != keywordMemberIDs.contains($0.string) }
        }
        for id in change.threadIDs {
            let thread = workspace.catalog.thread(id)
            if thread?.moku != true && thread?.observation.isExecutionActive == true {
                changedActivity = activeThreadIDs.insert(id).inserted || changedActivity
            } else {
                changedActivity = activeThreadIDs.remove(id) != nil || changedActivity
            }
            directoryTags.update(thread, id: id)
            if let thread, thread.moku != true {
                if catalogIDs.insert(id.string).inserted { pendingInsertedIDs.insert(id.string) }
            } else { catalogIDs.remove(id.string); harnessCache.removeValue(forKey: id) }
            if membershipThreads.contains(id) {
                membershipFacts.update(thread, id: id)
                let candidates = NativeOverviewSelection.candidates(threads: thread.map { $0.moku == true ? [] : [$0] } ?? [], applications: [])
                if let candidate = candidates.threads.first {
                    globalThreadIDs.insert(id)
                    if candidate.observation.latestExecution != nil { establishedThreadIDs.insert(id) }
                    else { establishedThreadIDs.remove(id) }
                } else { globalThreadIDs.remove(id); establishedThreadIDs.remove(id) }
            }
        }
        for (id, raw, previous, next) in changedApplications {
            if let previous, previous.entry.ref != next?.entry.ref {
                overviewEntries.removeValue(forKey: previous.entry.ref); applicationsByRef.removeValue(forKey: previous.entry.ref)
                applicationCache.removeValue(forKey: id)
            }
            if let raw, let next {
                overviewEntries[next.entry.ref] = (raw, next); applicationsByRef[next.entry.ref] = next
                applicationRecords.updateValue(next, forKey: id); catalogApplicationJSON[id] = raw
                if catalogIDs.insert(id.string).inserted { pendingInsertedIDs.insert(id.string) }
            } else {
                applicationRecords.removeValue(forKey: id); catalogApplicationJSON.removeValue(forKey: id)
                catalogIDs.remove(id.string); applicationCache.removeValue(forKey: id)
            }
            if membershipApplications.contains(id) {
                membershipFacts.update(next, previous: previous?.entry.ref)
                if !NativeOverviewSelection.candidates(threads: [], applications: next.map { [$0] } ?? []).applications.isEmpty { globalApplicationIDs.insert(id) }
                else { globalApplicationIDs.remove(id) }
            }
        }
        var affectedScopes = Set<String>()
        if changedMembership {
            membershipBuildCount += 1; allMembersDirty = true
            affectedScopes = membershipIndex.update(threadIDs: membershipThreads, applicationIDs: membershipApplications,
                catalog: workspace.catalog, directoryTags: directoryTags.values, application: { applicationRecords[$0] })
            publishMembership(); refreshGlobalAvailability()
        } else if changedActivity {
            refreshFilterActivity(filters)
            selectedFilter = matchingFilter(tag: selectedTag, scope: selectedScope, kind: tagSelection?.kind)
        }
        if !operationProjectionReady || operationThreadID != workspace.catalog.moku?.id
            || workspace.catalog.moku.map({ change.threadIDs.contains($0.id) }) == true { refreshMokuOperations() }
        catalogGeneration = workspace.catalog.installGeneration
        guard presentationActive else {
            presentationDirty = true
            if changedMembership { publishContext() }
            return true
        }
        if changedMembership {
            let current = matchingFilter(tag: selectedTag, scope: selectedScope, kind: tagSelection?.kind)
            if isSearching || current == nil || current?.count == 0 || affectedScopes.contains(selectedScope) {
                reconcile(captureMutation: captureMutation, refreshSelection: false)
                return true
            }
            selectedFilter = current
            publishContext()
        }
        if changedSearchMatches {
            reconcile(captureMutation: captureMutation, refreshSelection: false)
            return true
        }
        if changedApplications.contains(where: { change in
            collectionSources.keys.contains(where: { $0.threadID == change.id })
        }) {
            reconcile(captureMutation: captureMutation, refreshSelection: false)
            return true
        }
        let selected = NativeOverviewCollection(
            threads: changedThreads.filter { content.activeIDs.contains($0.id.string) },
            applications: changedApplications.compactMap(\.next).filter { content.activeIDs.contains($0.entry.ref.threadID.string) })
        let next = try project(selected, groupCollections: false)
        let previousTokens = next.compactMap { content.records[$0.id]?.presentationID }
        guard content.update(next) else {
            reconcile(captureMutation: captureMutation, refreshSelection: false)
            return true
        }
        let currentTokens = Set(next.map(\.presentationID))
        for token in previousTokens where !retainedPresentationIDs.contains(token) && !queuedPresentationIDs.contains(token) {
            if !currentTokens.contains(token) { snapshots.removeValue(forKey: token) }
        }
        error = nil
        return true
    }

    private func refreshMokuOperations() {
        operationThreadID = workspace.catalog.moku?.id
        if !operationProjectionReady || operationTranscript != workspace.catalog.moku?.transcript {
            operationProjectionReady = true
            operationTranscript = workspace.catalog.moku?.transcript
            operations = NativeOverviewMokuOperation.project(transcript: operationTranscript)
        }
    }

    private var searchAvailable: Bool {
        presentationActive && isSearching && facts.overviewVisible && !facts.settingsOpen && facts.documentVisible && facts.focused &&
            (workspace.runtimeAvailable || searchRequest != nil) && !NativeOverviewSearch(searchQuery).terms.isEmpty
    }
    private func invalidateContentSearch() {
        contentRequest?.cancel(); contentRequest = nil; contentRequestKey = nil; contentContextKey = nil; contentRanks = nil
        searchMode = "keyword"; searchReason = "disabled"; searchIndexing = false
    }
    private func scheduleContentSearch(scope: NativeOverviewCollection, keyword: NativeOverviewCollection) {
        guard searchAvailable else { invalidateContentSearch(); return }
        let refs = scope.threads.map { ApplicationThreadRef(threadID: $0.id, typeID: "agent") } + scope.applications.map { $0.entry.ref }
        let literal = keyword.threads.map { ApplicationThreadRef(threadID: $0.id, typeID: "agent").json } + keyword.applications.map { $0.entry.ref.json }
        let contextKey = NativeOverviewSelection.jsonString(.array([.text(searchQuery), .text(sceneKey),
            .integer(workspace.catalog.searchRevision)]))
        // Live transcript/status revisions do not change the query. Polling
        // already refreshes indexed content; restarting on each revision would
        // repeatedly discard body matches while a thread is streaming.
        let key = NativeOverviewSelection.jsonString(.array([.text(contextKey), .array(refs.map(\.json)), .array(literal)]))
        guard contentRequestKey != key else { return }
        contentRequest?.cancel(); contentRequestKey = key
        if contentContextKey != contextKey {
            contentRanks = nil
            searchMode = "keyword"; searchReason = "loading"; searchIndexing = false
        }
        contentContextKey = contextKey
        let input = JSONValue.object(["query": .text(searchQuery), "threads": .array(refs.map(\.json)), "keywordMatches": .array(literal)])
        contentRequest = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                while !Task.isCancelled {
                    guard let self, self.searchAvailable, self.contentRequestKey == key else { return }
                    let result: JSONValue
                    if let request = self.searchRequest { result = try await request(input) }
                    else { result = try await self.workspace.client.invoke("search:query", args: [input]) }
                    try Task.checkCancellation()
                    guard self.searchAvailable, self.contentRequestKey == key else { return }
                    let allowed = Set(refs)
                    var ranks: [String: Int] = [:]
                    for (index, hit) in (result["hits"]?.arrayValue ?? []).enumerated() {
                        guard let ref = hit["ref"], case .string(let id) = ref["threadId"], case .string(let type) = ref["typeId"],
                              allowed.contains(ApplicationThreadRef(threadID: id, typeID: type)) else { continue }
                        ranks[id.string] = index
                    }
                    self.contentRanks = ranks
                    self.searchMode = "keyword"
                    self.searchReason = result["reason"]?.stringValue ?? ""
                    self.searchIndexing = result["indexing"]?.boolValue == true
                    self.reconcile(captureMutation: false)
                    // Preparation and retries can finish without a catalog
                    // change. Keep the active query fresh even when its first
                    // response only had metadata matches; body indexing runs independently.
                    try await Task.sleep(for: .seconds(3))
                }
            } catch is CancellationError { }
            catch {
                guard let self, !Task.isCancelled, self.contentRequestKey == key else { return }
                if self.contentRanks == nil { self.searchMode = "keyword" }
                self.searchReason = "local-unavailable"; self.searchIndexing = false
                self.reconcile(captureMutation: false)
            }
        }
    }

    private func collection(tags: [String], kind: NativeOverviewTagKind?, scope: String? = nil) -> NativeOverviewCollection {
        NativeOverviewSelection.select(threads: catalogThreads.filter { !$0.attentionHidden }, applications: catalogApplications,
            tags: tags, kind: kind, scope: scope, directoryTags: directoryTags.values)
    }

    private func resolve(_ membership: NativeOverviewMembership) -> NativeOverviewCollection {
        .init(threads: membership.threads.map { workspace.catalog.thread($0)! },
              applications: membership.applications.map { applicationsByRef[$0]! })
    }

    private func allMembership() -> NativeOverviewMembership {
        if allMembersDirty {
            allMembers = NativeOverviewMembership(collection(tags: [], kind: nil))
            allMembersDirty = false
        }
        return allMembers
    }

    private func rebuildMembership() {
        membershipBuildCount += 1
        let threads = catalogThreads, applications = catalogApplications
        allMembersDirty = true
        let candidates = NativeOverviewSelection.candidates(threads: threads, applications: applications)
        globalThreadIDs = Set(candidates.threads.map(\.id))
        globalApplicationIDs = Set(candidates.applications.map { $0.entry.ref.threadID })
        establishedThreadIDs = Set(candidates.threads.filter { $0.observation.latestExecution != nil }.map(\.id))
        refreshGlobalAvailability()
        membershipIndex.reset(threads: threads, applications: applications, catalog: workspace.catalog,
            directoryTags: directoryTags.values, application: { applicationRecords[$0] })
        publishMembership()
    }

    private func refreshGlobalAvailability() {
        globalConversationCount = workspace.catalog.revision >= 0 ? globalThreadIDs.count + globalApplicationIDs.count : nil
        hasEstablishedConversation = !globalApplicationIDs.isEmpty || !establishedThreadIDs.isEmpty
    }

    private func publishMembership() {
        refreshFilterActivity(membershipIndex.filters)
        filterContextFacts = membershipIndex.contextFacts(filters: filters)
    }

    private func refreshFilterActivity(_ source: [NativeOverviewFilter]) {
        // Reuse the exact browsing memberships, including report coverage and
        // hidden/archived exclusions. Activity never changes membership/context.
        func hasActiveTasks(_ membership: NativeOverviewMembership) -> Bool {
            membership.threads.contains { activeThreadIDs.contains($0) }
        }
        let next = source.map { filter in
            var next = filter
            next.hasActiveTasks = hasActiveTasks(filterMembers[filter.selectionKey]!)
            next.children = filter.children.map { child in
                var next = child
                next.hasActiveTasks = hasActiveTasks(filterMembers[child.selectionKey]!)
                return next
            }
            return next
        }
        if filters != next { filters = next }
        // All uses its existing lazy membership too; an active task covered by
        // a Report must not keep an otherwise settled All collection marked.
        allHasActiveTasks = !activeThreadIDs.isEmpty && hasActiveTasks(allMembership())
    }

    func containsGlobalThread(_ id: JSONText) -> Bool { globalThreadIDs.contains(id) }

    private func project(_ collection: NativeOverviewCollection, groupCollections: Bool = true) throws -> [NativeOverviewItem] {
        projectionVisitCount += collection.count
        var entries: [(created: Double, index: Int, item: NativeOverviewItem)] = []
        for thread in collection.threads {
            let input = HarnessThreadInput(thread: thread, git: applicationFactories.gitStatus(thread))
            let projection: HarnessOverviewSnapshot
            if let cached = harnessCache[thread.id], cached.input == input { projection = cached }
            else { projection = try workspace.harnessHost.overview(input: input, availableColumns: 3); harnessCache[thread.id] = projection }
            let token = "agent:\(thread.id.string):\(ObjectIdentifier(projection))"
            snapshots[token] = .harness(projection)
            let completed = !thread.pendingInput && thread.observation.backgroundWork == nil && thread.observation.latestExecution?.status == .completed
            entries.append((thread.createdAt, entries.count, .init(id: thread.id.string,
                columns: projection.envelope.footprint.columns, rows: projection.envelope.footprint.rows,
                structureKey: projection.envelope.structureKey.string,
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
        if groupCollections {
            collectionSources.removeAll()
            collectionExpiryTask?.cancel(); collectionExpiryTask = nil
            if NativeOverviewSearch(isSearching ? searchQuery : "").terms.isEmpty {
                let now = Date()
                var candidates: [JSONText: (AnyApplicationThreadPlugin, ApplicationOverviewCollectionPolicy, [ApplicationOverviewSnapshot])] = [:]
                var nextExpiry: Date?
                for application in collection.applications {
                    let entry = application.entry
                    let plugin = try workspace.plugins.applications.requireThread(entry.ref.typeID)
                    guard let policy = plugin.overviewCollection, let opened = lastOpened(entry.ref) else { continue }
                    if policy.includes(lastOpened: opened, now: now) {
                        if candidates[plugin.id] == nil { candidates[plugin.id] = (plugin, policy, []) }
                        candidates[plugin.id]!.2.append(applicationCache[entry.ref.threadID]!.1)
                    } else {
                        let expiry = opened.addingTimeInterval(policy.openedBefore + 0.01)
                        nextExpiry = min(nextExpiry ?? expiry, expiry)
                    }
                }
                for (_, (plugin, policy, members)) in candidates where members.count > 1 {
                    let id = "\u{0}application-collection:\(plugin.id.string):\(browseSceneKey)"
                    let ids = Set(members.map { $0.entry.ref.threadID.string })
                    let origin = entries.filter { ids.contains($0.item.id) }.min {
                        $0.created == $1.created ? $0.index < $1.index : $0.created < $1.created
                    }!
                    let token = id + ":" + members.map { String(describing: ObjectIdentifier($0)) }.joined(separator: ",")
                    snapshots[token] = .collection(plugin, members)
                    for member in members { collectionSources[member.entry.ref] = id }
                    entries.removeAll { ids.contains($0.item.id) }
                    entries.append((origin.created, origin.index, .init(id: id, columns: policy.footprint.columns,
                        rows: policy.footprint.rows, structureKey: "application-collection", presentationID: token)))
                }
                if let expiry = nextExpiry, facts.overviewVisible, presentationActive {
                    collectionExpiryTask = Task { [weak self] in
                        do {
                            try await Task.sleep(for: .seconds(min(86_400, max(0.01, expiry.timeIntervalSinceNow))))
                            try Task.checkCancellation()
                            guard let self, self.active else { return }
                            self.reconcile(captureMutation: true)
                        } catch { }
                    }
                }
            }
        }
        let ordered = entries.sorted { a, b in
            if isSearching, let ranks = contentRanks {
                let left = ranks[a.item.id] ?? Int.max, right = ranks[b.item.id] ?? Int.max
                if left != right { return left < right }
            }
            return a.created == b.created ? a.index < b.index : a.created < b.created
        }.map(\.item)
        return ordered
    }

    private func pruneSnapshots() {
        let used = retainedPresentationIDs.union(content.retainedPresentationIDs)
            .union(items.map(\.presentationID)).union(revisions.flatMap { $0.items.map(\.presentationID) })
        snapshots = snapshots.filter { used.contains($0.key) }
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
        collectionExpiryTask?.cancel(); collectionExpiryTask = nil
        collectionSources.removeAll(); collectionSelections.removeAll(); recentApplicationOpens.removeAll()
        invalidateContentSearch()
        await publication?.value
        try? await workspace.client.updateOverviewContext(nil)
        content.stop()
        snapshots.removeAll(); revisions.removeAll(); harnessCache.removeAll(); applicationCache.removeAll(); directoryTags.removeAll()
        membershipFacts = nil; membershipIndex = .init(); allMembers = .init(); allMembersDirty = false; applicationsByRef.removeAll()
        activeThreadIDs.removeAll(); allHasActiveTasks = false
        globalThreadIDs.removeAll(); globalConversationCount = nil; hasEstablishedConversation = false
        applicationRecords = .init(); catalogIDs.removeAll(); keywordMemberIDs.removeAll()
        globalApplicationIDs.removeAll(); establishedThreadIDs.removeAll(); pendingInsertedIDs.removeAll()
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }
