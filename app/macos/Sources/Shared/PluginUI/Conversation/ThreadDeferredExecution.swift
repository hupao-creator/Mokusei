import Foundation
import Observation
import MokuseiCore
import MokuseiPluginAPI
import SwiftUI

/// Presence is separate from text: a deferred empty string must not change the
/// native row's identity, classification or summary.
public struct ThreadExecutionPresence: Sendable, Hashable {
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
    static let defaultValue: (@MainActor (JSONText, [ThreadDetailRow]) -> AnyView)? = nil
}
private struct ExecutionGroupKey: EnvironmentKey {
    static let defaultValue: JSONText? = nil
}
public extension EnvironmentValues {
    var threadExecutionPresence: ThreadExecutionPresence {
        get { self[ExecutionPresenceKey.self] }
        set { self[ExecutionPresenceKey.self] = newValue }
    }
    var threadExecutionLoader: (@MainActor (JSONText, [ThreadDetailRow]) -> AnyView)? {
        get { self[ExecutionLoaderKey.self] }
        set { self[ExecutionLoaderKey.self] = newValue }
    }
    var threadExecutionGroup: JSONText? {
        get { self[ExecutionGroupKey.self] }
        set { self[ExecutionGroupKey.self] = newValue }
    }
}

/// Own one resource per selected detail run, with distinct leases for
/// concurrently open groups. Closing one group must never revoke another.
@MainActor @Observable
final class ThreadExecutionDemand {
    private var resources: [HarnessDetailSelection: HarnessContentResource] = [:]
    private var leases: [HarnessDetailSelection: Set<UUID>] = [:]

    func resource(_ selection: HarnessDetailSelection) -> HarnessContentResource? { resources[selection] }
    func acquire(_ selection: HarnessDetailSelection, lease: UUID, make: () -> HarnessContentResource) {
        var owned = leases[selection] ?? []
        guard owned.insert(lease).inserted else { return }
        leases[selection] = owned
        if resources[selection] == nil || resources[selection]?.isReleased == true {
            resources[selection] = make()
        }
    }
    func release(_ selection: HarnessDetailSelection, lease: UUID) {
        var owned = leases[selection] ?? []
        owned.remove(lease)
        if owned.isEmpty {
            leases[selection] = nil
            resources.removeValue(forKey: selection)?.beginRelease()
        } else {
            leases[selection] = owned
        }
    }
    func clear() {
        leases.removeAll()
        for resource in resources.values { resource.beginRelease() }
        resources.removeAll()
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

    private func executionGroup(_ group: JSONText, rows: [ThreadDetailRow]) -> AnyView {
        guard !rows.isEmpty else { return AnyView(EmptyView()) }
        let selection = HarnessDetailSelection(execution: rowKey, items: rows.map(\.id))
        return AnyView(DeferredExecutionGroup(demand: demand, selection: selection, context: context, group: group))
    }
}

private struct DeferredExecutionGroup: View {
    let demand: ThreadExecutionDemand
    let selection: HarnessDetailSelection
    let context: HarnessRenderContext
    let group: JSONText
    @State private var lease = UUID()
    @State private var activeSelection: HarnessDetailSelection?
    @State private var retryError: String?
    @Environment(\.locale) private var locale

    var body: some View {
        Group {
            if let resource = demand.resource(selection) {
                switch resource.state {
                case .ready(let value): HarnessDetailList(directory: value, selection: selection, context: context)
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
        .environment(\.threadExecutionGroup, group)
        .nativeReadingObservation("load", role: "detail.load", value: loadState)
        .task(id: selection) {
            guard !Task.isCancelled else { return }
            if let activeSelection { demand.release(activeSelection, lease: lease) }
            activeSelection = selection
            guard !selection.items.isEmpty else { return }
            demand.acquire(selection, lease: lease, make: { context.contentResource(.detail(selection)) })
        }
        .onDisappear {
            if let activeSelection { demand.release(activeSelection, lease: lease) }
            activeSelection = nil
        }
    }
    private var loadState: JSONValue {
        guard let resource = demand.resource(selection) else { return .object(["state": .text("loading")]) }
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
