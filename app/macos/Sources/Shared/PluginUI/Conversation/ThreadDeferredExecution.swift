import Foundation
import Observation
import MokuseiCore
import MokuseiPluginAPI
import SwiftUI

/// Presence is separate from text: a deferred empty string must not change the
/// native row's identity, classification or summary.
public struct ThreadExecutionPresence: Sendable {
    private var fields: [JSONText: Set<JSONText>] = [:]
    public init() {}
    init(_ values: [JSONValue]) throws {
        for value in values {
            guard case let .string(id)? = value["id"], case let .string(field)? = value["field"] else {
                throw PluginContractError("Invalid deferred execution presence")
            }
            fields[id, default: []].insert(field)
        }
    }
    public func contains(_ id: JSONText, _ field: String) -> Bool { fields[id]?.contains(JSONText(field)) == true }
}

private struct ExecutionPresenceKey: EnvironmentKey {
    static let defaultValue = ThreadExecutionPresence()
}
private struct ExecutionLoaderKey: EnvironmentKey {
    static let defaultValue: (@MainActor (JSONText) -> AnyView)? = nil
}
private struct ExecutionGroupKey: EnvironmentKey {
    static let defaultValue: JSONText? = nil
}
public extension EnvironmentValues {
    var threadExecutionPresence: ThreadExecutionPresence {
        get { self[ExecutionPresenceKey.self] }
        set { self[ExecutionPresenceKey.self] = newValue }
    }
    var threadExecutionLoader: (@MainActor (JSONText) -> AnyView)? {
        get { self[ExecutionLoaderKey.self] }
        set { self[ExecutionLoaderKey.self] = newValue }
    }
    var threadExecutionGroup: JSONText? {
        get { self[ExecutionGroupKey.self] }
        set { self[ExecutionGroupKey.self] = newValue }
    }
}

/// Own one resource per turn, with distinct leases for concurrently open groups.
/// Closing one group must never revoke another group's resource.
@MainActor @Observable
final class ThreadExecutionDemand {
    private(set) var resource: HarnessContentResource?
    @ObservationIgnored private var leases = Set<UUID>()

    func acquire(_ lease: UUID, make: () -> HarnessContentResource) {
        guard leases.insert(lease).inserted else { return }
        if resource == nil || resource?.isReleased == true { resource = make() }
    }
    func release(_ lease: UUID) {
        leases.remove(lease)
        if leases.isEmpty { clear() }
    }
    func clear() {
        leases.removeAll()
        resource?.beginRelease()
        resource = nil
    }
}

/// Each rendering closure creates a view with its own decode lifetime. Neither
/// the lightweight row nor a closed disclosure retains a decoded full payload.
public struct ThreadDeferredExecutionContent<Content: View>: View {
    let raw: JSONValue
    let rowKey: JSONText
    let context: HarnessRenderContext
    let render: (JSONValue) -> Content
    @State private var demand = ThreadExecutionDemand()

    public init(raw: JSONValue, rowKey: JSONText, context: HarnessRenderContext,
                @ViewBuilder render: @escaping (JSONValue) -> Content) {
        self.raw = raw; self.rowKey = rowKey; self.context = context; self.render = render
    }

    public var body: some View {
        let deferred = raw["kind"] == .text("deferred-execution")
        let state = deferred ? raw["state"] : raw
        let presence = deferred
            ? raw["nonempty"]?.arrayValue.flatMap { try? ThreadExecutionPresence($0) }
            : ThreadExecutionPresence()
        return Group {
            if let state, let presence {
                // Settlement changes the wire envelope, not the mounted row.
                // Keep one render site so decoding, Markdown and native selection
                // survive the active-to-deferred boundary without a blank frame.
                render(state)
                    .environment(\.threadExecutionPresence, presence)
                    .environment(\.threadExecutionLoader, deferred ? executionGroup : nil)
            } else { Text("Invalid deferred execution content").foregroundStyle(.red) }
        }
        .onDisappear { demand.clear() }
    }

    private func executionGroup(_ group: JSONText) -> AnyView {
        AnyView(DeferredExecutionGroup(demand: demand,
            make: { context.contentResource(.execution(rowKey)) }) { value in
                render(value)
                    .environment(\.threadExecutionPresence, ThreadExecutionPresence())
                    .environment(\.threadExecutionLoader, nil)
                    .environment(\.threadExecutionGroup, group)
            })
    }
}

private struct DeferredExecutionGroup<Content: View>: View {
    let demand: ThreadExecutionDemand
    let make: () -> HarnessContentResource
    @ViewBuilder let render: (JSONValue) -> Content
    @State private var lease = UUID()
    @State private var retryError: String?
    @Environment(\.locale) private var locale

    var body: some View {
        Group {
            if let resource = demand.resource {
                switch resource.state {
                case .ready(let value): render(value)
                case .loading: ProgressView().controlSize(.small)
                case .error(let message):
                    VStack(alignment: .leading, spacing: 8) {
                        Text(retryError ?? message).foregroundStyle(NativePalette.thread.danger.swiftUI)
                        Button(NativePluginLocalization.localize("重试", locale: locale)) {
                            Task { do { try await resource.retry(); retryError = nil } catch { retryError = error.localizedDescription } }
                        }.buttonStyle(.plain)
                    }
                }
            } else { ProgressView().controlSize(.small) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .nativeReadingObservation("load", role: "execution.load", value: loadState)
        .task { guard !Task.isCancelled else { return }; demand.acquire(lease, make: make) }
        .onDisappear { demand.release(lease) }
    }
    private var loadState: JSONValue {
        guard let resource = demand.resource else { return .object(["state": .text("loading")]) }
        switch resource.state {
        case .loading: return .object(["state": .text("loading")])
        case .ready: return .object(["state": .text("ready")])
        case .error(let message): return .object(["state": .text("error"), "error": .text(retryError ?? message)])
        }
    }
}

/// Render only the requested native run, without recreating its disclosure or
/// the surrounding answer/footer. Grouping uses the same visibility as its parent.
public struct ThreadExecutionGroupContent: View {
    public let groupID: JSONText
    public let rows: [ThreadDetailRow]
    public init(groupID: JSONText, rows: [ThreadDetailRow]) { self.groupID = groupID; self.rows = rows }
    public var body: some View {
        if let members = partitionExecutionRows(rows).compactMap({ run -> [ThreadDetailRow]? in
            if case let .execution(id, rows) = run, id == groupID { return rows }; return nil
        }).first {
            ThreadExecutionMemberRows(rows: members)
        }
    }
}

/// Already partitioned members must not be partitioned again: a diagnostic can
/// split one source run into groups whose displayed IDs differ from that source.
struct ThreadExecutionMemberRows: View {
    let rows: [ThreadDetailRow]
    var body: some View {
        ThreadActivityList(items: rows.map { row in
            ThreadActivitySlot(id: row.id, node: AnyView(row.node.threadReadingAnchor(row.id)
                .nativeReadingScope("item." + nativeReadingInteractionKey(row.id))))
        })
        .environment(\.threadExecutionGroup, nil)
    }
}
