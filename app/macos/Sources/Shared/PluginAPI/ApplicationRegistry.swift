import Foundation
import MokuseiCore
import SwiftUI

@MainActor
public struct ApplicationRendererContext {
    public let theme: PluginTheme
    public let locale: JSONText
    public let lifetime: PluginLifetime
    public let contentTopInset: Double
    public let domain: ApplicationDomainClient
    public let capabilities: ApplicationCapabilityAccess<ApplicationRendererPhase>
    public let openThread: (ApplicationThreadRef, HarnessReadingTarget?) -> Void
    public let openExecution: (ApplicationExecutionRef) -> Void
    public init(theme: PluginTheme, locale: JSONText, lifetime: PluginLifetime, contentTopInset: Double = 0, domain: ApplicationDomainClient,
                capabilities: ApplicationCapabilityAccess<ApplicationRendererPhase>,
                openThread: @escaping (ApplicationThreadRef, HarnessReadingTarget?) -> Void,
                openExecution: @escaping (ApplicationExecutionRef) -> Void) {
        self.theme = theme; self.locale = locale; self.lifetime = lifetime; self.contentTopInset = contentTopInset; self.domain = domain
        self.capabilities = capabilities; self.openThread = openThread; self.openExecution = openExecution
    }
}
@MainActor
public struct ApplicationThreadProps<Value> {
    public let entry: ApplicationThreadCatalogEntry<Value>
    public let readingTarget: HarnessReadingTarget?
    public let context: ApplicationRendererContext
    public init(entry: ApplicationThreadCatalogEntry<Value>, readingTarget: HarnessReadingTarget? = nil,
                context: ApplicationRendererContext) {
        self.entry = entry; self.readingTarget = readingTarget; self.context = context
    }
}
@MainActor
public struct ApplicationSettingsProps<Value> {
    public let value: Value
    public let change: (Value) -> Void
    public let theme: PluginTheme
    public let locale: JSONText
    public let capabilities: ApplicationCapabilityAccess<ApplicationRendererPhase>
    public init(value: Value, change: @escaping (Value) -> Void, theme: PluginTheme, locale: JSONText,
                capabilities: ApplicationCapabilityAccess<ApplicationRendererPhase>) {
        self.value = value; self.change = change; self.theme = theme; self.locale = locale; self.capabilities = capabilities
    }
}

@MainActor
public protocol ApplicationThreadPlugin {
    associatedtype Value
    associatedtype CardProjection
    associatedtype Card: View
    associatedtype Detail: View = EmptyView
    var type: ApplicationValueKey<Value> { get }
    var requires: [ApplicationCapabilityRequirement] { get }
    var hasDetail: Bool { get }
    var allowsManualArchiving: Bool { get }
    func projectCard(entry: ApplicationThreadCatalogEntry<Value>, availableColumns: Int,
                     capabilities: ApplicationCapabilityAccess<ApplicationProjectionPhase>) throws -> HarnessOverviewProjection<CardProjection>
    @ViewBuilder func card(props: ApplicationThreadProps<Value>, projection: CardProjection, openThread: @escaping () -> Void) -> Card
    @ViewBuilder func detail(props: ApplicationThreadProps<Value>) -> Detail
}
extension ApplicationThreadPlugin {
    public var requires: [ApplicationCapabilityRequirement] { [] }
    public var hasDetail: Bool { true }
    public var allowsManualArchiving: Bool { true }
}
extension ApplicationThreadPlugin where Detail == EmptyView {
    public var hasDetail: Bool { false }
    public func detail(props: ApplicationThreadProps<Value>) -> EmptyView { EmptyView() }
}
@MainActor
public protocol ApplicationSettingsPlugin {
    associatedtype Value
    associatedtype Content: View
    var key: ApplicationValueKey<Value> { get }
    var label: JSONText { get }
    var requires: [ApplicationCapabilityRequirement] { get }
    @ViewBuilder func settings(props: ApplicationSettingsProps<Value>) -> Content
}

extension ApplicationSettingsPlugin {
    public var requires: [ApplicationCapabilityRequirement] { [] }
}

/// Like a Harness snapshot, this closure retains the exact private card value
/// used during layout. Runtime updates cannot substitute a later projection.
@MainActor
public final class ApplicationOverviewSnapshot {
    public let entry: ApplicationThreadCatalogEntry<JSONValue>
    public let envelope: HarnessOverviewEnvelope
    private let body: (HarnessReadingTarget?, ApplicationRendererContext, @escaping () -> Void) throws -> AnyView
    fileprivate init(entry: ApplicationThreadCatalogEntry<JSONValue>, envelope: HarnessOverviewEnvelope,
                     body: @escaping (HarnessReadingTarget?, ApplicationRendererContext, @escaping () -> Void) throws -> AnyView) {
        self.entry = entry; self.envelope = envelope; self.body = body
    }
    public func card(readingTarget: HarnessReadingTarget? = nil, context: ApplicationRendererContext,
                     openThread: @escaping () -> Void) throws -> AnyView {
        try body(readingTarget, context, openThread)
    }
}
@MainActor
public struct AnyApplicationThreadPlugin {
    public let id: JSONText
    public let ownerPluginID: JSONText
    public let requires: [ApplicationCapabilityRequirement]
    public let hasDetail: Bool
    public let allowsManualArchiving: Bool
    private let project: (ApplicationThreadCatalogEntry<JSONValue>, Int, ApplicationCapabilityAccess<ApplicationProjectionPhase>) throws -> ApplicationOverviewSnapshot
    private let detailBody: (ApplicationThreadProps<JSONValue>) throws -> AnyView
    public init<P: ApplicationThreadPlugin>(_ plugin: P) {
        id = plugin.type.id; ownerPluginID = plugin.type.ownerPluginID; requires = plugin.requires; hasDetail = plugin.hasDetail
        allowsManualArchiving = plugin.allowsManualArchiving
        project = { entry, columns, capabilities in
            try capabilities.validateRequirements(plugin.requires)
            try validateApplicationScope(capabilities.scope, owner: plugin.type.ownerPluginID, entry: entry.ref, type: plugin.type.id)
            guard (1...3).contains(columns) else { throw PluginContractError("Application overview requires one to three columns") }
            let typed = try entry.mapView(plugin.type.codec.decode)
            let projected = try plugin.projectCard(entry: typed, availableColumns: columns, capabilities: capabilities)
            guard projected.envelope.footprint.columns > 0, projected.envelope.footprint.columns <= columns,
                  (1...100).contains(projected.envelope.footprint.rows) else { throw PluginContractError("Application produced an invalid overview footprint") }
            return ApplicationOverviewSnapshot(entry: entry, envelope: projected.envelope) { target, context, open in
                try context.capabilities.validateRequirements(plugin.requires)
                try validateApplicationScope(context.capabilities.scope, owner: plugin.type.ownerPluginID, entry: typed.ref, type: plugin.type.id)
                guard context.domain.pluginID == plugin.type.ownerPluginID else { throw PluginContractError("Application domain owner mismatch") }
                return AnyView(plugin.card(props: ApplicationThreadProps(entry: typed, readingTarget: target, context: context),
                                           projection: projected.view, openThread: open))
            }
        }
        detailBody = { props in
            guard plugin.hasDetail else { throw PluginContractError("This application thread has no detail surface") }
            try props.context.capabilities.validateRequirements(plugin.requires)
            try validateApplicationScope(props.context.capabilities.scope, owner: plugin.type.ownerPluginID, entry: props.entry.ref, type: plugin.type.id)
            guard props.context.domain.pluginID == plugin.type.ownerPluginID else { throw PluginContractError("Application domain owner mismatch") }
            return AnyView(plugin.detail(props: ApplicationThreadProps(entry: try props.entry.mapView(plugin.type.codec.decode),
                readingTarget: props.readingTarget, context: props.context)))
        }
    }
    public func projectCard(entry: ApplicationThreadCatalogEntry<JSONValue>, availableColumns: Int,
                            capabilities: ApplicationCapabilityAccess<ApplicationProjectionPhase>) throws -> ApplicationOverviewSnapshot {
        try project(entry, availableColumns, capabilities)
    }
    public func detail(props: ApplicationThreadProps<JSONValue>) throws -> AnyView { try detailBody(props) }
}
@MainActor
public struct AnyApplicationSettingsPlugin {
    public let id: JSONText
    public let ownerPluginID: JSONText
    public let label: JSONText
    public let requires: [ApplicationCapabilityRequirement]
    private let body: (ApplicationSettingsProps<JSONValue>, @escaping (Error) -> Void) throws -> AnyView
    public init<P: ApplicationSettingsPlugin>(_ plugin: P) {
        id = plugin.key.id; ownerPluginID = plugin.key.ownerPluginID; label = plugin.label; requires = plugin.requires
        body = { props, onError in
            try props.capabilities.validateRequirements(plugin.requires)
            guard props.capabilities.scope.pluginID == plugin.key.ownerPluginID else { throw PluginContractError("Application settings scope owner mismatch") }
            return AnyView(plugin.settings(props: ApplicationSettingsProps(value: try plugin.key.codec.decode(props.value),
                change: { value in
                    do { props.change(try plugin.key.codec.encode(value)) }
                    catch { onError(error) }
                }, theme: props.theme, locale: props.locale, capabilities: props.capabilities)))
        }
    }
    public func settings(props: ApplicationSettingsProps<JSONValue>, onError: @escaping (Error) -> Void) throws -> AnyView {
        try body(props, onError)
    }
}

/// One statically composed module can contribute several thread/settings
/// types. Background-only applications register empty renderer collections.
@MainActor
public struct ApplicationPluginModule {
    public let manifest: ApplicationPluginManifest
    public let threads: [AnyApplicationThreadPlugin]
    public let settings: [AnyApplicationSettingsPlugin]
    public init(manifest: ApplicationPluginManifest, threads: [AnyApplicationThreadPlugin] = [],
                settings: [AnyApplicationSettingsPlugin] = []) throws {
        guard Set(threads.map(\.id)).count == threads.count,
              Set(settings.map(\.id)).count == settings.count,
              threads.allSatisfy({ $0.ownerPluginID == manifest.id }),
              settings.allSatisfy({ $0.ownerPluginID == manifest.id }),
              Set(threads.map(\.id)) == Set(manifest.contributes.threadTypes),
              Set(settings.map(\.id)) == Set(manifest.contributes.settings) else {
            throw PluginContractError("Application renderer contributions do not match the manifest")
        }
        self.manifest = manifest; self.threads = threads; self.settings = settings
    }
}
@MainActor
public final class ApplicationPluginRegistry {
    public let modules: [ApplicationPluginModule]
    private let threads: [JSONText: AnyApplicationThreadPlugin]
    private let settings: [JSONText: AnyApplicationSettingsPlugin]
    public init(_ modules: [ApplicationPluginModule]) throws {
        var ids: Set<JSONText> = [], threadIndex: [JSONText: AnyApplicationThreadPlugin] = [:], settingsIndex: [JSONText: AnyApplicationSettingsPlugin] = [:]
        for module in modules {
            guard ids.insert(module.manifest.id).inserted else { throw PluginContractError("Duplicate application plugin") }
            for thread in module.threads {
                guard threadIndex[thread.id] == nil else { throw PluginContractError("Duplicate application thread type") }
                threadIndex[thread.id] = thread
            }
            for setting in module.settings {
                guard settingsIndex[setting.id] == nil else { throw PluginContractError("Duplicate application settings") }
                settingsIndex[setting.id] = setting
            }
        }
        self.modules = modules; threads = threadIndex; settings = settingsIndex
    }
    public func requireThread(_ id: JSONText) throws -> AnyApplicationThreadPlugin {
        guard let result = threads[id] else { throw PluginContractError("Application thread type is not registered: \(id.string)") }; return result
    }
    public func requireSettings(_ id: JSONText) throws -> AnyApplicationSettingsPlugin {
        guard let result = settings[id] else { throw PluginContractError("Application settings are not registered: \(id.string)") }; return result
    }
}

@MainActor
private func validateApplicationScope(_ scope: ApplicationCapabilityScope, owner: JSONText,
                                      entry: ApplicationThreadRef, type: JSONText) throws {
    guard scope.pluginID == owner, scope.thread == entry, entry.typeID == type else {
        throw PluginContractError("Application capability scope does not match the current thread")
    }
}
