import MokuseiCore
import MokuseiPluginAPI
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
        .init(footprint: .init(columns: 1, rows: 1), structureKey: "report:1x1", excerpt: entry.view.previewText,
              view: .init(previewText: entry.view.previewText, relatedThreadCount: entry.view.relatedExecutions.count))
    }
    func card(props: ApplicationThreadProps<NativeReportView>, projection: NativeReportCardProjection, openThread: @escaping () -> Void) -> some View {
        NativeReportCard(props: props, projection: projection, openThread: openThread)
    }
    func detail(props: ApplicationThreadProps<NativeReportView>) -> some View { NativeReportDetail(props: props) }
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

private struct NativeReportDetail: View {
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
