import Foundation
import Observation
import MokuseiCore
import SwiftUI

public struct SidecardPluginDescriptor: Hashable, Sendable {
    public let id: JSONText
    public let displayName: JSONText
    public let apiVersion = 1
    public init(id: JSONText, displayName: JSONText) {
        self.id = id; self.displayName = displayName
    }
}

public struct SidecardSendReceipt: Hashable, Sendable {
    public let executionID: JSONText
    public init(executionID: JSONText) { self.executionID = executionID }
}

/// Semantic user requests are routed by the host independently of plugin IDs.
/// Numeric request IDs retain JavaScript number semantics, including fractions.
public struct SidecardIntent: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case activate
        case openURL(JSONText)
        case compose(initialDraft: JSONText?)
        case sendStarted(requestID: Double)
        case sendAccepted(requestID: Double, receipt: SidecardSendReceipt)
        case sendFailed(requestID: Double)
    }
    public let kind: Kind

    public init(_ kind: Kind) throws {
        switch kind {
        case let .sendStarted(requestID), let .sendAccepted(requestID, _), let .sendFailed(requestID):
            guard requestID.isFinite else { throw PluginContractError("Sidecard request ID must be finite") }
        case .activate, .openURL, .compose: break
        }
        self.kind = kind
    }
}

/// Complete transcript snapshots use the source identity, never generated UUIDs
/// or text-derived identity. createdAt is the source timestamp in milliseconds.
public struct VoiceTranscriptMessage: Hashable, Sendable, Identifiable {
    public enum Role: String, Hashable, Sendable { case user, assistant }
    public let id: JSONText
    public let sessionID: JSONText
    public let role: Role
    public let text: JSONText
    public let complete: Bool
    public let createdAt: Double

    public init(id: JSONText, sessionID: JSONText, role: Role, text: JSONText,
                complete: Bool, createdAt: Double) throws {
        guard createdAt.isFinite else { throw PluginContractError("Voice transcript timestamp must be finite") }
        self.id = id; self.sessionID = sessionID; self.role = role
        self.text = text; self.complete = complete; self.createdAt = createdAt
    }
}

public struct SidecardVoiceState: Hashable, Sendable {
    public enum Phase: String, Hashable, Sendable {
        case closed, preparing, connecting, listening, stopping, failed
    }
    public let phase: Phase
    public let supported: Bool
    public let available: Bool
    public let loading: Bool
    public let muted: Bool
    public let error: JSONText
    public let messages: [VoiceTranscriptMessage]

    public init(phase: Phase, supported: Bool, available: Bool, loading: Bool,
                muted: Bool, error: JSONText, messages: [VoiceTranscriptMessage]) {
        self.phase = phase; self.supported = supported; self.available = available
        self.loading = loading; self.muted = muted; self.error = error; self.messages = messages
    }
}

/// A read-only fork of this thread's voice context. These actions never send
/// agent input to the source thread. The host publishes canonical snapshots.
@MainActor @Observable
public final class SidecardVoiceCapability {
    public private(set) var state: SidecardVoiceState
    @ObservationIgnored private let startAction: () async throws -> Void
    @ObservationIgnored private let stopAction: () async throws -> Void
    @ObservationIgnored private let toggleMuteAction: () -> Void
    @ObservationIgnored private let refreshAction: () async throws -> Void
    @ObservationIgnored private var listeners: [UUID: () -> Void] = [:]

    public init(state: SidecardVoiceState, start: @escaping () async throws -> Void,
                stop: @escaping () async throws -> Void, toggleMute: @escaping () -> Void,
                refresh: @escaping () async throws -> Void) {
        self.state = state; startAction = start; stopAction = stop
        toggleMuteAction = toggleMute; refreshAction = refresh
    }
    public func snapshot() -> SidecardVoiceState { state }
    public func publish(_ state: SidecardVoiceState) {
        self.state = state
        for (id, listener) in Array(listeners) where listeners[id] != nil { listener() }
    }
    /// Bind subscriptions to the presentation lifetime to release observers when
    /// its thread/plugin owner disappears. Cancellation is safe to repeat.
    @discardableResult
    public func subscribe(lifetime: PluginLifetime, _ listener: @escaping () -> Void) -> () -> Void {
        guard !lifetime.isCancelled else { return {} }
        let id = UUID()
        listeners[id] = listener
        let lifetimeID = lifetime.onCancel { [weak self] in self?.listeners[id] = nil }
        return { [weak self, weak lifetime] in
            self?.listeners[id] = nil
            lifetime?.removeHandler(lifetimeID)
        }
    }
    public func start() async throws { try await startAction() }
    public func stop() async throws { try await stopAction() }
    public func toggleMute() { toggleMuteAction() }
    public func refresh() async throws { try await refreshAction() }
}

public struct SidecardStagedAttachment: Hashable, Sendable, Identifiable {
    public let id: JSONText
    public init(id: JSONText) { self.id = id }
}

/// The host owns the outer frame, sizing, transitions and suppression. A plugin
/// returns native content and reads these flags without constructing a host frame.
@MainActor
public struct SidecardContext {
    /// Drafts are persisted beneath this local runtime profile.
    public let draftStorageDirectory: URL?
    public let thread: HarnessThread
    public let conversationIndex: ThreadConversationIndex?
    public let actions: HarnessThreadActions
    /// Host localization for display strings, shared with its other native views.
    public let translate: (String) -> String
    public let readingTarget: HarnessReadingTarget?
    public let executionDisabled: Bool
    public let expanded: Bool
    public let transitioning: Bool
    /// Native views must not paint while the host is covered, moving or resizing.
    public let suppressed: Bool
    /// Re-enters the owning Harness through the host composition boundary.
    public let conversation: (JSONText, HarnessReadingTarget?) -> AnyView
    public let voice: SidecardVoiceCapability?
    public let open: () -> Int
    public let close: () -> Void
    public let selectionRevision: () -> Int
    private let observeIntent: (@escaping (SidecardIntent) -> Bool) -> () -> Void
    /// The host validates this lossless value against the runtime PublicAgentInput
    /// schema before accepting it. Invalid input fails; no field is defaulted.
    public let send: (JSONValue) async throws -> SidecardSendReceipt
    public let attachmentImport: SidecardAttachmentImport?
    private let stage: ([URL]) async throws -> [SidecardStagedAttachment]
    public let discardAttachments: ([JSONText]) async throws -> Void
    public let backToOverview: () -> Void

    public init(thread: HarnessThread, conversationIndex: ThreadConversationIndex?,
                actions: HarnessThreadActions, readingTarget: HarnessReadingTarget?,
                executionDisabled: Bool, expanded: Bool, transitioning: Bool, suppressed: Bool,
                conversation: @escaping (JSONText, HarnessReadingTarget?) -> AnyView,
                voice: SidecardVoiceCapability?, open: @escaping () -> Int,
                close: @escaping () -> Void, selectionRevision: @escaping () -> Int,
                onIntent: @escaping (@escaping (SidecardIntent) -> Bool) -> () -> Void,
                send: @escaping (JSONValue) async throws -> SidecardSendReceipt,
                stageAttachments: @escaping ([URL]) async throws -> [SidecardStagedAttachment],
                discardAttachments: @escaping ([JSONText]) async throws -> Void,
                backToOverview: @escaping () -> Void, translate: @escaping (String) -> String = { $0 },
                draftStorageDirectory: URL? = nil, attachmentImport: SidecardAttachmentImport? = nil) {
        self.thread = thread; self.conversationIndex = conversationIndex; self.actions = actions
        self.attachmentImport = attachmentImport
        self.draftStorageDirectory = draftStorageDirectory
        self.translate = translate
        self.readingTarget = readingTarget; self.executionDisabled = executionDisabled
        self.expanded = expanded; self.transitioning = transitioning; self.suppressed = suppressed
        self.conversation = conversation; self.voice = voice
        self.open = open; self.close = close
        self.selectionRevision = selectionRevision; observeIntent = onIntent; self.send = send
        stage = stageAttachments; self.discardAttachments = discardAttachments; self.backToOverview = backToOverview
    }
    @discardableResult
    public func onIntent(lifetime: PluginLifetime, _ handler: @escaping (SidecardIntent) -> Bool) -> () -> Void {
        guard !lifetime.isCancelled else { return {} }
        let subscription = SidecardCancellation()
        subscription.install(observeIntent { [weak subscription, weak lifetime] intent in
            guard let subscription, !subscription.isCancelled, let lifetime, !lifetime.isCancelled else { return false }
            return handler(intent)
        })
        let lifetimeID = lifetime.onCancel { subscription.cancel() }
        return { [weak lifetime] in
            subscription.cancel()
            lifetime?.removeHandler(lifetimeID)
        }
    }
    public func stageAttachments(_ files: [URL]) async throws -> [SidecardStagedAttachment] {
        guard files.allSatisfy(\.isFileURL) else {
            throw PluginContractError("Sidecard attachments must be local file URLs")
        }
        return try await stage(files)
    }
}

@MainActor
private final class SidecardCancellation {
    private(set) var isCancelled = false
    private var action: (() -> Void)?
    init(_ action: (() -> Void)? = nil) { self.action = action }
    func install(_ action: @escaping () -> Void) {
        if isCancelled { action() } else { self.action = action }
    }
    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        let current = action
        action = nil
        current?()
    }
}

public enum SidecardIndicator: String, Hashable, Sendable { case active, attention }

@MainActor
public struct SidecardView<Content: View> {
    public let available: Bool
    public let label: JSONText
    public let indicator: SidecardIndicator?
    public let acceptsInput: Bool?
    /// Preferred fraction of available horizontal width; the host clamps it.
    public let preferredWidth: Double
    /// Some activities preserve reading focus until the user enters a control.
    public let focusContentOnOpen: Bool
    public let excludeExecutionID: JSONText?
    public let content: Content

    public init(available: Bool, label: JSONText, indicator: SidecardIndicator? = nil,
                acceptsInput: Bool? = nil, preferredWidth: Double, focusContentOnOpen: Bool = true,
                excludeExecutionID: JSONText? = nil,
                @ViewBuilder content: () -> Content) throws {
        guard preferredWidth.isFinite else { throw PluginContractError("Sidecard preferred width must be finite") }
        self.available = available; self.label = label; self.indicator = indicator
        self.acceptsInput = acceptsInput; self.preferredWidth = preferredWidth
        self.focusContentOnOpen = focusContentOnOpen
        self.excludeExecutionID = excludeExecutionID; self.content = content()
    }
}

/// Statically linked native plugin. makePresentation runs once for each live
/// thread/plugin session; metadata and content may react to that observable owner.
@MainActor
public protocol SidecardPlugin {
    associatedtype Presentation: AnyObject & Observable
    associatedtype Content: View
    associatedtype Icon: View
    var descriptor: SidecardPluginDescriptor { get }
    @ViewBuilder var icon: Icon { get }
    func makePresentation(context: SidecardContext, lifetime: PluginLifetime) throws -> Presentation
    /// Called synchronously before the host reads metadata. Reconcile context in
    /// the owner here; rendering content must not mutate observable state.
    func updatePresentation(_ presentation: Presentation, context: SidecardContext) throws
    func sidecard(context: SidecardContext, presentation: Presentation) throws -> SidecardView<Content>
}

extension SidecardPlugin {
    public func updatePresentation(_ presentation: Presentation, context: SidecardContext) throws {}
}

/// The host retains this stable owner until the thread/plugin surface is removed.
/// Updating context or replacing its native scope never resets the plugin draft.
@MainActor @Observable
public final class SidecardSession {
    public let pluginID: JSONText
    public let threadID: JSONText
    public private(set) var context: SidecardContext
    public private(set) var isReleased = false
    @ObservationIgnored private let lifetime: PluginLifetime
    @ObservationIgnored private var updatePresentation: ((SidecardContext) throws -> Void)?
    @ObservationIgnored private var render: ((SidecardContext) throws -> SidecardView<AnyView>)?

    fileprivate init(pluginID: JSONText, context: SidecardContext, lifetime: PluginLifetime,
                     updatePresentation: @escaping (SidecardContext) throws -> Void,
                     render: @escaping (SidecardContext) throws -> SidecardView<AnyView>) {
        self.pluginID = pluginID; threadID = context.thread.id; self.context = context
        self.lifetime = lifetime; self.updatePresentation = updatePresentation; self.render = render
    }
    public func update(context: SidecardContext) throws {
        try checkActive()
        guard context.thread.id == threadID else { throw PluginContractError("Sidecard session belongs to a different thread") }
        try updatePresentation?(context)
        self.context = context
    }
    public func view() throws -> SidecardView<AnyView> {
        try checkActive()
        guard let render else { throw PluginContractError("Sidecard presentation has been released") }
        return try render(context)
    }
    public func release() {
        guard !isReleased else { return }
        isReleased = true
        lifetime.cancel()
        updatePresentation = nil
        render = nil
    }
    private func checkActive() throws {
        guard !isReleased else { throw PluginContractError("Sidecard session has been released") }
    }
}

/// Only this heterogeneous registry boundary erases the plugin's native views
/// and observable presentation type. The frame remains entirely host-owned.
@MainActor
public final class AnySidecardPlugin {
    public let descriptor: SidecardPluginDescriptor
    public let icon: AnyView
    private let create: (SidecardContext) throws -> SidecardSession

    public init<P: SidecardPlugin>(_ plugin: P) {
        descriptor = plugin.descriptor
        icon = AnyView(plugin.icon)
        create = { context in
            let lifetime = PluginLifetime()
            do {
                let presentation = try plugin.makePresentation(context: context, lifetime: lifetime)
                try plugin.updatePresentation(presentation, context: context)
                return SidecardSession(pluginID: plugin.descriptor.id, context: context, lifetime: lifetime,
                    updatePresentation: { try plugin.updatePresentation(presentation, context: $0) }) { context in
                    let output = try plugin.sidecard(context: context, presentation: presentation)
                    return try SidecardView(available: output.available, label: output.label,
                        indicator: output.indicator, acceptsInput: output.acceptsInput,
                        preferredWidth: output.preferredWidth, focusContentOnOpen: output.focusContentOnOpen,
                        excludeExecutionID: output.excludeExecutionID) {
                        AnyView(output.content)
                    }
                }
            } catch {
                lifetime.cancel()
                throw error
            }
        }
    }
    public func makeSession(context: SidecardContext) throws -> SidecardSession { try create(context) }
}

@MainActor
public final class SidecardPluginRegistry {
    public let modules: [AnySidecardPlugin]
    private let byID: [JSONText: AnySidecardPlugin]

    public init(_ modules: [AnySidecardPlugin]) throws {
        var index: [JSONText: AnySidecardPlugin] = [:]
        for module in modules {
            guard !module.descriptor.id.codeUnits.isEmpty, index[module.descriptor.id] == nil else {
                throw PluginContractError("Duplicate or empty Sidecard module identity")
            }
            index[module.descriptor.id] = module
        }
        self.modules = modules; byID = index
    }
    public func require(_ id: JSONText) throws -> AnySidecardPlugin {
        guard let module = byID[id] else { throw PluginContractError("Sidecard is not registered: \(id.string)") }
        return module
    }
}
