import Foundation
import MokuseiCore
import MokuseiPluginAPI

/// Keeps filter inputs and results by their actual scope. Unscoped applications
/// have explicit label dependencies; a local change never reselects another
/// scope merely because it shares the same catalog generation.
@MainActor
final class NativeOverviewMembershipIndex {
    private var threadScopes: [JSONText: String] = [:]
    private var applicationScopes: [JSONText: String] = [:]
    private var threads: [String: Set<JSONText>] = [:]
    private var applications: [String: Set<JSONText>] = [:]
    private struct Unscoped {
        let directory: Set<String>
        let semantic: Set<String>
    }
    private var unscoped: [JSONText: Unscoped] = [:]
    private var directoryApplications: [String: Set<JSONText>] = [:]
    private var semanticApplications: [String: Set<JSONText>] = [:]
    private var scopeFilters: [String: [NativeOverviewFilter]] = [:]
    private var renderedFilters: [String: NativeOverviewFilter] = [:]
    private var context: [String: JSONValue] = [:]
    private var scopeDependencies: [String: Set<String>] = [:]
    private var dependentScopes: [String: Set<String>] = [:]
    private(set) var members: [String: NativeOverviewMembership] = [:]
    private(set) var redundant = Set<String>()
    private(set) var selectionCount = 0
    private(set) var applicationCandidateVisits = 0

    var filters: [NativeOverviewFilter] {
        NativeOverviewSelection.orderedFilters(scopeFilters.values.flatMap { $0 }).map { raw in
            var result = renderedFilters[raw.selectionKey]!
            result.displayTag = raw.displayTag
            return result
        }
    }
    func contextFacts(filters: [NativeOverviewFilter]) -> [JSONValue] {
        (filters + filters.flatMap(\.children)).compactMap { context[$0.selectionKey] }
    }

    func reset(threads: [HarnessThread], applications: [NativeOverviewApplicationEntry],
               catalog: NativeWorkspaceCatalog, directoryTags: [JSONText: String],
               application: (JSONText) -> NativeOverviewApplicationEntry?) {
        threadScopes.removeAll(); applicationScopes.removeAll(); self.threads.removeAll(); self.applications.removeAll()
        unscoped.removeAll(); directoryApplications.removeAll(); semanticApplications.removeAll()
        scopeFilters.removeAll(); renderedFilters.removeAll(); members.removeAll(); context.removeAll(); redundant.removeAll()
        scopeDependencies.removeAll(); dependentScopes.removeAll()
        for thread in threads { index(thread: thread, id: thread.id) }
        for item in applications { index(application: item, id: item.entry.ref.threadID) }
        let scopes = Set(self.threads.keys).union(self.applications.keys)
        for scope in scopes { rebuild(scope: scope, catalog: catalog, directoryTags: directoryTags, application: application) }
    }

    @discardableResult
    func update(threadIDs: Set<JSONText>, applicationIDs: Set<JSONText>,
                catalog: NativeWorkspaceCatalog, directoryTags: [JSONText: String],
                application: (JSONText) -> NativeOverviewApplicationEntry?) -> Set<String> {
        var scopes = Set<String>()
        for id in threadIDs {
            if let old = threadScopes[id] { scopes.insert(old) }
            index(thread: catalog.thread(id), id: id)
            if let next = threadScopes[id] { scopes.insert(next) }
        }
        for id in applicationIDs {
            if let old = applicationScopes[id] { scopes.insert(old) }
            if let old = unscoped[id] {
                for key in old.directory.union(old.semantic) { scopes.formUnion(dependentScopes[key] ?? []) }
            }
            index(application: application(id), id: id)
            if let next = applicationScopes[id] { scopes.insert(next) }
            if let next = unscoped[id] {
                for key in next.directory.union(next.semantic) { scopes.formUnion(dependentScopes[key] ?? []) }
            }
        }
        for scope in scopes { rebuild(scope: scope, catalog: catalog, directoryTags: directoryTags, application: application) }
        return scopes
    }

    private func index(thread: HarnessThread?, id: JSONText) {
        if let old = threadScopes.removeValue(forKey: id) {
            threads[old]?.remove(id)
            if threads[old]?.isEmpty == true { threads.removeValue(forKey: old) }
        }
        guard let thread, thread.moku != true else { return }
        let scope = NativeOverviewSelection.scope(thread)
        threadScopes[id] = scope; threads[scope, default: []].insert(id)
    }

    private func index(application: NativeOverviewApplicationEntry?, id: JSONText) {
        if let old = applicationScopes.removeValue(forKey: id) {
            applications[old]?.remove(id)
            if applications[old]?.isEmpty == true { applications.removeValue(forKey: old) }
        }
        if let old = unscoped.removeValue(forKey: id) {
            for key in old.directory {
                directoryApplications[key]?.remove(id)
                if directoryApplications[key]?.isEmpty == true { directoryApplications.removeValue(forKey: key) }
            }
            for key in old.semantic {
                semanticApplications[key]?.remove(id)
                if semanticApplications[key]?.isEmpty == true { semanticApplications.removeValue(forKey: key) }
            }
        }
        guard let application else { return }
        if let scope = application.entry.scope?.string {
            applicationScopes[id] = scope; applications[scope, default: []].insert(id)
        } else {
            let directoryTags = application.directoryOnly ? application.entry.tags.directoryTags : application.entry.tags.tags
            let keys = Unscoped(directory: Set(directoryTags.map { NativeOverviewSelection.key($0.string) }),
                semantic: application.directoryOnly ? [] : Set(application.entry.tags.tags.map { NativeOverviewSelection.key($0.string) }))
            unscoped[id] = keys
            for key in keys.directory { directoryApplications[key, default: []].insert(id) }
            for key in keys.semantic { semanticApplications[key, default: []].insert(id) }
        }
    }

    private func rebuild(scope: String, catalog: NativeWorkspaceCatalog, directoryTags: [JSONText: String],
                         application: (JSONText) -> NativeOverviewApplicationEntry?) {
        let old = scopeFilters[scope] ?? []
        for filter in old + old.flatMap(\.children) {
            members.removeValue(forKey: filter.selectionKey); renderedFilters.removeValue(forKey: filter.selectionKey)
            context.removeValue(forKey: filter.selectionKey); redundant.remove(filter.selectionKey)
        }
        for key in scopeDependencies.removeValue(forKey: scope) ?? [] {
            dependentScopes[key]?.remove(scope)
            if dependentScopes[key]?.isEmpty == true { dependentScopes.removeValue(forKey: key) }
        }
        let threadInputs = (threads[scope] ?? []).compactMap { id -> (Int, HarnessThread)? in
            guard let thread = catalog.thread(id), let position = catalog.threadPosition(id) else { return nil }
            return (position, thread)
        }.sorted { $0.0 < $1.0 }.map(\.1)
        func orderedApplications(_ ids: Set<JSONText>) -> [NativeOverviewApplicationEntry] {
            ids.compactMap { id -> (Int, NativeOverviewApplicationEntry)? in
                guard let item = application(id), let position = catalog.applicationPosition(id) else { return nil }
                return (position, item)
            }.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let ownIDs = applications[scope] ?? []
        let ownApplications = orderedApplications(ownIDs)
        let candidates = NativeOverviewSelection.candidates(threads: threadInputs, applications: ownApplications)
        let browsing = NativeOverviewCollection(threads: candidates.threads.filter { !$0.attentionHidden }, applications: candidates.applications)
        var keys: [String: String] = [:]
        func normalized(_ text: String) -> String {
            if let value = keys[text] { return value }
            let value = NativeOverviewSelection.key(text); keys[text] = value; return value
        }
        let filters = NativeOverviewSelection.filters(browsing, directoryTags: directoryTags, key: normalized)
        if filters.isEmpty { scopeFilters.removeValue(forKey: scope) }
        else { scopeFilters[scope] = filters }
        func select(_ filter: NativeOverviewFilter) -> NativeOverviewMembership {
            var ids = ownIDs
            for key in Set(([filter.tag] + filter.aliases).map(normalized)) {
                if filter.isDirectory { ids.formUnion(directoryApplications[key] ?? []) }
                else if scope == NativeOverviewSelection.inboxScope { ids.formUnion(semanticApplications[key] ?? []) }
            }
            let applications = orderedApplications(ids)
            selectionCount += 1; applicationCandidateVisits += applications.count
            return NativeOverviewMembership(NativeOverviewSelection.select(threads: browsing.threads, applications: applications,
                tags: [filter.tag] + filter.aliases, kind: filter.isDirectory ? .directory : .semantic,
                scope: scope, directoryTags: directoryTags, key: normalized))
        }
        for var filter in filters {
            let parent = select(filter)
            members[filter.selectionKey] = parent; filter.count = parent.threads.count + parent.applications.count
            for index in filter.children.indices {
                var child = filter.children[index]
                let selected = select(child)
                members[child.selectionKey] = selected; child.count = selected.threads.count + selected.applications.count
                filter.children[index] = child
            }
            if filter.isDirectory, filter.children.count == 1, let child = filter.children.first {
                let names = browsing.threads.flatMap { $0.tags.map(\.string) }
                    + candidates.applications.flatMap { $0.entry.tags.semanticTags.map(\.string) }
                let semanticKeys = Set(names.map(normalized).filter { !$0.isEmpty })
                let selected = members[child.selectionKey]!
                if semanticKeys.count == 1, Set(parent.threads) == Set(selected.threads), Set(parent.applications) == Set(selected.applications) {
                    redundant.insert(child.selectionKey)
                }
            }
            renderedFilters[filter.selectionKey] = filter
            for value in [filter] + filter.children {
                let selected = members[value.selectionKey]!
                let refs = selected.threads.map { ApplicationThreadRef(threadID: $0, typeID: "agent").json } + selected.applications.map(\.json)
                context[value.selectionKey] = .object(["tag": .text(value.tag), "kind": .text(value.isDirectory ? "directory" : "semantic"),
                    "scope": value.scope.isEmpty ? .null : .text(value.scope), "aliases": .array(value.aliases.map(JSONValue.text)),
                    "count": .integer(value.count), "threads": .array(refs)])
                if value.isDirectory || scope == NativeOverviewSelection.inboxScope {
                    for key in Set(([value.tag] + value.aliases).map(normalized)) {
                        scopeDependencies[scope, default: []].insert(key)
                        dependentScopes[key, default: []].insert(scope)
                    }
                }
            }
        }
    }
}
