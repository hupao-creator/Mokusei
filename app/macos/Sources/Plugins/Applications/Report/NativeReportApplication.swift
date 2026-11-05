import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

@MainActor public enum NativeReportApplication {
    public static func make() throws -> ApplicationPluginModule {
        let manifest = try ApplicationPluginManifest(id: "report", displayName: "Report", contributes: .init(
            backgroundAgents: ["report.agent"], threadTypes: ["report.document"], settings: ["report.settings"],
            collections: ["report.records"], queries: ["report.read", "report.list", "report.html"], commands: ["report.create", "report.update"]))
        return try ApplicationPluginModule(manifest: manifest, threads: [AnyApplicationThreadPlugin(ReportThreadPlugin())],
                                           settings: [AnyApplicationSettingsPlugin(ReportSettingsPlugin())])
    }
}

@MainActor private struct ReportThreadPlugin: ApplicationThreadPlugin {
    var type: ApplicationValueKey<NativeReportView> { NativeReportContracts.thread }
    var requires: [ApplicationCapabilityRequirement] {
        [ApplicationCapabilities.executionReferencesUI.requirement, ApplicationCapabilities.threadUserActions.requirement,
         ApplicationCapabilities.isolatedHTML.requirement]
    }
    func projectCard(entry: ApplicationThreadCatalogEntry<NativeReportView>, availableColumns: Int,
                     capabilities: ApplicationCapabilityAccess<ApplicationProjectionPhase>) throws -> HarnessOverviewProjection<NativeReportCardProjection> {
        .init(footprint: .init(columns: 1, rows: 1), structureKey: "report:1x1", excerpt: entry.view.shortDescription,
              view: .init(previewText: entry.view.shortDescription, relatedThreadCount: entry.view.relatedExecutions.count))
    }
    func card(props: ApplicationThreadProps<NativeReportView>, projection: NativeReportCardProjection, openThread: @escaping () -> Void) -> some View {
        NativeReportCard(props: props, projection: projection, openThread: openThread)
    }
    func detail(props: ApplicationThreadProps<NativeReportView>) -> some View {
        NativeReportDetail(props: props).id(props.entry.ref)
    }
}

@MainActor private struct ReportSettingsPlugin: ApplicationSettingsPlugin {
    var key: ApplicationValueKey<ApplicationBackgroundExecutionSettings> { nativeBackgroundSettingsKey("report.settings", owner: "report") }
    let label: JSONText = "Report Agent"
    let requires = [ApplicationCapabilities.backgroundConfigurationUI.requirement]
    func settings(props: ApplicationSettingsProps<ApplicationBackgroundExecutionSettings>) -> some View {
        NativeBackgroundSettingsView(props: props,
            description: applicationText(props.locale, "按目录范围自动整理和更新报告，共用此处的执行设置。", "Organize and update reports within each directory scope using these shared execution settings."))
    }
}

private struct NativeReportHTML: View {
    let props: ApplicationThreadProps<NativeReportView>
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            switch Result(catching: { () throws -> (ApplicationIsolatedHTML, ApplicationHTMLSource) in
                let capability = try props.context.capabilities.require(ApplicationCapabilities.isolatedHTML)
                let source = try ApplicationHTMLSource(query: NativeReportContracts.html, input: props.entry.ref.threadID,
                                                      contentRevision: props.entry.view.contentRevision)
                return (capability, source)
            }) {
            case .failure(let error): NativeApplicationFailure(message: error.localizedDescription)
            case .success(let (capability, source)):
                // The surface owns loading errors and Retry for this visit.
                capability.surface(source: source) { _ in }
            }
        }
    }
}

struct NativeReportDetail: View {
    let props: ApplicationThreadProps<NativeReportView>
    @State private var references: [ApplicationExecutionPresentation] = []
    @State private var selected: ApplicationExecutionRef?
    @State private var unsubscribe: (() -> Void)?
    @State private var failure: String?
    @State private var localSidecards = NativeReportSidecardPresentation()
    @State private var entranceAdmitted = false
    @Environment(\.nativeReportSidecards) private var sharedSidecards
    @FocusState private var launcherFocused: Bool
    @Environment(\.nativeReadingEntranceReady) private var entranceReady
    @Environment(\.nativeReadingAuxiliarySuppressed) private var suppressed
    @Environment(\.nativeReadingAuxiliaryLauncherPosition) private var launcherPosition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var locale: JSONText { props.context.locale }
    private var sidecards: NativeReportSidecardPresentation { sharedSidecards ?? localSidecards }
    private var expanded: Bool { sidecards.active == .relatedExecutions }
    var body: some View {
        GeometryReader { geometry in
            let layout = NativeSidecardWorkspaceGeometry(size: geometry.size, open: expanded,
                preferredWidth: selected == nil ? 0.2 : 0.5)
            let source = launcherPosition.map { CGRect(x: $0.x - 21, y: $0.y - 21, width: 42, height: 42) }
            ZStack(alignment: .topLeading) {
                NativeReportHTML(props: props)
                    .onPreferenceChange(NativeApplicationHTMLReadinessKey.self) { readiness in
                        guard let readiness else { sidecards.updateDocument(nil); return }
                        guard readiness.thread == props.entry.ref,
                              readiness.source.contentRevision == props.entry.view.contentRevision else { return }
                        sidecards.updateDocument(readiness)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .nativeReadingPanelViewport(topInset: 8, balancedVerticalInsets: true)
                    .frame(width: layout.mainWidth, height: layout.mainHeight)
                    // Match Agent reflow: commit the native document's final
                    // size once while its surrounding shell travels.
                    .offset(x: -layout.mainWidth / 2)
                    .transaction(value: CGSize(width: layout.mainWidth, height: layout.mainHeight)) { $0.animation = nil }
                    .offset(x: layout.mainWidth / 2)
                    .frame(width: layout.mainWidth, height: layout.mainHeight)
                    .background(NativePalette.thread.canvas.swiftUI, in: RoundedRectangle(cornerRadius: 22))
                    // The document adopts its destination size before the shell
                    // arrives; clip after the animated frame, not only inside HTML.
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(NativePalette.thread.line.swiftUI.opacity(0.6)))
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        if selected != nil {
                            Button { selected = nil } label: {
                                Label(applicationText(locale, "关联执行", "Related executions"), systemImage: "chevron.left")
                            }.buttonStyle(.plain)
                        } else {
                            Text(applicationText(locale, "关联执行", "Related executions"))
                            Text(String(references.count)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }.font(NativeTypography.inter(size: 12, weight: 600)).padding(18)
                    Divider()
                    if let selected {
                        execution(selected).id(selected)
                    } else {
                        NativeScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                if let failure { Text(failure).foregroundStyle(.red) }
                                if references.isEmpty { Text(applicationText(locale, "暂无关联执行", "No related executions")).foregroundStyle(.secondary).padding(12) }
                                ForEach(references, id: \.reference) { item in
                                    Button { selected = item.reference } label: {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(item.title.string).font(NativeTypography.inter(size: 13, weight: 550)).lineLimit(3)
                                            HStack(spacing: 5) {
                                                if let harness = item.harness {
                                                    ThreadCardBrandLogo(logoSource: harness.logoSource, label: harness.displayName.string, brandKey: harness.id.string)
                                                }
                                                if item.missing { Text(applicationText(locale, "已删除", "Deleted")) }
                                                Spacer(minLength: 0)
                                                if let usage = item.usage { Text(usage.value.string) }
                                            }.font(NativeTypography.inter(size: 10)).foregroundStyle(.secondary)
                                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12).contentShape(Rectangle())
                                    }.buttonStyle(.plain).disabled(item.missing)
                                }
                            }.padding(8)
                        }
                    }
                }
                .environment(\.nativeReadingNavigation, nil)
                .clipShape(RoundedRectangle(cornerRadius: 21))
                .modifier(NativeSidecardFold(progress: expanded ? 1 : 0, source: source,
                    destination: CGRect(x: layout.surfaceX, y: layout.surfaceY,
                        width: layout.surfaceWidth, height: layout.surfaceHeight),
                    frameIdentifier: "report-executions-sidecard"))
                // Retain the execution reader while folded, but exclude native
                // controls and accessibility until this surface is expanded.
                .allowsHitTesting(expanded && !suppressed)
                .disabled(!expanded || suppressed)
                .accessibilityHidden(!expanded || suppressed)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(applicationText(locale, "关联执行", "Related executions"))
            }
            .animation(reduceMotion ? nil : NativeSidecardTiming.foldAnimation, value: expanded)
            .animation(reduceMotion ? nil : NativeSidecardTiming.foldAnimation, value: selected)
            .animation(reduceMotion ? nil : NativeSidecardTiming.foldAnimation, value: layout.stacked)
            .background {
                NativeReadingEntranceStage(enabled: entranceReady && !suppressed && !entranceAdmitted) {
                    entranceAdmitted = true
                    sidecards.updateLayout(ready: entranceReady, suppressed: suppressed)
                }
            }
        }
        .onAppear {
            do { unsubscribe = try props.context.capabilities.require(ApplicationCapabilities.executionReferencesUI).subscribe(refresh); refresh() }
            catch { failure = error.localizedDescription }
        }
        .onDisappear { unsubscribe?(); unsubscribe = nil; sidecards.cancel(); entranceAdmitted = false }
        .onChange(of: entranceReady && entranceAdmitted && !suppressed) { _, ready in
            sidecards.updateLayout(ready: ready, suppressed: suppressed)
        }
        .onChange(of: props.entry.view.contentRevision) { _, _ in sidecards.updateDocument(nil) }
        .onChange(of: props.entry.view.relatedExecutions) { _, _ in refresh() }
        .preference(key: NativeReadingAuxiliaryToolbarKey.self, value: AnyView(
            NativeSidecardToggle(expanded: expanded || sidecards.pending == .relatedExecutions,
                label: applicationText(locale, "关联执行", "Related executions"), action: {
                    sidecards.toggle(.relatedExecutions)
                    launcherFocused = !expanded
                }) {
                    NativeIcon(name: "PanelRight", size: 17, strokeWidth: 1.8)
                }
                .focused($launcherFocused)
                .disabled(!entranceAdmitted || suppressed)
                .accessibilityIdentifier("sidecard-toggle-report-executions")
        ))
        .preference(key: NativeReadingAuxiliaryBackKey.self, value: auxiliaryBack)
    }

    private var auxiliaryBack: NativeReadingAuxiliaryBackAction? {
        guard expanded || sidecards.pending == .relatedExecutions else { return nil }
        let selectionID = sidecards.selectionID
        let reference = selected
        let referenceID = reference.map { $0.thread.threadID.string + ":" + $0.executionID.string } ?? ""
        return NativeReadingAuxiliaryBackAction(id: selectionID.uuidString + referenceID) {
            guard selectionID == sidecards.selectionID, reference == selected,
                  sidecards.active == .relatedExecutions || sidecards.pending == .relatedExecutions else { return }
            if expanded && selected != nil { selected = nil }
            else { sidecards.close(); launcherFocused = true }
        }
    }

    private func refresh() {
        do {
            references = try props.context.capabilities.require(ApplicationCapabilities.executionReferencesUI).read(props.entry.view.relatedExecutions)
            if let selected, !references.contains(where: { $0.reference == selected && !$0.missing }) { self.selected = nil }
            failure = nil
        } catch { failure = error.localizedDescription }
    }
    @ViewBuilder private func execution(_ reference: ApplicationExecutionRef) -> some View {
        switch Result(catching: { try props.context.capabilities.require(ApplicationCapabilities.executionReferencesUI).execution(reference) }) {
        case .success(let view): view
        case .failure(let error): NativeApplicationFailure(message: error.localizedDescription)
        }
    }
}
