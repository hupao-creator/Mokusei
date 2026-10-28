import Foundation
import MokuseiCore
import SwiftUI

func threadExecutionResultAnchor(_ executionID: JSONText) -> JSONText {
    JSONText("execution-result:" + nativeReadingInteractionKey(executionID))
}

/// Opaque, plugin-rendered rows; the shared UI never decodes their content.
public struct ThreadDetailRow: Identifiable {
    public enum Kind: String, Sendable { case user, work, content, attention }

    public let id: JSONText
    public let kind: Kind
    public let node: AnyView
    public let execution: ThreadExecutionMembership?
    public let executionSummary: ThreadExecutionSummary?
    public let finalReply: Bool

    public init(id: JSONText, kind: Kind, node: AnyView,
                execution: ThreadExecutionMembership? = nil,
                executionSummary: ThreadExecutionSummary? = nil, finalReply: Bool = false) {
        self.id = id
        self.kind = kind
        self.node = node
        self.execution = execution
        self.executionSummary = executionSummary; self.finalReply = finalReply
    }
}

public struct ThreadExecutionSummary: Sendable {
    public let reasoningSegments: Int
    public let toolCalls: Int

    public init(reasoningSegments: Int = 0, toolCalls: Int = 0) {
        self.reasoningSegments = reasoningSegments
        self.toolCalls = toolCalls
    }
}

/// A last-call snapshot must never be presented as a whole-turn total.
public struct ThreadReasoningUsage: Sendable {
    public enum Scope: Sendable { case turn, reportedTurn, lastCall }
    public let tokens: Double
    public let scope: Scope

    public init(tokens: Double, scope: Scope) {
        self.tokens = tokens
        self.scope = scope
    }
}

public struct ThreadDetailVisibility: Sendable, Equatable {
    public var userMessages: Bool
    public var work: Bool
    public var workTurnID: JSONText?

    public init(userMessages: Bool = false, work: Bool = false, workTurnID: JSONText? = nil) {
        self.userMessages = userMessages
        self.work = work
        self.workTurnID = workTurnID
    }
}

private struct ThreadDetailVisibilityKey: EnvironmentKey {
    static let defaultValue = ThreadDetailVisibility()
}

private struct ThreadFirstDetailRowKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ThreadTokenUsageInFooterKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    var threadDetailVisibility: ThreadDetailVisibility {
        get { self[ThreadDetailVisibilityKey.self] }
        set { self[ThreadDetailVisibilityKey.self] = newValue }
    }
}

private extension EnvironmentValues {
    var threadFirstDetailRow: Bool {
        get { self[ThreadFirstDetailRowKey.self] }
        set { self[ThreadFirstDetailRowKey.self] = newValue }
    }
    var threadTokenUsageInFooter: Bool {
        get { self[ThreadTokenUsageInFooterKey.self] }
        set { self[ThreadTokenUsageInFooterKey.self] = newValue }
    }
}

public struct ThreadDetailTurn: View {
    @Environment(\.threadExecutionGroup) private var executionGroup
    public let id: JSONText
    public let author: JSONValue?
    public let rows: [ThreadDetailRow]
    public let reasoningUsage: ThreadReasoningUsage?
    public let createdAt: Double
    public let updatedAt: Double
    public let status: String
    public let completedAt: Double?
    public let usage: AnyView?
    public let active: Bool

    @Environment(\.threadDetailVisibility) private var visibility
    @Environment(\.locale) private var locale

    public init(id: JSONText, author: JSONValue? = nil, rows: [ThreadDetailRow],
                reasoningUsage: ThreadReasoningUsage? = nil, createdAt: Double,
                updatedAt: Double, status: String, completedAt: Double? = nil,
                usage: AnyView? = nil, active: Bool) {
        self.id = id
        self.author = author
        self.rows = rows
        self.reasoningUsage = reasoningUsage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.completedAt = completedAt
        self.usage = usage
        self.active = active
    }

    private var filteredRows: [ThreadDetailRow] {
        let workVisible = visibility.work && (visibility.workTurnID == nil || visibility.workTurnID == id)
        return rows.filter {
            ($0.kind != .user || visibility.userMessages) && ($0.kind != .work || workVisible)
        }
    }

    public var body: some View {
        if let executionGroup {
            ThreadExecutionGroupContent(groupID: executionGroup, rows: filteredRows)
        } else {
            let displayed = groupThreadExecutionRows(filteredRows, reasoningUsage: reasoningUsage)
            // Harnesses identify the final reply, including its first text part.
            // Resolve only after the body loads; review/status rows can follow it.
            let result = completedAt != nil ? displayed.first(where: \.finalReply)?.id ?? displayed.last?.id : displayed.last?.id
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(displayed.enumerated()), id: \.element.id) { index, row in
                    row.node
                        .modifier(ExecutionResultAnchor(id: id, enabled: row.id == result))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .environment(\.threadFirstDetailRow, index == 0)
                        .nativeReadingScope("item." + nativeReadingInteractionKey(row.id))
                        .threadReadingAnchor(row.id)
                        .padding(.bottom, !active && index == displayed.count - 1 ? 0 : row.kind == .user ? 26 : 16)
                }
                if displayed.isEmpty {
                    Text(localize(status)).foregroundStyle(NativePalette.thread.muted.swiftUI)
                        .threadReadingAnchor(threadExecutionResultAnchor(id))
                }
                if !active { footer.padding(.top, displayed.last?.kind == .user ? 26 : 18) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(localize("对话轮次"))
            .nativeReadingObservation("turn", role: "turn", value: .object([
                "executionId": .string(id), "state": .text("ready"), "rowCount": .integer(rows.count),
                "visibleRowCount": .integer(filteredRows.count), "status": .text(status),
                "userMessages": .bool(visibility.userMessages), "work": .bool(visibility.work)
            ]))
            .id(id)
        }
    }

    private var footer: some View {
        ThreadFooterFlow(spacing: 6) {
            Text(authorLabel).font(NativeTypography.mono(size: 14))
            Text("·")
            if let completedAt {
                Text(formatThreadTimestamp(completedAt))
                    .font(NativeTypography.mono(size: 14))
                    .tracking(0.44)
                    .accessibilityLabel("\(localize("完成时间：")) \(formatThreadTimestamp(completedAt))")
            } else {
                Text(status)
                Text("·")
                Text(formatThreadTimestamp(updatedAt))
                    .font(NativeTypography.mono(size: 14))
                    .tracking(0.4)
                Text("·")
                Text(localize("已运行 {duration}").replacingOccurrences(
                    of: "{duration}", with: formatThreadWorkDuration(createdAt, updatedAt)))
            }
            if let usage {
                usage.environment(\.threadTokenUsageInFooter, true)
            }
        }
        .font(NativeTypography.inter(size: 14))
        .foregroundStyle(NativePalette.thread.muted.swiftUI)
    }

    private var authorLabel: String {
        let model = author?["model"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let effort = author?["effort"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        return "Author: \(model ?? localize("未知模型")) · \(localize(effort ?? "未记录"))"
    }

    private func localize(_ source: String) -> String {
        NativePluginLocalization.localize(source, locale: locale)
    }
}

private struct ExecutionResultAnchor: ViewModifier {
    let id: JSONText
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.threadReadingAnchor(threadExecutionResultAnchor(id)) }
        else { content }
    }
}

/// The harness supplies native header, form and action slots.
public struct ThreadDetailRequest<Content: View>: View {
    @Environment(\.threadFirstDetailRow) private var firstRow
    private let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !firstRow {
                Rectangle().fill(NativePalette.thread.lineSoft.swiftUI).frame(height: 1)
                    .padding(.bottom, 20)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, firstRow ? 0 : 18)
        .threadTimelineFocus()
    }
}

public struct ThreadTokenUsage: View {
    public let input: Double?
    public let output: Double?
    public let cached: Double?
    public let cacheWrite: Double?
    public let reasoning: Double?
    @Environment(\.locale) private var locale
    @Environment(\.threadTokenUsageInFooter) private var inFooter

    public init(input: Double? = nil, output: Double? = nil, cached: Double? = nil,
                cacheWrite: Double? = nil, reasoning: Double? = nil) {
        self.input = input
        self.output = output
        self.cached = cached
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
    }

    public var body: some View {
        if let input, let output, Self.valid(input), Self.valid(output) {
            let detail = details(input: input, output: output)
            HStack(spacing: 6) {
                if inFooter { Text("·").accessibilityHidden(true) }
                Text("\(threadTokenNumber(input + output)) tokens")
            }
                .font(NativeTypography.mono(size: 14))
                .tracking(0.44)
                .foregroundStyle(NativePalette.thread.muted.swiftUI)
                .monospacedDigit()
                .help(detail)
                .focusable()
                .accessibilityLabel("\(threadTokenNumber(input + output)) tokens; \(detail)")
        }
    }

    private static func valid(_ value: Double) -> Bool { value.isFinite && value >= 0 }

    private func details(input: Double, output: Double) -> String {
        var values: [(String, Double)] = [("输入", input), ("输出", output)]
        if let cached, Self.valid(cached) { values.append(("缓存读取", cached)) }
        if let cacheWrite, Self.valid(cacheWrite) { values.append(("缓存写入", cacheWrite)) }
        if let reasoning, Self.valid(reasoning) { values.append(("推理", reasoning)) }
        return values.map {
            "\(NativePluginLocalization.localize($0.0, locale: locale)): \(threadTokenNumber($0.1))"
        }.joined(separator: " · ")
    }
}

/// All native harness timestamps have the same millisecond unit as JavaScript.
public func formatThreadTimestamp(_ at: Double) -> String {
    guard at.isFinite else { return "" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
    return formatter.string(from: Date(timeIntervalSince1970: at / 1_000))
}

public func formatThreadWorkDuration(_ startedAt: Double, _ endedAt: Double) -> String {
    let seconds = max(0, floor((endedAt - startedAt) / 1_000))
    guard seconds.isFinite, seconds < Double(Int.max) else { return "" }
    let elapsed = Int(seconds)
    if elapsed < 60 { return "\(elapsed)s" }
    let hours = elapsed / 3_600
    let minutes = elapsed % 3_600 / 60
    let remainder = elapsed % 60
    if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
    return remainder > 0 ? "\(minutes)m \(remainder)s" : "\(minutes)m"
}

func threadTokenNumber(_ value: Double) -> String {
    if value == 0 { return "0" }
    if value.isFinite, value.rounded() == value, abs(value) < 1e21 {
        return String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    return String(value)
}

private struct ThreadFooterFlow: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = arrange(subviews, width: bounds.width).positions
        for (index, subview) in subviews.enumerated() {
            let item = positions[index]
            subview.place(at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
                          proposal: ProposedViewSize(item.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, positions: [CGRect]) {
        var positions: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
            if x > 0, x + size.width > width { y += lineHeight + spacing; x = 0; lineHeight = 0 }
            positions.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            maxX = max(maxX, x + size.width)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return (CGSize(width: width.isFinite ? width : maxX, height: y + lineHeight), positions)
    }
}
