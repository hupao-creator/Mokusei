import Foundation
import Observation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

/// One visible conversation owns its manifest and visible row subscriptions.
/// Main and sidecard execution surfaces can coexist without sharing lifetimes.
@MainActor @Observable
public final class NativeHarnessThreadSurface {
    public let id = UUID()
    public let threadID: JSONText
    public let harnessID: JSONText
    public private(set) var input: HarnessThreadInput
    public private(set) var presentation: HarnessConversationPresentation
    public private(set) var isReleased = false
    @ObservationIgnored private let host: NativeHarnessHost
    @ObservationIgnored private let plugin: AnyHarnessPlugin
    @ObservationIgnored private let source: NativeHarnessConversationSource?
    @ObservationIgnored private var onIndexChange: (ThreadConversationIndex) -> Void
    @ObservationIgnored private var routes: NativeHarnessThreadRoutes?
    @ObservationIgnored private var lastIndex: ThreadConversationIndex?
    private(set) var performanceOperation: UInt64?
    @ObservationIgnored private var performanceParent: UInt64?
    @ObservationIgnored private var performanceGeneration: UUID?

    func bindPerformance(parent: UInt64?) {
        guard performanceParent != parent || performanceGeneration != NativePerformance.recordingID || performanceOperation == nil else { return }
        performanceParent = parent; performanceGeneration = NativePerformance.recordingID
        let execution: Bool
        if case .execution = presentation { execution = true } else { execution = false }
        performanceOperation = NativePerformance.makeSurfaceContext(parent: parent, execution: execution)
    }
    @ObservationIgnored private let materialization = NativeThreadMaterializationCache()
    @ObservationIgnored private var resources: [HarnessContentScope: (id: String, resource: HarnessContentResource)] = [:]

    init(host: NativeHarnessHost, plugin: AnyHarnessPlugin, input: HarnessThreadInput,
         presentation: HarnessConversationPresentation, source: NativeHarnessConversationSource?, routes: NativeHarnessThreadRoutes?,
         onIndexChange: @escaping (ThreadConversationIndex) -> Void) {
        self.host = host; self.plugin = plugin; self.input = input; self.presentation = presentation
        self.onIndexChange = onIndexChange; threadID = input.thread.id; harnessID = input.thread.harnessID
        self.routes = routes
        self.source = source
    }

    public func update(input: HarnessThreadInput, presentation: HarnessConversationPresentation,
                       routes: NativeHarnessThreadRoutes? = nil,
                       onIndexChange: ((ThreadConversationIndex) -> Void)? = nil) throws {
        try checkLifetime()
        guard input.thread.id == threadID, input.thread.harnessID == harnessID else {
            throw PluginContractError("A conversation surface cannot change its owning thread or Harness")
        }
        self.input = input; self.presentation = presentation; self.routes = routes
        if let onIndexChange { self.onIndexChange = onIndexChange }
    }

    public var actions: HarnessThreadActions {
        host.boundActions(threadID: threadID, harnessID: harnessID, observedCancellationID: input.thread.cancellationID,
                          source: source, routes: { [routes] in routes }) { [weak self] in
            guard let self else { throw CancellationError() }; try checkLifetime()
        }
    }

    public func view() -> AnyView { AnyView(NativeHarnessContentView(surface: self).id(id)) }

    public func contentResource(_ scope: HarnessContentScope) -> HarnessContentResource {
        if let entry = resources[scope], !entry.resource.isReleased { return entry.resource }
        guard !isReleased else {
            return HarnessContentResource(state: .error("This conversation surface has been released"),
                retry: { throw CancellationError() }, release: {})
        }
        let subscriptionID = UUID().uuidString.lowercased()
        let runtimeScope: RuntimeContentScope
        switch scope {
        case .thread: runtimeScope = .thread
        case .row(let key): runtimeScope = .turn(key: key)
        case .execution(let key): runtimeScope = .execution(key: key)
        }
        let client = host.client
        let threadID = threadID
        let resource = HarnessContentResource(retry: { [weak self] in
            guard let self else { throw CancellationError() }
            try checkLifetime()
            guard let current = resources[scope], current.id == subscriptionID, !current.resource.isReleased else { throw CancellationError() }
            _ = try host.authoritativeThread(threadID: threadID, harnessID: harnessID, source: source)
            do { try await client.retryThreadContent(subscriptionID) }
            catch let error as RuntimeError where error.code == "CONTENT_UNAVAILABLE" {
                try await client.subscribeThreadContent(threadId: threadID, scope: runtimeScope, subscriptionId: subscriptionID,
                    performanceContext: performanceOperation)
            }
            if self.resources[scope]?.id != subscriptionID { await client.releaseThreadContent(subscriptionID) }
        }, release: { [weak self, weak host] in
            host?.unregisterResource(subscriptionID)
            if self?.resources[scope]?.id == subscriptionID { self?.resources[scope] = nil }
            await client.releaseThreadContent(subscriptionID)
        })
        resources[scope] = (subscriptionID, resource)
        host.register(resource, id: subscriptionID)
        Task { @MainActor [weak self, weak resource] in
            guard let self, let resource else { return }
            do {
                try checkLifetime()
                guard !resource.isReleased, resources[scope]?.id == subscriptionID else { throw CancellationError() }
                _ = try host.authoritativeThread(threadID: threadID, harnessID: harnessID, source: source)
                try await client.subscribeThreadContent(threadId: threadID, scope: runtimeScope, subscriptionId: subscriptionID,
                    performanceContext: performanceOperation)
                if isReleased || resources[scope]?.id != subscriptionID { await client.releaseThreadContent(subscriptionID) }
            } catch {
                if !resource.isReleased { resource.publish(.error(error.localizedDescription)) }
            }
        }
        return resource
    }

    func render(_ state: JSONValue) throws -> AnyView {
        let measurement = NativePerformance.begin(.harnessRender, context: performanceOperation)
        do {
            try checkLifetime()
            _ = try host.authoritativeThread(threadID: threadID, harnessID: harnessID, source: source)
            let materialized = HarnessThreadInput(thread: try materialization.thread(input.thread, content: state), readingTarget: input.readingTarget)
            let context = HarnessRenderContext(content: .manifest, presentation: presentation,
                contentResource: { [weak self] scope in
                    guard let self else {
                        return HarnessContentResource(state: .error("This conversation surface has been released"),
                            retry: { throw CancellationError() }, release: {})
                    }
                    return contentResource(scope)
                }, onIndexChange: { [weak self] index in
                    guard let self, !isReleased, lastIndex != index else { return }
                    lastIndex = index; onIndexChange(index)
                }, previewAttachment: host.callbacks.previewAttachment.map { preview in
                    { [weak self] attachmentID in
                        guard let self else { throw CancellationError() }; try checkLifetime()
                        _ = try host.authoritativeThread(threadID: threadID, harnessID: harnessID, source: source)
                        let data = try await preview(threadID, attachmentID)
                        try checkLifetime(); return data
                    }
                }, resolveMedia: host.callbacks.resolveMedia)
            let result = try plugin.threadView(input: materialized, actions: actions, context: context)
            measurement?.end()
            return result
        } catch {
            measurement?.end(error is CancellationError ? .cancelled : .failed)
            throw error
        }
    }

    func checkLifetime() throws { if isReleased { throw CancellationError() } }

    var hasAuthority: Bool {
        !isReleased && (try? host.authoritativeThread(threadID: threadID, harnessID: harnessID, source: source)) != nil
    }

    func invalidate() {
        let owned = retire()
        Task { for resource in owned { await resource.release() } }
    }

    public func release() async {
        let owned = retire()
        for resource in owned { await resource.release() }
    }

    private func retire() -> [HarnessContentResource] {
        guard !isReleased else { return [] }
        isReleased = true
        let owned = resources.values.map(\.resource)
        for resource in owned { resource.beginRelease() }
        resources.removeAll(); materialization.clear(); lastIndex = nil
        host.unregisterSurface(id)
        return owned
    }
}

@MainActor
private struct NativeHarnessContentView: View {
    let surface: NativeHarnessThreadSurface
    @State private var resource: HarnessContentResource?
    @Environment(\.nativePerformanceOperation) private var performanceOperation

    var body: some View {
        Group {
            if let resource {
                switch resource.state {
                case .loading: NativeHarnessStatusView(message: "正在读取…", english: "Loading…")
                case .error(let message):
                    NativeHarnessStatusView(message: "读取对话内容失败。", english: "Unable to read this conversation.", detail: message) {
                        Task { try? await resource.retry() }
                    }
                case .ready(let value):
                    render(value)
                }
            } else { NativeHarnessStatusView(message: "正在读取…", english: "Loading…") }
        }
        .task(id: surface.id) {
            surface.bindPerformance(parent: performanceOperation)
            resource = surface.contentResource(.thread)
        }
        .onChange(of: performanceOperation) { _, value in surface.bindPerformance(parent: value) }
        .environment(\.nativePerformanceOperation, surface.performanceOperation ?? performanceOperation)
    }

    @ViewBuilder private func render(_ value: JSONValue) -> some View {
        switch Result(catching: { try surface.render(value) }) {
        case .success(let result): result
        case .failure(let error):
            NativeHarnessStatusView(message: "此 Harness 的渲染模块暂时不可用；其他 Thread 不受影响。",
                                    english: "This Harness view is unavailable; other threads are unaffected.", detail: error.localizedDescription)
        }
    }
}

/// Bounded by one surface. Admission still checks the entire resulting envelope
/// on each changed content value, including its extra nesting level.
@MainActor final class NativeThreadMaterializationCache {
    private var envelope: HarnessThread?
    private var content: JSONValue?
    private var result: Result<HarnessThread, Error>?
    private(set) var materializationCount = 0
    func thread(_ envelope: HarnessThread, content: JSONValue) throws -> HarnessThread {
        if self.envelope == envelope, self.content == content, let result { return try result.get() }
        let next = Result { try envelope.replacingSessionState(content) }
        materializationCount += 1
        self.envelope = envelope; self.content = content; result = next
        return try next.get()
    }
    func clear() { envelope = nil; content = nil; result = nil }
}
