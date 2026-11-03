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
                                     reasoningUsage: ThreadReasoningUsage? = nil) -> [ThreadDetailRow] {
    let runs = partitionExecutionRows(rows)
    let lastExecution = runs.lastIndex { if case .execution = $0 { true } else { false } }
    return runs.enumerated().map { index, run in
        switch run {
        case .row(let row): return row
        case .execution(let id, let rows):
            return ThreadDetailRow(
                id: executionProcessID(id), kind: .work,
                node: AnyView(ThreadExecutionProcess(groupID: id, rows: rows,
                    reasoningUsage: index == lastExecution ? reasoningUsage : nil)))
        }
    }
}

public struct ThreadExecutionProcess: View {
    public let groupID: JSONText
    public let rows: [ThreadDetailRow]
    public let reasoningUsage: ThreadReasoningUsage?
    @Environment(\.locale) private var locale
    @Environment(\.threadExecutionLoader) private var loader
    @Environment(\.threadAgentDetail) private var agentDetail

    public init(groupID: JSONText, rows: [ThreadDetailRow], reasoningUsage: ThreadReasoningUsage? = nil) {
        self.groupID = groupID
        self.rows = rows
        self.reasoningUsage = reasoningUsage
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            summaryRow
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
            Text(summary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
        .padding(.vertical, 6)
        .font(NativeTypography.inter(size: 11))
        .foregroundStyle(NativePalette.thread.muted.swiftUI)
        .accessibilityElement(children: .combine)
        .id(executionProcessID(groupID))
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
        if let reasoningUsage, reasoningUsage.tokens.isFinite, reasoningUsage.tokens >= 0,
           reasoningUsage.tokens.rounded() == reasoningUsage.tokens, reasoningUsage.tokens <= 9_007_199_254_740_991 {
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
