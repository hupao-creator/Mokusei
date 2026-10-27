import Foundation
import MokuseiCore
import SwiftUI

/// The queued overview revision owns both its public envelope and the exact
/// private projection that produced it. Rendering never projects a second time.
@MainActor
public final class HarnessOverviewSnapshot {
    public let input: HarnessThreadInput
    public let availableColumns: Int
    public let envelope: HarnessOverviewEnvelope
    private let render: (HarnessThreadActions, @escaping () -> Void) -> AnyView
    fileprivate init(input: HarnessThreadInput, availableColumns: Int, envelope: HarnessOverviewEnvelope,
                     render: @escaping (HarnessThreadActions, @escaping () -> Void) -> AnyView) {
        self.input = input; self.availableColumns = availableColumns; self.envelope = envelope; self.render = render
    }
    public func card(actions: HarnessThreadActions, openThread: @escaping () -> Void) -> AnyView {
        render(actions, openThread)
    }
}

/// Typed presentation resources stay in the plugin binding. The host holds this
/// session for its settings resource lifetime and invalidates it at teardown.
/// Global resources may be prefetched and retained across editor mounts.
@MainActor
public final class HarnessSettingsSession {
    public let reload: (_ refresh: Bool) async throws -> Void
    public let invalidate: () -> Void
    public let sourceChanged: () -> Void
    private let ready: () -> Bool
    public var isReady: Bool { ready() }
    private let threadBody: (HarnessThreadInput, @escaping (JSONValue) async throws -> Void) throws -> AnyView
    private let harnessBody: (HarnessSettingsSection, Bool, Bool, JSONValue, HarnessSettingsHost?, @escaping (JSONValue) throws -> Void) throws -> AnyView
    fileprivate init(reload: @escaping (Bool) async throws -> Void, invalidate: @escaping () -> Void, sourceChanged: @escaping () -> Void,
                     isReady: @escaping () -> Bool,
                     threadBody: @escaping (HarnessThreadInput, @escaping (JSONValue) async throws -> Void) throws -> AnyView,
                     harnessBody: @escaping (HarnessSettingsSection, Bool, Bool, JSONValue, HarnessSettingsHost?, @escaping (JSONValue) throws -> Void) throws -> AnyView) {
        self.reload = reload; self.invalidate = invalidate; ready = isReady
        self.sourceChanged = sourceChanged
        self.threadBody = threadBody; self.harnessBody = harnessBody
    }
    public func threadSettings(input: HarnessThreadInput, update: @escaping (JSONValue) async throws -> Void) throws -> AnyView {
        try threadBody(input, update)
    }
    public func harnessSettings(section: HarnessSettingsSection, executionSnapshot: Bool = false,
                                settingsFormPage: Bool = false, value: JSONValue, host: HarnessSettingsHost?,
                                change: @escaping (JSONValue) throws -> Void) throws -> AnyView {
        try harnessBody(section, executionSnapshot, settingsFormPage, value, host, change)
    }
}

@MainActor
private final class HarnessProjectionCache<Plugin: HarnessPlugin> {
    let plugin: Plugin
    private var entries: [JSONText: [Int: HarnessOverviewSnapshot]] = [:]
    private var recency: [JSONText] = []
    init(_ plugin: Plugin) { self.plugin = plugin }
    func project(_ input: HarnessThreadInput, columns: Int) throws -> HarnessOverviewSnapshot {
        guard (1...3).contains(columns) else { throw PluginContractError("Overview requires one to three available columns") }
        guard input.thread.harnessID == plugin.descriptor.id else { throw PluginContractError("Thread belongs to a different Harness") }
        if let snapshot = entries[input.thread.id]?[columns], snapshot.input == input { return snapshot }
        let projection = try plugin.projectOverview(input: input, availableColumns: columns)
        guard projection.envelope.footprint.columns > 0, projection.envelope.footprint.rows > 0,
              projection.envelope.footprint.columns <= columns,
              !projection.envelope.structureKey.codeUnits.isEmpty else {
            throw PluginContractError("Harness produced an invalid overview footprint")
        }
        let snapshot = HarnessOverviewSnapshot(input: input, availableColumns: columns, envelope: projection.envelope) { [plugin] actions, open in
            AnyView(plugin.overviewCard(input: input, projection: projection.view, actions: actions, openThread: open))
        }
        // Keep at most one revision per width and bounded recent threads. Old
        // choreography snapshots survive only while their owning host retains them.
        entries[input.thread.id, default: [:]][columns] = snapshot
        recency.removeAll { $0 == input.thread.id }; recency.append(input.thread.id)
        while recency.count > 128 { entries.removeValue(forKey: recency.removeFirst()) }
        return snapshot
    }
    func clear() { entries.removeAll(); recency.removeAll() }
}

/// The single heterogeneous collection boundary. It erases native Swift views,
/// never serializes a UI tree, and never gives plugins the runtime transport.
@MainActor
public final class AnyHarnessPlugin {
    public let descriptor: HarnessPluginDescriptor
    public let logoSource: String
    public let translations: HarnessTranslationCatalog
    private let logoBody: (CGFloat) -> AnyView
    private let threadBody: (HarnessThreadInput, HarnessThreadActions, HarnessRenderContext) -> AnyView
    private let overview: (HarnessThreadInput, Int) throws -> HarnessOverviewSnapshot
    private let moku: (HarnessThreadInput) throws -> HarnessMokuPresentation?
    private let usage: (HarnessThread, JSONText) throws -> HarnessExecutionTokenUsage?
    private let settings: (@escaping (Bool) async throws -> JSONValue, @escaping (Error) -> Void) -> HarnessSettingsSession
    public let clearProjectionCache: () -> Void

    public init<P: HarnessPlugin>(_ plugin: P) {
        descriptor = plugin.descriptor; logoSource = plugin.logoSource; translations = plugin.translations
        logoBody = { size in AnyView(plugin.logo(size: size)) }
        let cache = HarnessProjectionCache(plugin)
        threadBody = { input, actions, context in AnyView(plugin.threadView(input: input, actions: actions, context: context)) }
        overview = { input, columns in try cache.project(input, columns: columns) }
        moku = { try plugin.projectMokuDock(input: $0) }
        usage = { try plugin.executionTokenUsage(thread: $0, executionID: $1) }
        clearProjectionCache = { cache.clear() }
        settings = { load, onError in
            let resource = HarnessSettingsResource<P.SettingsPresentation> { refresh in
                try plugin.settingsPresentationCodec.decode(try await load(refresh))
            }
            return HarnessSettingsSession(reload: { try await resource.reload(refresh: $0) }, invalidate: { resource.invalidate() },
                sourceChanged: { resource.invalidate(keepingValue: true) },
                isReady: { if case .ready = resource.state { return true }; return false },
                threadBody: { input, update in
                    guard input.thread.harnessID == plugin.descriptor.id else { throw PluginContractError("Thread settings belong to a different Harness") }
                    return AnyView(plugin.threadSettings(input: input, resource: resource) { value in
                        try await update(plugin.threadSettingsCodec.encode(value))
                    })
                }, harnessBody: { section, snapshot, page, value, host, change in
                    let typed = try plugin.harnessSettingsCodec.decode(value)
                    return AnyView(plugin.harnessSettings(props: HarnessSettingsProps(section: section,
                        executionSnapshot: snapshot, settingsFormPage: page, value: typed, resource: resource, host: host,
                        change: { newValue in
                            do { try change(plugin.harnessSettingsCodec.encode(newValue)) }
                            catch { onError(error) }
                        })))
                })
        }
    }
    /// Remains a native view so the caller's color scheme reaches its owning plugin.
    public func logo(size: CGFloat) -> AnyView { logoBody(size) }

    private func validate(_ thread: HarnessThread) throws {
        guard thread.harnessID == descriptor.id else { throw PluginContractError("Thread belongs to a different Harness") }
    }
    public func threadView(input: HarnessThreadInput, actions: HarnessThreadActions, context: HarnessRenderContext) throws -> AnyView {
        try validate(input.thread); return threadBody(input, actions, context)
    }
    public func projectOverview(input: HarnessThreadInput, availableColumns: Int) throws -> HarnessOverviewSnapshot {
        try overview(input, availableColumns)
    }
    public func projectMokuDock(input: HarnessThreadInput) throws -> HarnessMokuPresentation? {
        try validate(input.thread); return try moku(input)
    }
    public func executionTokenUsage(thread: HarnessThread, executionID: JSONText) throws -> HarnessExecutionTokenUsage? {
        try validate(thread); return try usage(thread, executionID)
    }
    public func makeSettingsSession(load: @escaping (Bool) async throws -> JSONValue,
                                    onError: @escaping (Error) -> Void) -> HarnessSettingsSession {
        settings(load, onError)
    }
}

@MainActor
public final class HarnessPluginRegistry {
    public let modules: [AnyHarnessPlugin]
    private let byID: [JSONText: AnyHarnessPlugin]
    public init(_ modules: [AnyHarnessPlugin]) throws {
        var index: [JSONText: AnyHarnessPlugin] = [:]
        for module in modules {
            guard !module.descriptor.id.codeUnits.isEmpty, index[module.descriptor.id] == nil else {
                throw PluginContractError("Duplicate or empty Harness module identity")
            }
            index[module.descriptor.id] = module
        }
        self.modules = modules; byID = index
    }
    public func require(_ id: JSONText) throws -> AnyHarnessPlugin {
        guard let module = byID[id] else { throw PluginContractError("Harness is not registered: \(id.string)") }
        return module
    }
}
