import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

@MainActor private enum ReportExpansionStore { static var expanded = Set<JSONText>() }

@MainActor struct NativeReportCard: View {
    let props: ApplicationThreadProps<NativeReportView>
    let projection: NativeReportCardProjection
    let openThread: () -> Void
    @State private var expanded = false
    @State private var references: [ApplicationExecutionPresentation] = []
    @State private var requestedReferences: [ApplicationExecutionRef] = []
    @State private var failure: String?
    @State private var unsubscribe: (() -> Void)?
    @State private var archivePending = false
    @FocusState private var expansionFocused: Bool
    private var locale: JSONText { props.context.locale }
    private var visibleReferences: [ApplicationExecutionPresentation] { expanded ? references : Array(references.prefix(2)) }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Button(action: openThread) { Color.clear.contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel(props.entry.title.string)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text(props.entry.title.string).font(NativeTypography.inter(size: 15, weight: 620)).lineLimit(1).help(props.entry.title.string)
                        Spacer(minLength: 0)
                        Button { Task { await archive() } } label: {
                            NativeIcon(name: props.entry.archived ? "ArchiveRestore" : "Archive", size: 12).frame(width: 20, height: 20)
                        }.buttonStyle(.plain).foregroundStyle(NativePalette.overview.faint.swiftUI).disabled(archivePending)
                            .accessibilityLabel(applicationText(locale, props.entry.archived ? "恢复报告：\(props.entry.title.string)" : "归档报告：\(props.entry.title.string)", props.entry.archived ? "Restore report: \(props.entry.title.string)" : "Archive report: \(props.entry.title.string)"))
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { clock in
                        HStack(spacing: 3) {
                            NativeIcon(name: "FileText", size: 11)
                            Text(applicationText(locale, "报告", "Report")).fontWeight(.semibold)
                            Text(" · ")
                            Text(updatedLabel(now: clock.date))
                        }.font(NativeTypography.inter(size: 9.5)).foregroundStyle(NativePalette.overview.faint.swiftUI)
                    }.padding(.top, 6)
                    Text(projection.previewText.string).font(NativeTypography.inter(size: 11.5)).lineSpacing(3)
                        .foregroundStyle(NativePalette.overview.ink.swiftUI.opacity(0.7)).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12).opacity(expanded ? 0 : 1)
                    if !expanded { relations.padding(.top, 8) }
                    Spacer(minLength: 0)
                    footer
                    if let failure { Text(failure).font(NativeTypography.inter(size: 10)).foregroundStyle(NativePalette.overview.danger.swiftUI).lineLimit(2) }
                }.padding(18).allowsHitTesting(true)
                if expanded {
                    NativeScrollView { relations }.frame(height: max(0, geometry.size.height - 114))
                        .nativeCanvasNavigationRegion().padding(.horizontal, 18).offset(y: 64)
                }
            }
        }.foregroundStyle(NativePalette.overview.ink.swiftUI)
            .onAppear { expanded = ReportExpansionStore.expanded.contains(props.entry.ref.threadID); requestedReferences = props.entry.view.relatedExecutions; subscribe() }
            .onDisappear { unsubscribe?(); unsubscribe = nil }
            .onChange(of: props.entry.view.relatedExecutions) { _, next in requestedReferences = next; readReferences() }
            .onChange(of: props.entry.ref) { _, reference in expanded = ReportExpansionStore.expanded.contains(reference.threadID); requestedReferences = props.entry.view.relatedExecutions; subscribe() }
            .nativeOnExitCommand { if expanded { setExpanded(false); expansionFocused = true } }
    }
    private var relations: some View {
        VStack(alignment: .leading, spacing: 2) {
            if visibleReferences.isEmpty {
                Text(applicationText(locale, "无关联 Thread", "No related threads")).font(NativeTypography.inter(size: 10)).foregroundStyle(NativePalette.overview.faint.swiftUI)
            }
            ForEach(visibleReferences, id: \.reference) { reference in
                Button { if !reference.missing { props.context.openExecution(reference.reference) } } label: {
                    HStack(spacing: 6) {
                        if let harness = reference.harness {
                            relationLogo(harness)
                        } else { Circle().fill(NativePalette.overview.muted.swiftUI.opacity(0.38)).frame(width: 4, height: 4).frame(width: 12, height: 12) }
                        Text(reference.title.string).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        if let usage = reference.usage {
                            Text(usage.value.string).foregroundStyle(NativePalette.overview.faint.swiftUI)
                                .accessibilityLabel("\(usage.count.formatted()) \(usage.suffix.string)")
                                .help(applicationText(locale, "输入与输出 token 合计，按 Harness 当前上报的统计范围显示", "Total input and output tokens within the Harness's current reporting scope"))
                        }
                        if reference.missing || reference.running {
                            Text(reference.missing ? applicationText(locale, "已删除", "Deleted") : applicationText(locale, "运行中", "Running"))
                                .foregroundStyle(NativePalette.overview.faint.swiftUI)
                        }
                    }.font(NativeTypography.inter(size: 10)).frame(minHeight: expanded ? 28 : 18).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(reference.missing)
                    .foregroundStyle(reference.missing ? NativePalette.overview.faint.swiftUI : NativePalette.overview.ink.swiftUI.opacity(0.76))
                    .accessibilityLabel(applicationText(locale, "打开关联 Thread：\(reference.title.string)", "Open related thread: \(reference.title.string)"))
            }
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityLabel(applicationText(locale, "关联的 Agent Thread", "Related Agent threads"))
    }
    private var footer: some View {
        HStack(spacing: 12) {
            if references.count > 2 {
                Button { setExpanded(!expanded) } label: {
                    HStack(spacing: 4) {
                        Text(expanded ? applicationText(locale, "收起关联", "Collapse related threads") : applicationText(locale, "查看全部 \(references.count) 个关联", "View all \(references.count) related threads"))
                        NativeIcon(name: "ChevronDown", size: 12).rotationEffect(.degrees(expanded ? 180 : 0))
                    }.font(NativeTypography.inter(size: 10)).frame(minHeight: 24)
                }.buttonStyle(.plain).foregroundStyle(NativePalette.overview.muted.swiftUI).focused($expansionFocused)
                    .accessibilityValue(expanded ? "expanded" : "collapsed")
            }
            Spacer(minLength: 0)
            Button(action: openThread) {
                HStack(spacing: 3) { Text(applicationText(locale, "打开报告", "Open report")); NativeIcon(name: "ArrowUpRight", size: 11) }
                    .font(NativeTypography.inter(size: 9.5, weight: 650))
            }.buttonStyle(.plain).foregroundStyle(NativePalette.overview.muted.swiftUI)
        }
    }
    private func setExpanded(_ value: Bool) {
        expanded = value
        if value { ReportExpansionStore.expanded.insert(props.entry.ref.threadID) }
        else { ReportExpansionStore.expanded.remove(props.entry.ref.threadID) }
    }
    @ViewBuilder private func relationLogo(_ harness: ApplicationExecutionPresentation.Harness) -> some View {
        switch Result(catching: { try props.context.capabilities.require(ApplicationCapabilities.executionReferencesUI).logo(harness.id, 12) }) {
        case .success(let view): view.frame(width: 12, height: 12).accessibilityLabel(harness.displayName.string)
        case .failure(let error):
            NativeIcon(name: "CircleAlert", size: 12).foregroundStyle(NativePalette.overview.danger.swiftUI)
                .help(error.localizedDescription).accessibilityLabel(error.localizedDescription)
                .onAppear { failure = error.localizedDescription }
        }
    }
    private func subscribe() {
        unsubscribe?(); unsubscribe = nil
        do {
            let capability = try props.context.capabilities.require(ApplicationCapabilities.executionReferencesUI)
            unsubscribe = capability.subscribe { readReferences() }; readReferences()
        } catch { failure = error.localizedDescription }
    }
    private func readReferences() {
        do {
            references = try props.context.capabilities.require(ApplicationCapabilities.executionReferencesUI).read(requestedReferences)
            if expanded, references.count <= 2 { setExpanded(false) }
        }
        catch { failure = error.localizedDescription }
    }
    private func archive() async {
        guard !archivePending else { return }; archivePending = true
        defer { archivePending = false }
        do {
            try await props.context.capabilities.require(ApplicationCapabilities.threadUserActions)
                .setArchived(!props.entry.archived, JSONText(UUID().uuidString), props.context.lifetime)
            failure = nil
        } catch { failure = error.localizedDescription }
    }
    private func updatedLabel(now: Date) -> String {
        let updated = Date(timeIntervalSince1970: props.entry.updatedAt / 1_000)
        let seconds = max(0, Int(now.timeIntervalSince(updated)))
        if seconds < 60 { return applicationText(locale, "刚刚", "now") }
        if seconds >= 7 * 86_400 {
            let format = DateFormatter(); format.locale = Locale(identifier: locale.string); format.setLocalizedDateFormatFromTemplate("MMMd")
            return format.string(from: updated)
        }
        let formatter = RelativeDateTimeFormatter(); formatter.locale = Locale(identifier: locale.string); formatter.unitsStyle = .full
        let amount = seconds < 3_600 ? DateComponents(minute: -(seconds / 60)) : seconds < 86_400 ? DateComponents(hour: -(seconds / 3_600)) : DateComponents(day: -(seconds / 86_400))
        return formatter.localizedString(from: amount)
    }
}
