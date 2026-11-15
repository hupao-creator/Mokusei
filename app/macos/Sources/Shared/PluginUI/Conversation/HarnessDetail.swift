import Foundation
import MokuseiCore
import MokuseiPluginAPI
import SwiftUI

/// One selected execution run. The directory is metadata-only; body views lease
/// independent, versioned chunks page by page.
public struct HarnessDetailList: View {
    public let directory: JSONValue
    public let selection: HarnessDetailSelection?
    public let context: HarnessRenderContext
    @Environment(\.locale) private var locale
    public init(directory: JSONValue, selection: HarnessDetailSelection? = nil, context: HarnessRenderContext) {
        self.directory = directory
        self.selection = selection
        self.context = context
    }

    public var body: some View {
        let execution = directory["executionId"]?.stringValue.map { JSONText($0) }
        let contentID = directory["contentId"]?.stringValue ?? ""
        let items = directory["items"]?.arrayValue ?? []
        let truncated = directory["truncated"]?.boolValue == true || selection?.truncated == true
        VStack(alignment: .leading, spacing: 0) {
            if truncated {
                Text(NativePluginLocalization.localize("详情过多，仅显示前一部分。", locale: locale))
                    .font(NativeTypography.inter(size: 11))
                    .foregroundStyle(NativePalette.thread.muted.swiftUI)
                    .padding(.vertical, 8)
            }
            ForEach(items, id: \.self) { item in
                if let execution, let itemID = item["id"]?.stringValue.map({ JSONText($0) }) {
                    HarnessDetailItemView(item: item, execution: execution, contentID: contentID, context: context)
                        .threadReadingAnchor(itemID)
                        .nativeReadingScope("item." + nativeReadingInteractionKey(itemID))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HarnessDetailItemView: View {
    let item: JSONValue
    let execution: JSONText
    let contentID: String
    let context: HarnessRenderContext
    @Environment(\.locale) private var locale

    private var id: JSONText? { item["id"]?.stringValue.map { JSONText($0) } }
    private var kind: String { item["kind"]?.stringValue ?? "" }
    private var label: String { item["label"]?.stringValue ?? "" }
    private var status: String { item["status"]?.stringValue ?? "" }
    private var toolName: String { item["toolName"]?.stringValue ?? "" }
    private var bodies: [JSONValue] { item["bodies"]?.arrayValue ?? [] }

    var body: some View {
        Group {
            if let id {
                switch kind {
                case "reasoning":
                    ThreadSurfaceDisclosure(label: localized("思考过程"), live: status == "running") {
                        bodyList(itemID: id)
                    }
                case "activity", "tool", "interaction":
                    ThreadActivityRow(id: id, state: activityState,
                        label: AnyView(Text(activityLabel).lineLimit(1)),
                        detail: bodies.isEmpty ? nil : AnyView(bodyList(itemID: id)))
                case "error":
                    bodyList(itemID: id)
                        .font(NativeTypography.inter(size: 12))
                        .foregroundStyle(NativePalette.thread.danger.swiftUI)
                case "notice":
                    bodyList(itemID: id)
                        .font(NativeTypography.inter(size: 11))
                        .foregroundStyle(NativePalette.thread.muted.swiftUI)
                case "review":
                    ThreadSurfaceDisclosure(label: localized("代码审查")) {
                        bodyList(itemID: id)
                    }
                case "context":
                    HStack(spacing: 8) {
                        NativeIcon(name: "Minimize2", size: 12)
                        Text(localized("上下文已压缩"))
                    }
                    .font(NativeTypography.inter(size: 11))
                    .foregroundStyle(NativePalette.thread.muted.swiftUI)
                    .padding(.vertical, 8)
                default:
                    bodyList(itemID: id)
                }
            }
        }
    }

    private var activityLabel: String {
        let value = !label.isEmpty ? label : !toolName.isEmpty ? toolName : localized("工具")
        return status == "failed" ? value + " · " + localized("失败") : value
    }

    private var activityState: AnyView {
        if status == "running" { return AnyView(ProgressView().controlSize(.mini).scaleEffect(0.7)) }
        let name = status == "failed" ? "CircleAlert" : ["command": "SquareTerminal", "search": "Search", "subagent": "Bot"].first { toolName.contains($0.key) }?.value ?? "Wrench"
        return AnyView(NativeIcon(name: name, size: 13))
    }

    private func bodyList(itemID: JSONText) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(bodies.enumerated()), id: \.offset) { _, body in
                if let slot = body["slot"]?.stringValue {
                    VStack(alignment: .leading, spacing: 4) {
                        if let label = bodyLabel(slot: slot, body: body), !label.isEmpty {
                            Text(label).font(NativeTypography.inter(size: 11))
                                .foregroundStyle(NativePalette.thread.muted.swiftUI)
                        }
                        HarnessDetailBodyView(execution: execution, contentID: contentID, item: itemID,
                                              bodyData: body, slot: JSONText(slot), context: context)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bodyLabel(slot: String, body: JSONValue) -> String? {
        if let label = body["label"]?.stringValue, !label.isEmpty { return label }
        switch slot {
        case "arguments": return localized("输入")
        case "result": return localized("输出")
        default: return nil
        }
    }

    private func localized(_ value: String) -> String { NativePluginLocalization.localize(value, locale: locale) }
}

@MainActor final class HarnessDetailBodyGate {
    struct Admission { let token: UUID }
    struct PageReservation { let token: UUID }

    static let shared = HarnessDetailBodyGate()
    private let pageCapacityTimeout: Duration
    private var activeViews = 0
    private var pageReservations = 0
    private var generation = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var capacityPollTask: Task<Void, Never>?

    var activeViewCount: Int { activeViews }
    var pageReservationCount: Int { pageReservations }
    var waiterCount: Int { waiters.count }
    /// Deterministic test seam for the check-to-registration window.
    var beforeWaitForTesting: (@MainActor () -> Void)?

    init(pageCapacityTimeout: Duration = .seconds(5)) {
        self.pageCapacityTimeout = pageCapacityTimeout
    }

    /// Admit a body view. The capacity closure is re-read while waiting. Page
    /// reservations already granted to sibling views reduce the view limit, so a
    /// new view cannot consume a slot another admitted body is about to use.
    /// A zero limit is not queued: the caller shows the capacity failure and its
    /// explicit retry action. External capacity is polled while a view waits, so
    /// a non-body surface releasing a slot can admit a new view without an
    /// existing view releasing its gate token.
    func acquire(limit: @MainActor () async -> Int) async throws -> Admission? {
        let token = UUID()
        let deadline = ContinuousClock.now + pageCapacityTimeout
        while true {
            try Task.checkCancellation()
            // Capture the release generation before the suspension. A release
            // landing between capacity read and waiter registration changes this
            // value, so wait(observed:) returns immediately instead of losing it.
            let observed = generation
            let available = await limit()
            // A raw zero is the explicit capacity/retry state. Positive capacity
            // that is fully reserved by admitted siblings waits instead, so a
            // newly mounted body does not fail merely because older pages hold
            // the current reservations.
            guard available > 0 else { return nil }
            let maximum = max(0, available - pageReservations)
            if activeViews < maximum {
                activeViews += 1
                return Admission(token: token)
            }
            beforeWaitForTesting?()
            await wait(observed: observed)
            guard ContinuousClock.now < deadline else { return nil }
        }
    }

    /// Reserve the one client resource a body page is about to create. This is
    /// the authoritative per-page admission: unlike a raw "available > 0"
    /// check, pending reservations from admitted siblings are counted, so pages
    /// wait instead of racing into CONTENT_CAPACITY.
    func reservePage(capacity: @MainActor () async -> Int) async throws -> PageReservation? {
        let token = UUID()
        let deadline = ContinuousClock.now + pageCapacityTimeout
        var delay = Duration.milliseconds(20)
        while true {
            try Task.checkCancellation()
            if await capacity() - pageReservations > 0 {
                pageReservations += 1
                return PageReservation(token: token)
            }
            // External capacity (non-body resources) is not owned by the gate
            // and therefore cannot signal a gate release. Poll with backoff so a
            // freed external slot is observed; a persistently exhausted page
            // gives up for an explicit capacity/retry state.
            guard ContinuousClock.now < deadline else { return nil }
            try await Task.sleep(for: delay)
            delay = min(delay + delay, .milliseconds(250))
        }
    }

    func release(_ admission: Admission) {
        activeViews = max(0, activeViews - 1)
        wakeAll()
    }

    func releasePage(_ reservation: PageReservation) {
        pageReservations = max(0, pageReservations - 1)
        wakeAll()
    }

    private func wait(observed: Int) async {
        let waiter = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || generation != observed {
                    continuation.resume()
                } else {
                    waiters[waiter] = continuation
                    startCapacityPoll()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(waiter) }
        }
    }

    private func startCapacityPoll() {
        guard capacityPollTask == nil else { return }
        capacityPollTask = Task { @MainActor [weak self] in
            defer { self?.capacityPollTask = nil }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !self.waiters.isEmpty else { return }
                // External capacity changes cannot signal the gate directly.
                // Wake registered admissions periodically to re-read it.
                self.wakeAll()
            }
        }
    }

    private func wakeAll() {
        generation &+= 1
        let waiting = waiters.values
        waiters.removeAll()
        for continuation in waiting { continuation.resume() }
    }

    private func cancel(_ token: UUID) {
        waiters.removeValue(forKey: token)?.resume()
    }
}

struct HarnessDetailBodyView: View {
    let execution: JSONText
    let contentID: String
    let item: JSONText
    let bodyData: JSONValue
    let slot: JSONText
    let context: HarnessRenderContext
    let gate: HarnessDetailBodyGate
    @State private var text = ""
    @State private var failure: String?
    @State private var loading = true
    @State private var generation = 0
    @Environment(\.locale) private var locale

    init(execution: JSONText, contentID: String, item: JSONText, bodyData: JSONValue,
         slot: JSONText, context: HarnessRenderContext, gate: HarnessDetailBodyGate = .shared) {
        self.execution = execution; self.contentID = contentID; self.item = item
        self.bodyData = bodyData; self.slot = slot; self.context = context; self.gate = gate
    }

    private var format: String { bodyData["format"]?.stringValue ?? "text" }
    private var descriptorLength: Int { bodyData["length"]?.intValue ?? 0 }
    private var loadKey: String { "\(item.string)|\(slot.string)|\(contentID)|\(descriptorLength)" }

    var body: some View {
        Group {
            if let failure {
                VStack(alignment: .leading, spacing: 6) {
                    Text(failure)
                        .font(NativeTypography.inter(size: 11))
                        .foregroundStyle(NativePalette.thread.danger.swiftUI)
                        .textSelection(.enabled)
                    Button(localized("重试")) {
                        Task { await restartLoad() }
                    }
                    .buttonStyle(.plain)
                    .font(NativeTypography.inter(size: 11))
                }
            } else if format == "markdown" {
                NativeMarkdownView(text: text, openExternal: context.openExternal, resolveMedia: context.resolveMedia)
            } else {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if loading, text.isEmpty, failure == nil {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(localized("正在加载详情"))
            }
        }
        .task(id: loadKey) { await restartLoad() }
    }

    @MainActor private func restartLoad() async {
        generation += 1
        await load(generation)
    }

    @MainActor private func load(_ generation: Int) async {
        loading = true; failure = nil; text = ""
        var cursor = ""
        var version: String?
        var totalLength: Int?
        var restarted = false
        var admission: HarnessDetailBodyGate.Admission?
        var pageReservation: HarnessDetailBodyGate.PageReservation?
        do {
            guard let acquired = try await gate.acquire(limit: {
                await context.detailBodyCapacity?() ?? 4
            }) else {
                failure = localized("内容容量已满，请关闭其他详情后重试。")
                loading = false
                return
            }
            admission = acquired
        } catch {
            if generation == self.generation { failure = error.localizedDescription; loading = false }
            return
        }
        defer {
            if let pageReservation { gate.releasePage(pageReservation) }
            if let admission { gate.release(admission) }
        }
        while !Task.isCancelled, generation == self.generation {
            let reservation: HarnessDetailBodyGate.PageReservation
            do {
                guard let acquired = try await gate.reservePage(capacity: {
                    await context.detailBodyCapacity?() ?? 4
                }) else {
                    guard generation == self.generation else { return }
                    failure = localized("内容容量已满，请关闭其他详情后重试。")
                    loading = false
                    return
                }
                reservation = acquired
            } catch {
                if Task.isCancelled || generation != self.generation { return }
                failure = error.localizedDescription
                loading = false
                return
            }
            pageReservation = reservation
            guard !Task.isCancelled, generation == self.generation else {
                gate.releasePage(reservation)
                pageReservation = nil
                return
            }
            let resource = context.contentResource(.body(HarnessDetailBodyReference(
                execution: execution, item: item, slot: slot, cursor: cursor)))
            do {
                let value = try await resource.waitForResult()
                try Task.checkCancellation()
                guard generation == self.generation else {
                    await resource.release()
                    gate.releasePage(reservation)
                    pageReservation = nil
                    return
                }
                guard value["executionId"]?.stringValue == execution.string,
                      value["itemId"]?.stringValue == item.string,
                      value["slot"]?.stringValue == slot.string,
                      let responseVersion = value["version"]?.stringValue, !responseVersion.isEmpty,
                      let offset = value["offset"]?.intValue, let length = value["length"]?.intValue else {
                    throw PluginContractError("Detail body identity changed")
                }
                if let version {
                    guard responseVersion == version, offset == text.utf8.count, length == totalLength else {
                        throw HarnessContentFailure(code: "DETAIL_VERSION_CHANGED", message: "The detail body changed; reload the detail")
                    }
                } else {
                    guard offset == 0 else { throw PluginContractError("Detail body did not start at offset zero") }
                    version = responseVersion; totalLength = length
                }
                text += value["text"]?.stringValue ?? ""
                let next = value["next"]?.stringValue ?? ""
                await resource.release()
                gate.releasePage(reservation)
                pageReservation = nil
                guard generation == self.generation else { return }
                if next.isEmpty {
                    if let totalLength, text.utf8.count != totalLength {
                        throw PluginContractError("Detail body ended before its declared length")
                    }
                    loading = false
                    return
                }
                guard next != cursor else {
                    throw PluginContractError("Detail body cursor did not advance")
                }
                cursor = next
            } catch {
                await resource.release()
                gate.releasePage(reservation)
                pageReservation = nil
                if Task.isCancelled || generation != self.generation || error is CancellationError { return }
                let failure = error as? HarnessContentFailure
                if failure?.code == "DETAIL_VERSION_CHANGED", !restarted {
                    // Only an explicit version change discards a partial body.
                    // The next first page names the new length and version.
                    restarted = true
                    cursor = ""
                    text = ""
                    version = nil
                    totalLength = nil
                    continue
                }
                self.failure = error.localizedDescription
                loading = false
                return
            }
        }
    }

    private func localized(_ value: String) -> String { NativePluginLocalization.localize(value, locale: locale) }
}
