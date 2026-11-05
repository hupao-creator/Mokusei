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
    @State private var referencesRevealed = false
    @Environment(\.nativeReportSidecards) private var sharedSidecards
    @FocusState private var launcherFocused: Bool
    @Environment(\.nativeReadingEntranceReady) private var entranceReady
    @Environment(\.nativeReadingAuxiliarySuppressed) private var suppressed
    @Environment(\.nativeReportPanelReturn) private var returning
    @Environment(\.nativeReadingAuxiliaryLauncherPosition) private var launcherPosition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var locale: JSONText { props.context.locale }
    private var sidecards: NativeReportSidecardPresentation { sharedSidecards ?? localSidecards }
    private var expanded: Bool { sidecards.active == .relatedExecutions }
    var body: some View {
        GeometryReader { geometry in
            let layout = NativeSidecardWorkspaceGeometry(size: geometry.size, open: expanded,
                preferredWidth: selected == nil ? 0.3 : 0.5)
            let source = launcherPosition.map { CGRect(x: $0.x - 21, y: $0.y - 21, width: 42, height: 42) }
            ZStack(alignment: .topLeading) {
                NativeReportHTML(props: props)
                    .onPreferenceChange(NativeApplicationHTMLReadinessKey.self) { readiness in
                        guard let readiness else { sidecards.updateDocument(nil); return }
                        guard readiness.thread == props.entry.ref,
                              readiness.source.contentRevision == props.entry.view.contentRevision else { return }
                        sidecards.updateDocument(readiness)
                    }
                    .modifier(NativeReportDocumentFrame(size: CGSize(width: layout.mainWidth, height: layout.mainHeight)))
                VStack(alignment: .leading, spacing: 0) {
                    if let selected {
                        execution(selected).id(selected)
                            .overlay(alignment: .topLeading) {
                                Button { if !sidecards.retainingForReturn { self.selected = nil } } label: {
                                    Image(systemName: "chevron.left")
                                        .font(.system(size: 12, weight: .semibold))
                                        .frame(width: 36, height: 36)
                                        .contentShape(Circle())
                                        .glassEffect(.regular.interactive(), in: Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(applicationText(locale, "返回关联执行", "Back to related executions"))
                                .padding(12)
                            }
                    } else {
                        referencesContent
                            .opacity(reduceMotion || referencesRevealed ? 1 : 0)
                    }
                }
                .environment(\.nativeReadingNavigation, nil)
                // Selection animates the shell, not insertion/removal or the
                // initial native layout of its newly mounted execution reader.
                // Later reader-owned animation transactions remain independent.
                .transaction(value: selected) { $0.animation = nil }
                .clipShape(RoundedRectangle(cornerRadius: 21))
                .modifier(NativeSidecardFold(progress: expanded ? 1 : 0, source: source,
                    destination: CGRect(x: layout.surfaceX, y: layout.surfaceY,
                        width: layout.surfaceWidth, height: layout.surfaceHeight),
                    frameIdentifier: "report-executions-sidecard", reportReturn: true))
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
                    sidecards.updateLayout(ready: entranceReady, suppressed: suppressed, retainingForReturn: returning != nil)
                }
            }
            .preference(key: NativeReportExecutionInputKey.self,
                value: expanded && !suppressed && returning == nil ? selected.map {
                    NativeReportExecutionInput(reference: $0, frame: CGRect(x: layout.surfaceX, y: layout.surfaceY,
                        width: layout.surfaceWidth, height: layout.surfaceHeight))
                } : nil)
        }
        .onAppear {
            do { unsubscribe = try props.context.capabilities.require(ApplicationCapabilities.executionReferencesUI).subscribe(refresh); refresh() }
            catch { failure = error.localizedDescription }
        }
        .onDisappear { unsubscribe?(); unsubscribe = nil; sidecards.cancel(); entranceAdmitted = false }
        .onChange(of: expanded) { _, open in
            if open && !referencesRevealed {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { referencesRevealed = true }
            }
        }
        .onChange(of: [entranceReady && entranceAdmitted && !suppressed, returning != nil]) { _, _ in
            sidecards.updateLayout(ready: entranceReady && entranceAdmitted && !suppressed,
                suppressed: suppressed, retainingForReturn: returning != nil)
            if returning == nil { refresh() }
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

    private var referencesContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(applicationText(locale, "关联执行", "Related executions"))
                Text(String(references.count)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }.font(NativeTypography.inter(size: 12, weight: 600)).padding(18)
            Divider()
            NativeScrollView {
                GlassEffectContainer(spacing: 8) {
                    VStack(alignment: .leading, spacing: 14) {
                        if let failure { Text(failure).foregroundStyle(.red) }
                        if references.isEmpty {
                            Text(applicationText(locale, "暂无关联执行", "No related executions"))
                                .foregroundStyle(.secondary).padding(12)
                        }
                        ForEach(references, id: \.reference) { item in
                            NativeReportExecutionRow(item: item, locale: locale,
                                visible: expanded && !suppressed && (reduceMotion || referencesRevealed)) {
                                if !sidecards.retainingForReturn { selected = item.reference }
                            }
                        }
                    }.padding(16)
                }
            }
        }
    }

    private var auxiliaryBack: NativeReadingAuxiliaryBackAction? {
        guard expanded || sidecards.pending == .relatedExecutions else { return nil }
        let selectionID = sidecards.selectionID
        let reference = selected
        let referenceID = reference.map { $0.thread.threadID.string + ":" + $0.executionID.string } ?? ""
        return NativeReadingAuxiliaryBackAction(id: selectionID.uuidString + referenceID) {
            guard !sidecards.retainingForReturn, selectionID == sidecards.selectionID, reference == selected,
                  sidecards.active == .relatedExecutions || sidecards.pending == .relatedExecutions else { return }
            if expanded && selected != nil { selected = nil }
            else { sidecards.close(); launcherFocused = true }
        }
    }

    private func refresh() {
        guard !sidecards.retainingForReturn else { return }
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

/// HTML must receive the shell's presented size, not its final size ahead of
/// travel: a centered responsive page otherwise jumps before the shell moves.
/// Keep interpolation below the retained document so only its viewport relayouts.
private struct NativeReportDocumentFrame: ViewModifier, @MainActor Animatable {
    var size: CGSize
    @Environment(\.nativeReportPanelReturn) private var returning
    @State private var presentation = ReportDocumentPresentation()

    var animatableData: CGSize.AnimatableData {
        get { size.animatableData }
        set { size.animatableData = newValue }
    }

    func body(content: Content) -> some View {
        let size = presentation.size(size, retaining: returning != nil)
        content
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .nativeReadingPanelViewport(topInset: 8, balancedVerticalInsets: true)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(NativePalette.thread.canvas.swiftUI, in: RoundedRectangle(cornerRadius: 22))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(NativePalette.thread.line.swiftUI.opacity(0.6)))
            // `size` already contains this animation frame's interpolation.
            // A second implicit animation would put WebKit behind its shell.
            .transaction(value: size) { $0.animation = nil }
            .nativeReportMainReturn(size: size)
    }
}

/// A render-only memo, not observable application state. Save the interpolated
/// size below the animation boundary so Close during width travel retains the
/// last presented document layout instead of snapping to its destination width.
@MainActor private final class ReportDocumentPresentation {
    private var presented: CGSize?
    func size(_ proposed: CGSize, retaining: Bool) -> CGSize {
        if !retaining || presented == nil { presented = proposed }
        return presented ?? proposed
    }
}
