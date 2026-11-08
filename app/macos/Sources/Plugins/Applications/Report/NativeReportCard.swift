import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

@MainActor struct NativeReportCard: View {
    let props: ApplicationThreadProps<NativeReportView>
    let projection: NativeReportCardProjection
    let openThread: () -> Void
    @State private var references: [ApplicationExecutionPresentation] = []
    @State private var requestedReferences: [ApplicationExecutionRef] = []
    @State private var failure: String?
    @State private var unsubscribe: (() -> Void)?
    @State private var archivePending = false
    private var locale: JSONText { props.context.locale }
    var body: some View {
        Button(action: openThread) {
            VStack(spacing: 4) {
                if props.entry.view.hasCover {
                    NativeReportCover(props: props)
                        .frame(height: 308)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                metadata
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(NativePalette.overview.ink.swiftUI)
            .environment(\.threadCardUsesFlatMaterials, true)
            .contextMenu {
                Button(applicationText(locale, props.entry.archived ? "恢复报告" : "归档报告", props.entry.archived ? "Restore report" : "Archive report")) {
                    Task { await archive() }
                }.disabled(archivePending)
            }
            .onAppear { requestedReferences = props.entry.view.relatedExecutions; subscribe() }
            .onDisappear { unsubscribe?(); unsubscribe = nil }
            .onChange(of: props.entry.view.relatedExecutions) { _, next in requestedReferences = next; subscribe() }
            .onChange(of: props.entry.ref) { _, _ in requestedReferences = props.entry.view.relatedExecutions; subscribe() }
    }
    private var metadata: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(props.entry.title.string).font(NativeTypography.inter(size: 15, weight: 620))
                .lineLimit(1, reservesSpace: true).fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, ThreadCardProviderStatus.cornerClearance).help(props.entry.title.string)
                .accessibilityLabel(props.entry.title.string)
            HStack(spacing: 5) {
                ForEach(harnesses, id: \.id) { harness in
                    let count = references.filter { $0.harness?.id == harness.id }.count
                    HStack(spacing: 3) {
                        relationLogo(harness)
                        if count > 1 { Text("×\(count)").monospacedDigit() }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(applicationText(locale, "\(harness.displayName.string)，\(count) 个关联 Thread", "\(harness.displayName.string), \(count) related threads"))
                    .help(applicationText(locale, "\(harness.displayName.string)：\(count) 个关联 Thread", "\(harness.displayName.string): \(count) related threads"))
                }
                TimelineView(.periodic(from: .now, by: 30)) { clock in Text(updatedLabel(now: clock.date)) }
            }.font(NativeTypography.inter(size: 11)).foregroundStyle(NativePalette.overview.faint.swiftUI)
                .padding(.top, 5).padding(.trailing, ThreadCardProviderStatus.cornerClearance)
            ThreadCardExcerpt(content: props.entry.view.shortDescription.string).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
            if let failure { Text(failure).font(NativeTypography.inter(size: 10)).foregroundStyle(NativePalette.overview.danger.swiftUI) }
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .threadCardBadge {
                ThreadCardProviderStatus(label: props.entry.title.string, brandKey: "", emoji: props.entry.view.emoji.string,
                                         completedBackground: true)
            }.contentShape(Rectangle())
    }

    private var harnesses: [ApplicationExecutionPresentation.Harness] {
        var seen = Set<JSONText>()
        return references.compactMap(\.harness).filter { seen.insert($0.id).inserted }
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
            unsubscribe = capability.subscribe(requestedReferences) { readReferences() }; readReferences()
        } catch { failure = error.localizedDescription }
    }
    private func readReferences() {
        do {
            references = try props.context.capabilities.require(ApplicationCapabilities.executionReferencesUI).read(requestedReferences)
            failure = nil
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
