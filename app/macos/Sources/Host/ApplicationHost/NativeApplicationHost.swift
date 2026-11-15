import AppKit
import Foundation
import Observation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

@MainActor
public struct NativeApplicationNavigationCallbacks {
    public let openThread: (ApplicationThreadRef, HarnessReadingTarget?) -> Void
    public let openExecution: (ApplicationExecutionRef) -> Void
    public let followUp: (JSONText, JSONText) -> Void
    public let openExternal: (URL) async throws -> Void
    public init(openThread: @escaping (ApplicationThreadRef, HarnessReadingTarget?) -> Void,
                openExecution: @escaping (ApplicationExecutionRef) -> Void,
                followUp: @escaping (JSONText, JSONText) -> Void,
                openExternal: @escaping (URL) async throws -> Void) {
        self.openThread = openThread; self.openExecution = openExecution
        self.followUp = followUp; self.openExternal = openExternal
    }
}

/// Application composition understands only public catalog/presentation fields.
/// Private views are decoded exclusively by each registered Swift plugin.
@MainActor
public final class NativeApplicationHost {
    public let workspace: NativeWorkspaceModel
    public let navigation: NativeApplicationNavigationCallbacks
    lazy var git = NativeGitWorkspaceModel(host: self)
    private struct ReferenceListener {
        let references: [ApplicationExecutionRef]
        let threads: Set<JSONText>
        let previews: Bool
        let callback: () -> Void
    }
    private struct PreviewKey: Hashable {
        let thread: JSONText
        let execution: JSONText
    }
    private struct PreviewCacheEntry {
        let threadRevision: Int
        let title: JSONText?
        let preview: HarnessExecutionPreview?
    }
    private var referenceListeners: [UUID: ReferenceListener] = [:]
    private var listenersByThread: [JSONText: Set<UUID>] = [:]
    private var applicationBindings: [JSONText: Set<JSONText>] = [:]
    private var htmlApplications = Set<JSONText>()
    private var previewCache: [PreviewKey: PreviewCacheEntry] = [:]
    private var pendingPreviewKeys = Set<PreviewKey>()
    private var inFlightPreviewKeys = Set<PreviewKey>()
    private var previewGeneration = 0
    // Test seam for fixture runs without a connected Runtime. Production uses
    // the exact-reference command below.
    var previewResolver: (([ApplicationExecutionRef]) async throws -> [NativeExecutionPreview])?
    private var previewTask: Task<Void, Never>?
    private var previewTaskGeneration = -1
    private var stopCatalogObservation: (() -> Void)?
    private var observing = true
    let htmlPreloader = NativeApplicationHTMLPreloader()
    public private(set) var isReleased = false
    /// Test/diagnostic surface for preview-cache release; values are plain data.
    var retainedPreviewCount: Int { previewCache.count }

    public init(workspace: NativeWorkspaceModel, navigationCallbacks: NativeApplicationNavigationCallbacks) {
        self.workspace = workspace; navigation = navigationCallbacks
        catalogChanged(.init(reset: true))
        stopCatalogObservation = workspace.catalog.observeChanges { [weak self] in self?.catalogChanged($0) }
    }
    public var overviewFactories: NativeOverviewApplicationFactories {
        NativeOverviewApplicationFactories(projectionCapabilities: { [weak self] plugin, entry in
            guard let self else { throw CancellationError() }
            return try projectionCapabilities(plugin: plugin, entry: entry)
        }, rendererContext: { [weak self] plugin, entry, lifetime in
            guard let self else { throw CancellationError() }
            return try rendererContext(plugin: plugin, entry: entry, lifetime: lifetime)
        }, gitStatus: { [weak self] thread in self?.git.status(thread: thread) })
    }
    public func release() {
        git.stop(); isReleased = true; observing = false
        previewGeneration += 1
        previewTask?.cancel(); previewTask = nil; previewTaskGeneration = -1
        pendingPreviewKeys.removeAll(); inFlightPreviewKeys.removeAll(); previewCache.removeAll()
        previewResolver = nil
        stopCatalogObservation?(); stopCatalogObservation = nil
        referenceListeners.removeAll(); listenersByThread.removeAll(); applicationBindings.removeAll(); htmlApplications.removeAll()
        htmlPreloader.setEnabled(false)
    }
    public func entry(_ ref: ApplicationThreadRef) throws -> ApplicationThreadCatalogEntry<JSONValue> {
        guard !isReleased else { throw CancellationError() }
        let result = try workspace.catalog.applicationEntry(ref)
        guard result.ref == ref else { throw PluginContractError("Application thread identity changed") }
        return result
    }
    public func canOpen(_ typeID: JSONText) -> Bool {
        (try? workspace.plugins.applications.requireThread(typeID).hasDetail) == true
    }
    func module(_ id: JSONText) throws -> ApplicationPluginModule {
        if id == "git" { return try NativeGitService.module() }
        guard let module = workspace.plugins.applications.modules.first(where: { $0.manifest.id == id }) else {
            throw PluginContractError("Application plugin is not registered: \(id.string)")
        }
        return module
    }
    func isEnabled(_ owner: JSONText) -> Bool {
        if owner == "git" { return true }
        let key = JSONText(codeUnits: JSONText("extension:").codeUnits + owner.codeUnits)
        return workspace.catalog.plugins.first(where: { $0["key"] == .string(key) })?["enabled"] != .bool(false)
    }
    func isHarnessAvailable(_ id: JSONText) -> Bool {
        let key = JSONText(codeUnits: JSONText("harness:").codeUnits + id.codeUnits)
        let harness = workspace.catalog.plugins.first { $0["key"] == .string(key) }
        return harness?["enabled"] != .bool(false)
            && (harness?["unavailableReason"] == nil || harness?["unavailableReason"] == .null)
    }
    func canExecute(_ owner: JSONText, entry: ApplicationThreadCatalogEntry<JSONValue>) -> Bool {
        workspace.runtimeAvailable && isEnabled(owner) && !entry.archived
    }
    var theme: PluginTheme {
        switch workspace.preferences.appearance {
        case .light: .light
        case .dark: .dark
        case .system:
            NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        }
    }
    var locale: JSONText { JSONText(workspace.preferences.locale.rawValue) }

    func domain(pluginID: JSONText, viewLifetime: PluginLifetime) throws -> ApplicationDomainClient {
        let manifest = try module(pluginID).manifest
        return ApplicationDomainClient(pluginID: pluginID) { [weak self] kind, operation, input, receipt, callLifetime in
            guard let self, !isReleased else { throw CancellationError() }
            try callLifetime.checkCancellation()
            let allowed = kind == .query ? manifest.contributes.queries : manifest.contributes.commands
            guard allowed.contains(operation) else { throw PluginContractError("Application operation is not declared by its owner") }
            if kind == .query { try viewLifetime.checkCancellation() }
            if kind == .command, !isEnabled(pluginID) { throw PluginContractError("Application plugin is disabled") }
            var payload: [JSONText: JSONValue] = ["pluginId": .string(pluginID), "operationId": .string(operation), "input": input]
            if kind == .command {
                guard let receipt else { throw PluginContractError("Application command has no receipt identity") }
                payload["requestId"] = .string(receipt)
            }
            let check = {
                try callLifetime.checkCancellation()
                if kind == .query { try viewLifetime.checkCancellation() }
                if kind == .command, !self.isEnabled(pluginID) { throw PluginContractError("Application plugin is disabled") }
            }
            let value: JSONValue
            if kind == .query {
                value = try await invokeQuery(args: [.object(payload)], check: check)
            } else {
                value = try await invokePrepared("application:command", args: [.object(payload)], check: check)
            }
            try callLifetime.checkCancellation()
            if kind == .query {
                guard !isReleased else { throw CancellationError() }
                try viewLifetime.checkCancellation()
            }
            return value
        }
    }

    func archive(_ ref: ApplicationThreadRef, archived: Bool, owner: JSONText,
                 viewLifetime: PluginLifetime, callLifetime: PluginLifetime) async throws {
        try viewLifetime.checkCancellation(); try callLifetime.checkCancellation()
        let current = try entry(ref)
        let plugin = try workspace.plugins.applications.requireThread(current.ref.typeID)
        guard plugin.ownerPluginID == owner, isEnabled(owner), plugin.allowsManualArchiving else { throw PluginContractError("Application archive authority is unavailable or managed automatically") }
        _ = try await invokePrepared("application:archive", args: [ref.json, .bool(archived)]) {
            try viewLifetime.checkCancellation(); try callLifetime.checkCancellation()
            let current = try self.entry(ref)
            guard try self.workspace.plugins.applications.requireThread(current.ref.typeID).ownerPluginID == owner,
                  self.isEnabled(owner) else { throw PluginContractError("Application archive authority is unavailable") }
        }
    }
    func initialize(_ ref: ApplicationThreadRef, owner: JSONText,
                    viewLifetime: PluginLifetime, callLifetime: PluginLifetime) async throws {
        try viewLifetime.checkCancellation(); try callLifetime.checkCancellation()
        let current = try entry(ref)
        guard try workspace.plugins.applications.requireThread(ref.typeID).ownerPluginID == owner,
              canExecute(owner, entry: current) else { throw PluginContractError("Application conversation cannot be initialized") }
        guard try conversation(current) != nil else { throw PluginContractError("Application thread has no conversation extension") }
        _ = try await invokePrepared("application:initialize-conversation", args: [ref.json]) {
            try viewLifetime.checkCancellation(); try callLifetime.checkCancellation()
            let latest = try self.entry(ref)
            guard try self.workspace.plugins.applications.requireThread(ref.typeID).ownerPluginID == owner,
                  self.canExecute(owner, entry: latest), try self.conversation(latest) != nil else {
                throw PluginContractError("Application conversation authority changed")
            }
        }
    }

    /// Connected reads need no durable output-locale write. An unavailable
    /// service may start background work when the client reconnects, so retain
    /// the startup locale barrier along with the authority and lifetime checks.
    func invokeQuery(args: [JSONValue], check: () throws -> Void) async throws -> JSONValue {
        guard !isReleased else { throw CancellationError() }
        try Task.checkCancellation(); try check()
        if !workspace.runtimeAvailable {
            try await workspace.prepareCommand()
            guard !isReleased else { throw CancellationError() }
            try Task.checkCancellation(); try check()
        }
        let value = try await workspace.client.invoke("application:query", args: args)
        guard !isReleased else { throw CancellationError() }
        try Task.checkCancellation(); try check()
        return value
    }

    /// Recheck scope after locale publication; cancellation or a catalog change
    /// during that await must not admit a now-obsolete user operation.
    func invokePrepared(_ channel: String, args: [JSONValue], check: () throws -> Void) async throws -> JSONValue {
        guard !isReleased else { throw CancellationError() }
        try Task.checkCancellation(); try check()
        try await workspace.prepareCommand()
        guard !isReleased else { throw CancellationError() }
        try Task.checkCancellation(); try check()
        return try await workspace.client.invoke(channel, args: args)
    }

    func executionReferences(_ references: [ApplicationExecutionRef]) throws -> [ApplicationExecutionPresentation] {
        guard !isReleased else { throw CancellationError() }
        return try references.compactMap { reference in
            // This capability presents ordinary Agent Threads only, including
            // historical executions. Application conversations are not agents.
            let thread = reference.thread.typeID == "agent"
                ? workspace.catalog.thread(reference.thread.threadID) : nil
            guard let thread else {
                return ApplicationExecutionPresentation(reference: reference,
                    title: JSONText(workspace.preferences.locale.text("已删除的 Agent Thread", "Deleted Agent Thread")),
                    emoji: nil, missing: true, running: false, harness: nil, preview: nil)
            }
            guard thread.moku != true, !thread.mokuHistory else { return nil }
            let plugin = try workspace.plugins.harnesses.require(thread.harnessID)
            let key = PreviewKey(thread: reference.thread.threadID, execution: reference.executionID)
            let cached = previewCache[key]
            // A title or excerpt is valid only when it was projected for this
            // exact execution; the current Thread title/status never substitutes.
            // Stale revisions retain the same execution's last facts until the
            // debounced refresh arrives.
            let title = cached?.title
                ?? JSONText(workspace.preferences.locale.text("执行记录", "Execution"))
            return ApplicationExecutionPresentation(reference: reference, title: title,
                emoji: nativeGeneratedThreadEmoji(metadata: thread.metadataState), missing: false,
                running: cached?.preview?.running ?? false,
                harness: .init(id: plugin.descriptor.id, displayName: plugin.descriptor.displayName),
                preview: cached?.preview)
        }
    }
    func subscribeReferences(_ references: [ApplicationExecutionRef], listener: @escaping () -> Void,
                             previews: Bool = true, lifetime: PluginLifetime) -> () -> Void {
        guard !lifetime.isCancelled, observing else { return {} }
        let id = UUID()
        let threads = Set(references.filter { $0.thread.typeID == "agent" }.map { $0.thread.threadID })
        referenceListeners[id] = .init(references: references, threads: threads, previews: previews, callback: listener)
        for thread in threads { listenersByThread[thread, default: []].insert(id) }
        if previews { schedulePreviews(references) }
        let token = lifetime.onCancel { [weak self] in self?.removeReferenceListener(id) }
        return { [weak self, weak lifetime] in
            self?.removeReferenceListener(id); lifetime?.removeHandler(token)
        }
    }
    private func removeReferenceListener(_ id: UUID) {
        guard let listener = referenceListeners.removeValue(forKey: id) else { return }
        for thread in listener.threads {
            listenersByThread[thread]?.remove(id)
            if listenersByThread[thread]?.isEmpty == true { listenersByThread.removeValue(forKey: thread) }
        }
        let referenced = referencedPreviewKeys()
        for key in Array(previewCache.keys) where !referenced.contains(key) {
            previewCache.removeValue(forKey: key)
        }
        pendingPreviewKeys = Set(pendingPreviewKeys.filter { referenced.contains($0) })
        inFlightPreviewKeys = inFlightPreviewKeys.intersection(referenced)
        if pendingPreviewKeys.isEmpty && inFlightPreviewKeys.isEmpty && referenced.isEmpty {
            previewGeneration += 1
            previewTask?.cancel(); previewTask = nil; previewTaskGeneration = -1
        }
    }

    private func referencedPreviewKeys() -> Set<PreviewKey> {
        var result = Set<PreviewKey>()
        for listener in referenceListeners.values where listener.previews {
            for reference in listener.references where reference.thread.typeID == "agent" {
                result.insert(PreviewKey(thread: reference.thread.threadID, execution: reference.executionID))
            }
        }
        return result
    }

    private func schedulePreviews(_ references: [ApplicationExecutionRef]) {
        guard observing, !isReleased else { return }
        let referenced = referencedPreviewKeys()
        for reference in references where reference.thread.typeID == "agent" {
            let key = PreviewKey(thread: reference.thread.threadID, execution: reference.executionID)
            guard referenced.contains(key) else { continue }
            if let cached = previewCache[key], let thread = workspace.catalog.thread(key.thread),
               cached.threadRevision == thread.revision {
                continue
            }
            pendingPreviewKeys.insert(key)
        }
        startPreviewTask()
    }

    private func startPreviewTask() {
        guard previewTask == nil, !pendingPreviewKeys.isEmpty, !isReleased else { return }
        let generation = previewGeneration
        previewTaskGeneration = generation
        let immediate = pendingPreviewKeys.contains { previewCache[$0] == nil }
        previewTask = Task { @MainActor [weak self] in
            if !immediate {
                // Streaming catalog revisions arrive per token. Coalesce refreshes
                // so a cited preview updates after the burst, not once per revision.
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            }
            guard let self, !self.isReleased, self.previewTaskGeneration == generation else { return }
            await self.drainPreviews(generation: generation)
            guard !self.isReleased, self.previewTaskGeneration == generation else { return }
            self.previewTask = nil; self.previewTaskGeneration = -1
            if !self.pendingPreviewKeys.isEmpty { self.startPreviewTask() }
        }
    }

    private func drainPreviews(generation: Int) async {
        while !Task.isCancelled, generation == previewGeneration, !pendingPreviewKeys.isEmpty {
            let batch = Set(pendingPreviewKeys.prefix(64))
            pendingPreviewKeys.subtract(batch)
            inFlightPreviewKeys.formUnion(batch)
            await fetchPreviews(batch, generation: generation)
            inFlightPreviewKeys.subtract(batch)
        }
    }

    private func fetchPreviews(_ keys: Set<PreviewKey>, generation: Int) async {
        guard !isReleased, generation == previewGeneration else {
            requeuePreviews(keys)
            return
        }
        let references = keys.compactMap { key -> (PreviewKey, Int)? in
            guard let thread = workspace.catalog.thread(key.thread) else { return nil }
            return (key, thread.revision)
        }
        guard !references.isEmpty else { return }
        let applicationReferences = references.map {
            ApplicationExecutionRef(thread: ApplicationThreadRef(threadID: $0.0.thread, typeID: "agent"),
                                    executionID: $0.0.execution)
        }
        do {
            let previews: [NativeExecutionPreview]
            if let previewResolver {
                previews = try await previewResolver(applicationReferences)
            } else {
                try await workspace.prepareCommand()
                guard !isReleased, generation == previewGeneration else {
                    requeuePreviews(keys)
                    return
                }
                let value = try await workspace.client.invoke("thread:execution-previews", args: [.object([
                    "references": .array(applicationReferences.map { reference in
                        .object(["threadId": .string(reference.thread.threadID), "executionId": .string(reference.executionID)])
                    })
                ])])
                guard !isReleased, generation == previewGeneration else {
                    requeuePreviews(keys)
                    return
                }
                previews = (value["previews"]?.arrayValue ?? []).compactMap { try? NativeExecutionPreview(json: $0) }
            }
            guard !isReleased, generation == previewGeneration else {
                requeuePreviews(keys)
                return
            }
            var fetched: [PreviewKey: PreviewCacheEntry] = [:]
            let referenced = referencedPreviewKeys()
            for preview in previews {
                let key = PreviewKey(thread: preview.thread, execution: preview.executionID)
                guard referenced.contains(key),
                      let revision = references.first(where: { $0.0 == key })?.1,
                      let thread = workspace.catalog.thread(key.thread), thread.revision == revision else { continue }
                fetched[key] = PreviewCacheEntry(threadRevision: revision,
                    title: preview.title, preview: preview.preview)
            }
            for (key, revision) in references where referenced.contains(key) && fetched[key] == nil {
                fetched[key] = PreviewCacheEntry(threadRevision: revision, title: nil, preview: nil)
            }
            guard !fetched.isEmpty else { return }
            for (key, entry) in fetched { previewCache[key] = entry }
            notifyPreviewListeners(Set(fetched.keys))
        } catch {
            // A later catalog revision or explicit read retries. Do not retain a
            // stale preview after its source Thread became unavailable.
        }
    }

    private func requeuePreviews(_ keys: Set<PreviewKey>) {
        guard !isReleased else { return }
        let referenced = referencedPreviewKeys()
        for key in keys where referenced.contains(key) {
            if let cached = previewCache[key], let thread = workspace.catalog.thread(key.thread),
               cached.threadRevision == thread.revision {
                continue
            }
            pendingPreviewKeys.insert(key)
        }
        startPreviewTask()
    }

    private func notifyPreviewListeners(_ keys: Set<PreviewKey>) {
        guard !keys.isEmpty else { return }
        let ids = referenceListeners.compactMap { entry -> UUID? in
            let (id, listener) = entry
            return listener.previews && listener.references.contains { reference in
                reference.thread.typeID == "agent" &&
                    keys.contains(PreviewKey(thread: reference.thread.threadID, execution: reference.executionID))
            } ? id : nil
        }
        for id in ids { referenceListeners[id]?.callback() }
    }

    private func invalidatePreviews(threads: Set<JSONText>) {
        guard !threads.isEmpty else { return }
        let relevant = referenceListeners.values.flatMap { $0.previews ? $0.references : [] }.filter { threads.contains($0.thread.threadID) }
        let touched = pendingPreviewKeys.union(inFlightPreviewKeys).union(previewCache.keys).contains { threads.contains($0.thread) }
        guard touched || !relevant.isEmpty else { return }
        previewGeneration += 1
        previewTask?.cancel(); previewTask = nil; previewTaskGeneration = -1
        pendingPreviewKeys = Set(pendingPreviewKeys.filter { !threads.contains($0.thread) })
        inFlightPreviewKeys = Set(inFlightPreviewKeys.filter { !threads.contains($0.thread) })
        for key in Array(previewCache.keys) where threads.contains(key.thread) && workspace.catalog.thread(key.thread) == nil {
            previewCache.removeValue(forKey: key)
        }
        schedulePreviews(relevant)
    }
    private func catalogChanged(_ change: NativeCatalogChanges) {
        guard observing else { return }
        var affectedThreads = change.threadIDs
        let applications: Set<JSONText>
        if change.reset || change.fields.contains("plugins") {
            applications = Set(workspace.catalog.applicationThreads.compactMap { raw in
                guard case .string(let id) = raw["id"] else { return nil }; return id
            }).union(applicationBindings.keys).union(htmlApplications)
        } else { applications = change.applicationIDs }
        for id in applications {
            let raw = workspace.catalog.applicationJSON(id)
            let previous = applicationBindings[id] ?? []
            let entry = raw.flatMap { try? workspace.catalog.applicationEntry(json: $0) }
            let projection = entry.flatMap { try? NativeOverviewApplicationEntry(entry: $0) }
            let bindings = Set((projection?.coveredExecutions ?? []).filter { $0.thread.typeID == "agent" }.map { $0.thread.threadID })
            if bindings.isEmpty { applicationBindings.removeValue(forKey: id) }
            else { applicationBindings[id] = bindings }
            if previous != bindings { affectedThreads.formUnion(previous); affectedThreads.formUnion(bindings) }
            if let entry, let plugin = try? workspace.plugins.applications.requireThread(entry.ref.typeID),
               plugin.hasDetail, isEnabled(plugin.ownerPluginID),
               plugin.requires.contains(ApplicationCapabilities.isolatedHTML.requirement) {
                htmlApplications.insert(id)
            } else { htmlApplications.remove(id) }
        }
        htmlPreloader.setEnabled(!htmlApplications.isEmpty)
        let previewThreads: Set<JSONText>
        if change.reset {
            previewThreads = Set(previewCache.keys.map(\.thread))
                .union(pendingPreviewKeys.map(\.thread))
                .union(inFlightPreviewKeys.map(\.thread))
                .union(referenceListeners.values.flatMap(\.references).map(\.thread.threadID))
        } else {
            previewThreads = affectedThreads
        }
        invalidatePreviews(threads: previewThreads)
        let listeners = change.reset ? Set(referenceListeners.keys)
            : affectedThreads.reduce(into: Set<UUID>()) { $0.formUnion(listenersByThread[$1] ?? []) }
        for id in listeners { referenceListeners[id]?.callback() }
    }
}
