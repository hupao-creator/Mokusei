import Foundation
import Observation
import MokuseiCore

public enum PluginResourceState<Value> {
    case loading
    case ready(Value)
    case error(String)
}

public struct HarnessContentFailure: Error, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public var errorDescription: String? { message }
    public init(code: String, message: String) { self.code = code; self.message = message }
}

/// Scoped resources are supplied by composition, not by a plugin's runtime client.
/// The host publishes only events for this handle and releases it when its view leaves.
@MainActor @Observable
public final class HarnessContentResource {
    public private(set) var state: PluginResourceState<JSONValue>
    public private(set) var isReleased = false
    public private(set) var failureCode: String?
    @ObservationIgnored private let retryAction: () async throws -> Void
    @ObservationIgnored private let releaseAction: () async -> Void
    @ObservationIgnored private var retryGeneration = 0
    @ObservationIgnored private var pendingRelease: Task<Void, Never>?
    @ObservationIgnored private var stateWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    public init(state: PluginResourceState<JSONValue> = .loading,
                retry: @escaping () async throws -> Void,
                release: @escaping () async -> Void) {
        self.state = state; retryAction = retry; releaseAction = release
    }
    public func publish(_ state: PluginResourceState<JSONValue>, code: String? = nil) {
        guard !isReleased else { return }
        self.state = state
        if case .error = state { failureCode = code } else { failureCode = nil }
        resumeStateWaiters()
    }
    /// Wait for the next settled state. Chunked detail reads use this to join the
    /// existing leased resource without polling or retaining a second value.
    public func waitForResult() async throws -> JSONValue {
        while true {
            try Task.checkCancellation()
            guard !isReleased else { throw PluginContractError("Content surface has been released") }
            switch state {
            case .ready(let value): return value
            case .error(let message):
                if let failureCode { throw HarnessContentFailure(code: failureCode, message: message) }
                throw PluginContractError(message)
            case .loading: break
            }
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if isReleased { continuation.resume() } else { stateWaiters[id] = continuation }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.resumeStateWaiter(id) }
            }
        }
    }
    private func resumeStateWaiter(_ id: UUID) {
        stateWaiters.removeValue(forKey: id)?.resume()
    }
    private func resumeStateWaiters() {
        let waiters = stateWaiters.values
        stateWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    public func retry() async throws {
        guard !isReleased else { throw PluginContractError("Content surface has been released") }
        retryGeneration += 1
        let generation = retryGeneration
        state = .loading
        failureCode = nil
        resumeStateWaiters()
        do { try await retryAction() }
        catch {
            if !isReleased, retryGeneration == generation {
                state = .error(error.localizedDescription)
                failureCode = (error as? RuntimeError)?.code ?? (error as? HarnessContentFailure)?.code
                resumeStateWaiters()
            }
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
        resumeStateWaiters()
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

public struct HarnessDetailSelection: Hashable, Sendable {
    public let execution: JSONText
    public let items: [JSONText]
    public let truncated: Bool
    public init(execution: JSONText, items: [JSONText]) {
        self.execution = execution
        self.truncated = items.count > 1024
        self.items = Array(items.prefix(1024))
    }
}
public struct HarnessDetailBodyReference: Hashable, Sendable {
    public let execution: JSONText
    public let item: JSONText
    public let slot: JSONText
    public let cursor: String
    public init(execution: JSONText, item: JSONText, slot: JSONText, cursor: String = "") {
        self.execution = execution; self.item = item; self.slot = slot; self.cursor = cursor
    }
}
public enum HarnessContentScope: Hashable, Sendable {
    case thread
    case row(JSONText)
    /// Count-only Agent reading. Target is the owning Harness's explicit
    /// message selector, retained only when the reader requested that reply.
    case reading(JSONText, target: JSONValue?)
    case execution(JSONText)
    case detail(HarnessDetailSelection)
    case body(HarnessDetailBodyReference)
}
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
    public let openExternal: ((URL) -> Void)?
    /// Remaining Runtime content slots for bounded detail body leases.
    public let detailBodyCapacity: (@MainActor () async -> Int)?
    public init(content: HarnessContentMode, presentation: HarnessConversationPresentation,
                contentResource: @escaping (HarnessContentScope) -> HarnessContentResource,
                onIndexChange: @escaping (ThreadConversationIndex) -> Void,
                previewAttachment: ((JSONText) async throws -> Data)? = nil,
                resolveMedia: (@Sendable (URL) async throws -> Data)? = nil,
                openExternal: ((URL) -> Void)? = nil,
                detailBodyCapacity: (@MainActor () async -> Int)? = nil) {
        self.content = content; self.presentation = presentation
        self.contentResource = contentResource; self.onIndexChange = onIndexChange
        self.previewAttachment = previewAttachment; self.resolveMedia = resolveMedia
        self.openExternal = openExternal; self.detailBodyCapacity = detailBodyCapacity
    }
    /// Re-enters the same owning Harness for a lazily materialized row.
    public func row(_ id: JSONText) -> Self {
        Self(content: .row(id), presentation: presentation,
             contentResource: contentResource, onIndexChange: onIndexChange,
             previewAttachment: previewAttachment, resolveMedia: resolveMedia,
             openExternal: openExternal, detailBodyCapacity: detailBodyCapacity)
    }
}
