import Foundation
import Observation
import MokuseiCore

public enum PluginResourceState<Value> {
    case loading
    case ready(Value)
    case error(String)
}

/// Scoped resources are supplied by composition, not by a plugin's runtime client.
/// The host publishes only events for this handle and releases it when its view leaves.
@MainActor @Observable
public final class HarnessContentResource {
    public private(set) var state: PluginResourceState<JSONValue>
    public private(set) var isReleased = false
    @ObservationIgnored private let retryAction: () async throws -> Void
    @ObservationIgnored private let releaseAction: () async -> Void
    @ObservationIgnored private var retryGeneration = 0
    @ObservationIgnored private var pendingRelease: Task<Void, Never>?

    public init(state: PluginResourceState<JSONValue> = .loading,
                retry: @escaping () async throws -> Void,
                release: @escaping () async -> Void) {
        self.state = state; retryAction = retry; releaseAction = release
    }
    public func publish(_ state: PluginResourceState<JSONValue>) {
        guard !isReleased else { return }
        self.state = state
    }
    public func retry() async throws {
        guard !isReleased else { throw PluginContractError("Content surface has been released") }
        retryGeneration += 1
        let generation = retryGeneration
        state = .loading
        do { try await retryAction() }
        catch {
            if !isReleased, retryGeneration == generation { state = .error(error.localizedDescription) }
            throw error
        }
    }
    /// Revoke synchronously from onDisappear before scheduling asynchronous wire
    /// cleanup, so a reappearing row cannot reacquire this departing handle.
    public func beginRelease() {
        guard !isReleased else { return }
        isReleased = true
        retryGeneration += 1
        state = .loading // Drop retained private history immediately.
        pendingRelease = Task { [weak self, releaseAction] in
            await releaseAction()
            self?.pendingRelease = nil
        }
    }
    /// Concurrent callers join the same cleanup, including beginRelease callers.
    public func release() async {
        beginRelease()
        await pendingRelease?.value
    }
}

@MainActor @Observable
public final class HarnessSettingsResource<Value> {
    public private(set) var state: PluginResourceState<Value>
    @ObservationIgnored private let reloadAction: (_ refresh: Bool) async throws -> Value
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pending: Task<Void, Error>?

    public init(state: PluginResourceState<Value> = .loading,
                reload: @escaping (_ refresh: Bool) async throws -> Value) {
        self.state = state; reloadAction = reload
    }
    /// Calls made while loading coalesce; an explicit refresh supersedes older reads.
    public func reload(refresh: Bool = false) async throws {
        if let pending, !refresh { return try await pending.value }
        generation += 1
        let current = generation
        if case .ready = state {} else { state = .loading }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                let value = try await reloadAction(refresh)
                try Task.checkCancellation()
                if generation == current { state = .ready(value) }
            } catch {
                if generation == current { state = .error(error.localizedDescription) }
                throw error
            }
        }
        pending = task
        do {
            try await task.value
            if generation == current { pending = nil }
        } catch {
            if generation == current { pending = nil }
            throw error
        }
    }
    public func invalidate(keepingValue: Bool = false) {
        generation += 1; pending?.cancel(); pending = nil
        if !keepingValue { state = .loading }
    }
}

public enum HarnessContentScope: Hashable, Sendable { case thread, row(JSONText), execution(JSONText) }
public enum HarnessContentMode: Hashable, Sendable { case materialized, manifest, row(JSONText) }
public enum HarnessConversationPresentation: Hashable, Sendable {
    case main(excludedExecutionIDs: [JSONText])
    case execution(JSONText)
}

@MainActor
public struct HarnessRenderContext {
    public let content: HarnessContentMode
    public let presentation: HarnessConversationPresentation
    public let contentResource: (HarnessContentScope) -> HarnessContentResource
    public let onIndexChange: (ThreadConversationIndex) -> Void
    public let previewAttachment: ((JSONText) async throws -> Data)?
    public let resolveMedia: (@Sendable (URL) async throws -> Data)?
    public init(content: HarnessContentMode, presentation: HarnessConversationPresentation,
                contentResource: @escaping (HarnessContentScope) -> HarnessContentResource,
                onIndexChange: @escaping (ThreadConversationIndex) -> Void,
                previewAttachment: ((JSONText) async throws -> Data)? = nil,
                resolveMedia: (@Sendable (URL) async throws -> Data)? = nil) {
        self.content = content; self.presentation = presentation
        self.contentResource = contentResource; self.onIndexChange = onIndexChange
        self.previewAttachment = previewAttachment; self.resolveMedia = resolveMedia
    }
    /// Re-enters the same owning Harness for a lazily materialized row.
    public func row(_ id: JSONText) -> Self {
        Self(content: .row(id), presentation: presentation,
             contentResource: contentResource, onIndexChange: onIndexChange,
             previewAttachment: previewAttachment, resolveMedia: resolveMedia)
    }
}
