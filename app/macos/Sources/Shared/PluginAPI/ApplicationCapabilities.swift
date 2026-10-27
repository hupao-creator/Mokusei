import Foundation
import MokuseiCore
import SwiftUI

public enum ApplicationCapabilityPhase: String, Sendable { case projection, renderer }
public protocol ApplicationPhase { static var phase: ApplicationCapabilityPhase { get } }
public enum ApplicationProjectionPhase: ApplicationPhase { public static let phase = ApplicationCapabilityPhase.projection }
public enum ApplicationRendererPhase: ApplicationPhase { public static let phase = ApplicationCapabilityPhase.renderer }
public struct ApplicationCapabilityRequirement: Hashable, Sendable {
    public let id: JSONText
    public let apiVersion: Int
    public let phase: ApplicationCapabilityPhase
    public init(id: JSONText, apiVersion: Int = 1, phase: ApplicationCapabilityPhase) {
        self.id = id; self.apiVersion = apiVersion; self.phase = phase
    }
}
public struct ApplicationCapabilityKey<Value, Phase: ApplicationPhase>: Sendable {
    public let id: JSONText
    public let apiVersion: Int
    public init(_ id: JSONText, apiVersion: Int = 1) { self.id = id; self.apiVersion = apiVersion }
    public var requirement: ApplicationCapabilityRequirement { .init(id: id, apiVersion: apiVersion, phase: Phase.phase) }
}
public struct ApplicationCapabilityScope: Hashable, Sendable {
    public let pluginID: JSONText
    public let thread: ApplicationThreadRef?
    public init(pluginID: JSONText, thread: ApplicationThreadRef? = nil) { self.pluginID = pluginID; self.thread = thread }
}

/// Host composition erases a capability once, after binding its authority to scope.
@MainActor
public struct ApplicationCapabilityRegistration<Phase: ApplicationPhase> {
    fileprivate let id: JSONText
    fileprivate let apiVersion: Int
    fileprivate let value: Any
    public init<Value>(_ key: ApplicationCapabilityKey<Value, Phase>, value: Value) {
        id = key.id; apiVersion = key.apiVersion; self.value = value
    }
}
@MainActor
public final class ApplicationCapabilityAccess<Phase: ApplicationPhase> {
    public let scope: ApplicationCapabilityScope
    private let declarations: [JSONText: ApplicationCapabilityRequirement]
    private let registrations: [JSONText: ApplicationCapabilityRegistration<Phase>]
    public init(scope: ApplicationCapabilityScope, requires: [ApplicationCapabilityRequirement],
                registrations: [ApplicationCapabilityRegistration<Phase>]) throws {
        var declarations: [JSONText: ApplicationCapabilityRequirement] = [:]
        for item in requires where item.phase == Phase.phase {
            guard item.apiVersion > 0, declarations[item.id] == nil else { throw PluginContractError("Duplicate or invalid application capability requirement") }
            declarations[item.id] = item
        }
        var values: [JSONText: ApplicationCapabilityRegistration<Phase>] = [:]
        for item in registrations {
            guard values[item.id] == nil else { throw PluginContractError("Duplicate application capability registration") }
            values[item.id] = item
        }
        // Providers may be absent while a conversation is uninitialized.
        // Match the renderer contract: reject unavailable capability on require,
        // so a plugin can render its legitimate empty/initialize state first.
        self.scope = scope; self.declarations = declarations; self.registrations = values
    }
    /// Binding validation prevents a host from accidentally lending another
    /// contribution's declarations when dispatching this plugin.
    public func validateRequirements(_ requires: [ApplicationCapabilityRequirement]) throws {
        let expected = requires.filter { $0.phase == Phase.phase }
        guard Set(expected).count == expected.count,
              Set(expected) == Set(declarations.values) else {
            throw PluginContractError("Application capability declarations do not match the contribution")
        }
    }
    public func require<Value>(_ key: ApplicationCapabilityKey<Value, Phase>) throws -> Value {
        guard let declaration = declarations[key.id], declaration.apiVersion == key.apiVersion,
              let registration = registrations[key.id], registration.apiVersion == key.apiVersion,
              let value = registration.value as? Value else {
            throw PluginContractError("Undeclared or incompatible application capability: \(key.id.string)")
        }
        return value
    }
}

/// Opaque local wrapper retaining the selected owning-Harness snapshot.
/// It cannot be synthesized from JSON and does not expose a private overview value.
@MainActor
public struct ApplicationConversationCard {
    public let snapshot: HarnessOverviewSnapshot
    public init(snapshot: HarnessOverviewSnapshot) { self.snapshot = snapshot }
}
@MainActor
public struct ApplicationConversationProjection {
    public let projectOverview: (Int) throws -> HarnessOverviewProjection<ApplicationConversationCard>
    public init(projectOverview: @escaping (Int) throws -> HarnessOverviewProjection<ApplicationConversationCard>) {
        self.projectOverview = projectOverview
    }
}
@MainActor
public struct ApplicationConversationUI {
    private let workspaceBody: (HarnessReadingTarget?) -> AnyView
    private let cardBody: (ApplicationConversationCard, @escaping () -> Void) -> AnyView
    /// The host erases its native factories at this composition boundary only.
    public init<Workspace: View, Card: View>(workspace: @escaping (HarnessReadingTarget?) -> Workspace,
                                            card: @escaping (ApplicationConversationCard, @escaping () -> Void) -> Card) {
        workspaceBody = { AnyView(workspace($0)) }; cardBody = { value, open in AnyView(card(value, open)) }
    }
    public func workspace(readingTarget: HarnessReadingTarget?) -> AnyView { workspaceBody(readingTarget) }
    public func overviewCard(projection: ApplicationConversationCard, openThread: @escaping () -> Void) -> AnyView {
        cardBody(projection, openThread)
    }
}
@MainActor
public struct ApplicationThreadUserActions {
    public let setArchived: (Bool, JSONText, PluginLifetime) async throws -> Void
    public let initializeConversation: (JSONText, PluginLifetime) async throws -> Void
    public init(setArchived: @escaping (Bool, JSONText, PluginLifetime) async throws -> Void,
                initializeConversation: @escaping (JSONText, PluginLifetime) async throws -> Void) {
        self.setArchived = setArchived; self.initializeConversation = initializeConversation
    }
}
public struct ApplicationExecutionPresentation: Hashable, Sendable {
    public struct Harness: Hashable, Sendable {
        public let id: JSONText
        public let displayName: JSONText
        public let logoSource: String
        public init(id: JSONText, displayName: JSONText, logoSource: String) { self.id = id; self.displayName = displayName; self.logoSource = logoSource }
    }
    public let reference: ApplicationExecutionRef
    public let title: JSONText
    public let missing: Bool
    public let running: Bool
    public let harness: Harness?
    public let usage: HarnessExecutionTokenUsage?
    public init(reference: ApplicationExecutionRef, title: JSONText, missing: Bool, running: Bool,
                harness: Harness?, usage: HarnessExecutionTokenUsage?) {
        self.reference = reference; self.title = title; self.missing = missing; self.running = running
        self.harness = harness; self.usage = usage
    }
}
@MainActor
public struct ApplicationExecutionReferencesUI {
    public let read: ([ApplicationExecutionRef]) throws -> [ApplicationExecutionPresentation]
    /// The host returns cancellation for the same aggregate catalog subscription.
    public let subscribe: (@escaping () -> Void) -> () -> Void
    /// Renderer-only native factory; public reference metadata stays plain data.
    public let logo: (JSONText, CGFloat) throws -> AnyView
    public init(read: @escaping ([ApplicationExecutionRef]) throws -> [ApplicationExecutionPresentation],
                subscribe: @escaping (@escaping () -> Void) -> () -> Void,
                logo: @escaping (JSONText, CGFloat) throws -> AnyView) {
        self.read = read; self.subscribe = subscribe; self.logo = logo
    }
}
public struct ApplicationHTMLFailure: Sendable {
    public let thread: ApplicationThreadRef
    public let message: String
    public init(thread: ApplicationThreadRef, message: String) { self.thread = thread; self.message = message }
}
@MainActor
public struct ApplicationIsolatedHTML {
    private let body: (ApplicationHTMLSource, @escaping (ApplicationHTMLFailure) -> Void) -> AnyView
    public init<Surface: View>(surface: @escaping (ApplicationHTMLSource, @escaping (ApplicationHTMLFailure) -> Void) -> Surface) {
        body = { source, failure in AnyView(surface(source, failure)) }
    }
    public func surface(source: ApplicationHTMLSource, onFailure: @escaping (ApplicationHTMLFailure) -> Void) -> AnyView {
        body(source, onFailure)
    }
}
@MainActor
public struct ApplicationBackgroundConfigurationUI {
    private let body: (ApplicationBackgroundExecutionSettings, @escaping (ApplicationBackgroundExecutionSettings) -> Void) -> AnyView
    public init<Editor: View>(editor: @escaping (ApplicationBackgroundExecutionSettings, @escaping (ApplicationBackgroundExecutionSettings) -> Void) -> Editor) {
        body = { value, change in AnyView(editor(value, change)) }
    }
    public func editor(value: ApplicationBackgroundExecutionSettings, change: @escaping (ApplicationBackgroundExecutionSettings) -> Void) -> AnyView { body(value, change) }
}
public enum ApplicationCapabilities {
    public static let conversationUI = ApplicationCapabilityKey<ApplicationConversationUI, ApplicationRendererPhase>("mokusei.conversationUiCapability")
    public static let conversationProjection = ApplicationCapabilityKey<ApplicationConversationProjection, ApplicationProjectionPhase>("mokusei.conversationProjectionCapability")
    public static let threadUserActions = ApplicationCapabilityKey<ApplicationThreadUserActions, ApplicationRendererPhase>("mokusei.threadUserActionsCapability")
    public static let executionReferencesUI = ApplicationCapabilityKey<ApplicationExecutionReferencesUI, ApplicationRendererPhase>("mokusei.executionReferencesUiCapability")
    public static let isolatedHTML = ApplicationCapabilityKey<ApplicationIsolatedHTML, ApplicationRendererPhase>("mokusei.isolatedHtmlCapability")
    public static let backgroundConfigurationUI = ApplicationCapabilityKey<ApplicationBackgroundConfigurationUI, ApplicationRendererPhase>("mokusei.backgroundConfigurationUiCapability")
}
