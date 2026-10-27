import Foundation
import MokuseiCore
import SwiftUI

public struct HarnessThreadCapabilities: Hashable, Sendable {
    public enum ToolMode: String, Hashable, Sendable { case extend, exclusive }
    public let instructions: Bool
    public let threadContext: Bool
    public let sendContext: Bool
    public let toolModes: [ToolMode]
    public init(instructions: Bool, threadContext: Bool, sendContext: Bool, toolModes: [ToolMode]) {
        self.instructions = instructions; self.threadContext = threadContext
        self.sendContext = sendContext; self.toolModes = toolModes
    }
    public var canHostMoku: Bool {
        instructions && threadContext && sendContext && toolModes.contains(.exclusive)
    }
}

public struct HarnessPluginDescriptor: Hashable, Sendable {
    public let id: JSONText
    public let displayName: JSONText
    public let threadCapabilities: HarnessThreadCapabilities
    public init(id: JSONText, displayName: JSONText, threadCapabilities: HarnessThreadCapabilities) {
        self.id = id; self.displayName = displayName; self.threadCapabilities = threadCapabilities
    }
}

public struct HarnessThreadInput: Hashable, Sendable {
    public let thread: HarnessThread
    public let readingTarget: HarnessReadingTarget?
    public let git: HarnessGitStatus?
    public init(thread: HarnessThread, readingTarget: HarnessReadingTarget? = nil, git: HarnessGitStatus? = nil) {
        self.thread = thread; self.readingTarget = readingTarget; self.git = git
    }
}

@MainActor
public struct HarnessThreadActions {
    public let interrupt: () async throws -> Void
    public let respond: (HarnessRespondRequest) async throws -> Void
    public let invokeHarnessExtension: (JSONText, JSONValue) async throws -> JSONValue
    public let forkThread: (JSONValue) async throws -> JSONText
    public let openExternal: (JSONText) async throws -> Void
    public let openFollowUp: (JSONText) -> Void
    public init(interrupt: @escaping () async throws -> Void,
                respond: @escaping (HarnessRespondRequest) async throws -> Void,
                invokeHarnessExtension: @escaping (JSONText, JSONValue) async throws -> JSONValue,
                forkThread: @escaping (JSONValue) async throws -> JSONText,
                openExternal: @escaping (JSONText) async throws -> Void,
                openFollowUp: @escaping (JSONText) -> Void) {
        self.interrupt = interrupt; self.respond = respond
        self.invokeHarnessExtension = invokeHarnessExtension; self.forkThread = forkThread
        self.openExternal = openExternal; self.openFollowUp = openFollowUp
    }
}

public struct HarnessOverviewFootprint: Hashable, Sendable {
    public let columns: Int
    public let rows: Int
    public init(columns: Int, rows: Int) { self.columns = columns; self.rows = rows }
}
public struct HarnessOverviewEnvelope: Hashable, Sendable {
    public let footprint: HarnessOverviewFootprint
    public let structureKey: JSONText
    public let excerpt: JSONText
    public init(footprint: HarnessOverviewFootprint, structureKey: JSONText, excerpt: JSONText) {
        self.footprint = footprint; self.structureKey = structureKey; self.excerpt = excerpt
    }
}
public struct HarnessOverviewProjection<Overview> {
    public let envelope: HarnessOverviewEnvelope
    public let view: Overview
    public init(envelope: HarnessOverviewEnvelope, view: Overview) { self.envelope = envelope; self.view = view }
    public init(footprint: HarnessOverviewFootprint, structureKey: JSONText, excerpt: JSONText, view: Overview) {
        self.init(envelope: HarnessOverviewEnvelope(footprint: footprint, structureKey: structureKey, excerpt: excerpt), view: view)
    }
}
public struct HarnessExecutionTokenUsage: Hashable, Sendable {
    public let value: JSONText
    public let count: Double
    public let suffix: JSONText
    public init(value: JSONText, count: Double, suffix: JSONText) {
        self.value = value; self.count = count; self.suffix = suffix
    }
}

public enum HarnessSettingsSection: String, Sendable { case cli, thread }
@MainActor
public struct HarnessSettingsHost {
    public let cwd: JSONText
    public let invokeExtension: (JSONText, JSONValue) async throws -> JSONValue
    public let openExternal: (JSONText) async throws -> Void
    public init(cwd: JSONText, invokeExtension: @escaping (JSONText, JSONValue) async throws -> JSONValue,
                openExternal: @escaping (JSONText) async throws -> Void) {
        self.cwd = cwd; self.invokeExtension = invokeExtension; self.openExternal = openExternal
    }
}
@MainActor
public struct HarnessSettingsProps<Value, Presentation> {
    public let section: HarnessSettingsSection
    public let executionSnapshot: Bool
    public let settingsFormPage: Bool
    public let value: Value
    public let resource: HarnessSettingsResource<Presentation>
    public let host: HarnessSettingsHost?
    public let change: (Value) -> Void
    public init(section: HarnessSettingsSection, executionSnapshot: Bool = false, settingsFormPage: Bool = false,
                value: Value, resource: HarnessSettingsResource<Presentation>, host: HarnessSettingsHost?,
                change: @escaping (Value) -> Void) {
        self.section = section; self.executionSnapshot = executionSnapshot; self.settingsFormPage = settingsFormPage
        self.value = value; self.resource = resource; self.host = host; self.change = change
    }
}

/// Statically linked Swift plugin. Its native history and overview representation
/// are private associated types; Core cannot inspect them or invent a timeline.
@MainActor
public protocol HarnessPlugin {
    associatedtype Overview
    associatedtype Logo: View
    associatedtype ThreadSettingsUpdate
    associatedtype HarnessSettings
    associatedtype SettingsPresentation
    associatedtype ThreadBody: View
    associatedtype OverviewBody: View
    associatedtype ThreadSettingsBody: View
    associatedtype HarnessSettingsBody: View
    var descriptor: HarnessPluginDescriptor { get }
    /// Compatibility/source metadata only. Visible host marks use logo(size:).
    var logoSource: String { get }
    @ViewBuilder func logo(size: CGFloat) -> Logo
    var translations: HarnessTranslationCatalog { get }
    var threadSettingsCodec: PluginValueCodec<ThreadSettingsUpdate> { get }
    var harnessSettingsCodec: PluginValueCodec<HarnessSettings> { get }
    var settingsPresentationCodec: PluginValueCodec<SettingsPresentation> { get }
    func projectOverview(input: HarnessThreadInput, availableColumns: Int) throws -> HarnessOverviewProjection<Overview>
    func executionTokenUsage(thread: HarnessThread, executionID: JSONText) throws -> HarnessExecutionTokenUsage?
    func projectMokuDock(input: HarnessThreadInput) throws -> HarnessMokuPresentation?
    @ViewBuilder func threadView(input: HarnessThreadInput, actions: HarnessThreadActions,
                                 context: HarnessRenderContext) -> ThreadBody
    @ViewBuilder func overviewCard(input: HarnessThreadInput, projection: Overview,
                                   actions: HarnessThreadActions, openThread: @escaping () -> Void) -> OverviewBody
    @ViewBuilder func threadSettings(input: HarnessThreadInput, resource: HarnessSettingsResource<SettingsPresentation>,
                                     update: @escaping (ThreadSettingsUpdate) async throws -> Void) -> ThreadSettingsBody
    @ViewBuilder func harnessSettings(props: HarnessSettingsProps<HarnessSettings, SettingsPresentation>) -> HarnessSettingsBody
}

extension HarnessPlugin {
    public var translations: HarnessTranslationCatalog { [:] }
    public func executionTokenUsage(thread: HarnessThread, executionID: JSONText) throws -> HarnessExecutionTokenUsage? { nil }
    public func projectMokuDock(input: HarnessThreadInput) throws -> HarnessMokuPresentation? { nil }
}
