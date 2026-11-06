import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

/// A reference opens the existing reader; no secondary navigation or selection owner.
struct NativeReportExecutionRow: View {
    let item: ApplicationExecutionPresentation
    let locale: JSONText
    let relation: NativeReportRelation?
    let visible: Bool
    let open: () -> Void
    @State private var hovered = false
    @State private var excerpt: (source: JSONText, text: String)?
    @State private var visibility = ThreadCardAnimationVisibility(isVisible: false)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    Text(item.emoji ?? "📝")
                        .font(.system(size: 16))
                        .accessibilityHidden(true)
                    Text(item.title.string)
                        .font(NativeTypography.inter(size: 13, weight: 600))
                        .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NativePalette.thread.muted.swiftUI)
                        .opacity(hovered ? 1 : 0.4).padding(.top, 3)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 5) {
                    if let relation {
                        if let title = relation.threadTitle {
                            Text("Thread: \(title.string)").lineLimit(2)
                            Text(applicationText(locale, "当前：", "Now: ") + status(relation.current?.status)
                                + (relation.backgroundRunning ? applicationText(locale, " · 后台运行中", " · Background running") : "")
                                + (relation.archived ? applicationText(locale, " · 已归档", " · Archived") : ""))
                        }
                        Text(applicationText(locale, relation.historical ? "报告关联的历史执行：" : "报告关联执行：",
                            relation.historical ? "Historical report execution: " : "Report execution: ")
                            + executionStatus(relation))
                        if relation.bindingCount > 1 {
                            Text(applicationText(locale, "绑定冲突：此 Thread 关联了多个 Super Thread，原始关联已保留。",
                                "Binding conflict: this Thread belongs to multiple Super Threads. Original links are preserved."))
                                .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text(applicationText(locale, "运行状态暂不可用", "Execution status unavailable"))
                    }
                    Text(item.reference.executionID.string)
                        .font(.system(size: 10, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        .accessibilityLabel("Execution ID: " + item.reference.executionID.string)
                }.font(NativeTypography.inter(size: 11)).foregroundStyle(NativePalette.thread.muted.swiftUI)
                if let excerpt, excerpt.source == item.preview?.excerpt, !excerpt.text.isEmpty {
                    Text(excerpt.text).font(NativeTypography.inter(size: 12))
                        .foregroundStyle(NativePalette.thread.muted.swiftUI)
                        .lineSpacing(4).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 5) {
                    if let harness = item.harness {
                        ThreadCardBrandLogo(logoSource: harness.logoSource,
                            label: harness.displayName.string, brandKey: harness.id.string)
                        Text(harness.displayName.string).lineLimit(1)
                    }
                    if item.missing { Text(applicationText(locale, "已删除", "Deleted")) }
                    Spacer(minLength: 8)
                    if !item.missing {
                        Image(systemName: "clock").accessibilityHidden(true)
                        if let execution = relation?.execution {
                            ThreadCardRuntime(startedAt: execution.startedAt, endedAt: execution.finishedAt)
                                .focusable(false)
                        } else {
                            Text(applicationText(locale, "耗时未知", "Duration unavailable"))
                        }
                    }
                }.font(NativeTypography.inter(size: 10)).foregroundStyle(NativePalette.thread.muted.swiftUI)
                    .padding(.top, 2)
            }
            .multilineTextAlignment(.leading)
            .foregroundStyle(NativePalette.thread.ink.swiftUI)
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(ReportExecutionGlassStyle())
        .disabled(item.missing || relation.map { !$0.unavailable.isEmpty } == true)
        .opacity(item.missing ? 0.45 : 1)
        .onHover { hovered = $0 }
        .help(item.title.string)
        .environment(\.threadCardAnimationVisibility, visibility)
        .task(id: visible ? item.preview?.excerpt : nil) {
            guard visible, let source = item.preview?.excerpt else { return }
            let text = await NativeMarkdownSummary.plainText(source.string, limit: 600)
            guard !Task.isCancelled else { return }
            excerpt = (source, text.split(whereSeparator: \.isWhitespace).joined(separator: " "))
        }
        // The sidecard remains mounted when folded. Stop excerpt/clock work then.
        .onChange(of: visible, initial: true) { _, value in visibility.isVisible = value }
        .onDisappear { visibility.isVisible = false }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
    }

    private func status(_ value: PublicExecution.Status?) -> String {
        switch value {
        case .running: applicationText(locale, "运行中", "Running")
        case .waitingForUser: applicationText(locale, "等待输入", "Waiting for input")
        case .completed: applicationText(locale, "已完成", "Completed")
        case .failed: applicationText(locale, "失败", "Failed")
        case .interrupted: applicationText(locale, "已中断", "Interrupted")
        case nil: applicationText(locale, "暂无执行", "No execution")
        }
    }

    private func executionStatus(_ relation: NativeReportRelation) -> String {
        switch relation.unavailable {
        case "thread-missing": return applicationText(locale, "Thread 已删除或缺失", "Thread deleted or missing")
        case "execution-missing": return applicationText(locale, "执行记录缺失", "Execution missing")
        case "outside-scope": return applicationText(locale, "来源已不在当前目录范围", "Source is outside this directory scope")
        default: return status(relation.execution?.status)
        }
    }
}

private struct ReportExecutionGlassStyle: ButtonStyle {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        Group {
            if reduceTransparency {
                configuration.label.background(configuration.isPressed
                    ? NativePalette.thread.accentSoft.swiftUI : NativePalette.thread.surface.swiftUI,
                    in: RoundedRectangle(cornerRadius: 16))
            } else {
                configuration.label.glassEffect(.regular.tint(configuration.isPressed
                    ? NativePalette.thread.accent.swiftUI.opacity(0.18) : nil).interactive(enabled),
                    in: .rect(cornerRadius: 16))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(
            configuration.isPressed ? NativePalette.thread.accent.swiftUI
                : NativePalette.thread.line.swiftUI.opacity(reduceTransparency || contrast == .increased ? 1 : 0),
            lineWidth: 1).allowsHitTesting(false))
    }
}
