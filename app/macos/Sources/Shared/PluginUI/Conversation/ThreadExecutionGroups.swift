import MokuseiCore
import SwiftUI

/// Explicit native membership, including a start hidden by visibility filters.
public enum ThreadExecutionMembership: Sendable, Equatable {
    case member
    case source(startID: JSONText)
}

public protocol ThreadExecutionSourceIdentity {
    var id: JSONText { get }
}

public func bindThreadExecutionSource<Source>(
    rows: [ThreadDetailRow], source: [Source], id: (Source) -> JSONText,
    isExecution: (Source) -> Bool
) -> [ThreadDetailRow] {
    var sourceIDs = Set<JSONText>()
    var runIDs: [JSONText: JSONText] = [:]
    var start: JSONText?
    for item in source {
        let itemID = id(item)
        sourceIDs.insert(itemID)
        guard isExecution(item) else { start = nil; continue }
        if start == nil { start = itemID }
        runIDs[itemID] = start
    }
    return rows.map { row in
        guard sourceIDs.contains(row.id) else { return row }
        return ThreadDetailRow(id: row.id, kind: row.kind, node: row.node,
                               execution: runIDs[row.id].map { .source(startID: $0) },
                               executionSummary: row.executionSummary, finalReply: row.finalReply)
    }
}

public func bindThreadExecutionSource<Source: ThreadExecutionSourceIdentity>(
    rows: [ThreadDetailRow], source: [Source], isExecution: (Source) -> Bool
) -> [ThreadDetailRow] {
    bindThreadExecutionSource(rows: rows, source: source, id: { $0.id }, isExecution: isExecution)
}

public enum ThreadExecutionRowRun {
    case row(ThreadDetailRow)
    case execution(id: JSONText, rows: [ThreadDetailRow])
}

/// Adjacent visible execution rows share a summary even across hidden native
/// boundaries. Its identity comes from the first surviving run's source start.
public func partitionExecutionRows(_ rows: [ThreadDetailRow]) -> [ThreadExecutionRowRun] {
    var result: [ThreadExecutionRowRun] = []
    var currentID: JSONText?
    var currentRows: [ThreadDetailRow] = []
    var usedIDs = Set<JSONText>()

    func flush() {
        if let currentID, let first = currentRows.first {
            // A visible diagnostic can split one native run. Reusing its source
            // start for both summaries makes SwiftUI reuse the wrong subtree.
            let id = usedIDs.contains(currentID) ? first.id : currentID
            usedIDs.insert(id)
            result.append(.execution(id: id, rows: currentRows))
        }
        currentID = nil
        currentRows = []
    }

    for row in rows {
        let runID: JSONText?
        if row.kind == .work || row.kind == .attention {
            switch row.execution {
            case .member: runID = row.id
            case .source(let startID): runID = startID
            case nil: runID = nil
            }
        } else { runID = nil }
        guard let runID else {
            flush()
            result.append(.row(row))
            continue
        }
        if currentID == nil { currentID = runID }
        currentRows.append(row)
    }
    flush()
    return result
}

@MainActor
public func groupThreadExecutionRows(_ rows: [ThreadDetailRow],
                                     reasoningUsage: ThreadReasoningUsage? = nil,
                                     summaryOnly: Bool = false, running: Bool = false) -> [ThreadDetailRow] {
    let runs = partitionExecutionRows(rows)
    let lastExecution = runs.lastIndex { if case .execution = $0 { true } else { false } }
    return runs.enumerated().compactMap { index, run in
        switch run {
        case .row(let row): return row
        case .execution(let id, let rows):
            let usage = index == lastExecution ? reasoningUsage : nil
            // A later reply/diagnostic ends loading even while the execution runs.
            // Use the unfiltered runs so omitting an empty summary cannot reactivate an older group.
            let loading = running && index == lastExecution && index == runs.indices.last

            // Classify by native content, never by row position or zero tool counts.
            // Full readers keep their original rows, disclosures and detail leases.
            guard !summaryOnly || rows.contains(where: { $0.executionSummary?.hasContent != false }) ||
                (usage?.hasValidTokens == true && (usage?.tokens ?? 0) > 0) else { return nil }
            return ThreadDetailRow(
                id: executionProcessID(id), kind: .work,
                node: AnyView(ThreadExecutionProcess(groupID: id, rows: rows,
                    reasoningUsage: usage, running: loading)))
        }
    }
}

public struct ThreadExecutionProcess: View {
    public let groupID: JSONText
    public let rows: [ThreadDetailRow]
    public let reasoningUsage: ThreadReasoningUsage?
    public let running: Bool
    @Environment(\.locale) private var locale
    @Environment(\.threadExecutionLoader) private var loader
    @Environment(\.threadAgentDetail) private var agentDetail
    @Environment(\.nativeThreadReveal) private var reveal

    public init(groupID: JSONText, rows: [ThreadDetailRow], reasoningUsage: ThreadReasoningUsage? = nil, running: Bool = false) {
        self.groupID = groupID
        self.rows = rows
        self.reasoningUsage = reasoningUsage
        self.running = running
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if reveal != nil {
                NativeThreadRevealRow(contentID: summary) { summaryRow }
            } else { summaryRow }
            // Agent reading stops at the summary, including for failed tools.
            // Do not acquire historical detail leases for this presentation.
            if !agentDetail {
                if let loader { loader(groupID) }
                else { ThreadExecutionMemberRows(rows: rows) }
            }
        }
    }

    private var summaryRow: some View {
        HStack(spacing: 7) {
            NativeIcon(name: "Wrench", size: 13)
                .frame(width: 20)
                .accessibilityHidden(true)
            summaryText
                .overlay {
                    if running && agentDetail {
                        ThreadExecutionLoadingSweep()
                            .mask { summaryText }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
        .padding(.vertical, 6)
        .font(NativeTypography.inter(size: 11))
        .foregroundStyle(NativePalette.thread.muted.swiftUI)
        .accessibilityElement(children: .combine)
        .id(executionProcessID(groupID))
    }

    private var summaryText: some View {
        Text(summary)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
    }

    private var summary: String {
        let reasoning = rows.reduce(0) { $0 + ($1.executionSummary?.reasoningSegments ?? 0) }
        let tools = rows.reduce(0) { $0 + ($1.executionSummary?.toolCalls ?? 0) }
        var parts = [localize("执行过程")]
        if reasoning != 0 {
            parts.append(localize(reasoning == 1 ? "1 段思考" : "{count} 段思考")
                .replacingOccurrences(of: "{count}", with: reasoning.formatted(.number.locale(locale))))
        }
        if tools != 0 {
            parts.append(localize(tools == 1 ? "1 次工具调用" : "{count} 次工具调用")
                .replacingOccurrences(of: "{count}", with: tools.formatted(.number.locale(locale))))
        }
        if let reasoningUsage, reasoningUsage.hasValidTokens {
            let label: String
            switch reasoningUsage.scope {
            case .turn: label = "本轮思考 {count} tokens"
            case .reportedTurn: label = "本轮已上报思考 {count} tokens"
            case .lastCall: label = "最近一次思考 {count} tokens"
            }
            parts.append(localize(label).replacingOccurrences(of: "{count}",
                with: reasoningUsage.tokens.formatted(.number.precision(.fractionLength(0)).locale(locale))))
        }
        return parts.joined(separator: " · ")
    }

    private func localize(_ source: String) -> String {
        NativePluginLocalization.localize(source, locale: locale)
    }
}

private func executionProcessID(_ source: JSONText) -> JSONText {
    JSONText(codeUnits: Array("execution-process:".utf16) + source.codeUnits)
}

private extension ThreadReasoningUsage {
    var hasValidTokens: Bool {
        tokens.isFinite && tokens >= 0 && tokens.rounded() == tokens && tokens <= 9_007_199_254_740_991
    }
}

/// Keep the clock in the decorative leaf: counts and accessibility remain static.
private struct ThreadExecutionLoadingSweep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.nativeReadingEntranceReady) private var entranceReady
    @State private var visible = false
    @State private var startedAt = Date()

    private var animates: Bool {
        visible && entranceReady && !reduceMotion && scenePhase == .active
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: NativeFrameRate.interval, paused: !animates)) { context in
            GeometryReader { geometry in
                // A fixed-width soft highlight keeps long summaries from becoming
                // a whole-line pulse. The reset happens beyond both text edges.
                let width: CGFloat = 64
                let travel = geometry.size.width + width
                let duration = max(0.8, Double(travel) / 180)
                let phase = context.date.timeIntervalSince(startedAt)
                    .truncatingRemainder(dividingBy: duration + 0.25) / duration
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: NativePalette.thread.inkStrong.swiftUI, location: 0.35),
                    .init(color: NativePalette.thread.inkStrong.swiftUI, location: 0.65),
                    .init(color: .clear, location: 1)
                ], startPoint: .leading, endPoint: .trailing)
                    .frame(width: width)
                    .offset(x: -width + travel * min(phase, 1))
            }
        }
        .opacity(animates ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { startedAt = Date(); visible = true }
        .onDisappear { visible = false }
        .onChange(of: animates) { _, value in if value { startedAt = Date() } }
    }
}
