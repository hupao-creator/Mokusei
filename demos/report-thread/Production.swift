import SwiftUI
import Observation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import MokuseiHarnessCodex
import MokuseiHarnessClaude
@testable import MokuseiApplications
@testable import MokuseiUI

@MainActor @Observable private final class ProductionReportFixture {
    var open = false
    let sample = ReportFixture.groupedSample
    @ObservationIgnored lazy var props: ApplicationThreadProps<NativeReportView> = makeProps()
    private func makeProps() -> ApplicationThreadProps<NativeReportView> {
        let reference = ApplicationThreadRef(threadID: "report-preview", typeID: "report.document")
        let refs = sample.executions.map { ApplicationExecutionRef(thread: .init(threadID: JSONText($0.id), typeID: "agent"), executionID: JSONText($0.id)) }
        let capabilities = try! ApplicationCapabilityAccess<ApplicationRendererPhase>(scope: .init(pluginID: "report", thread: reference), requires: [
            ApplicationCapabilities.executionReferencesUI.requirement,
            ApplicationCapabilities.threadUserActions.requirement,
            ApplicationCapabilities.isolatedHTML.requirement
        ], registrations: [
            .init(ApplicationCapabilities.threadUserActions, value: ApplicationThreadUserActions(setArchived: { _, _, _ in }, initializeConversation: { _, _ in })),
            .init(ApplicationCapabilities.executionReferencesUI, value: ApplicationExecutionReferencesUI(read: { [sample] requested in
                requested.compactMap { ref in
                    guard let item = sample.executions.first(where: { $0.id == ref.executionID.string }) else { return nil }
                    let codex = item.harness == .codex
                    return .init(reference: ref, title: JSONText(item.title), missing: false, running: false,
                        harness: .init(id: codex ? "codex" : "claude", displayName: JSONText(item.harness.rawValue), logoSource: codex ? CodexLogo.source : ClaudeLogo.source), preview: try! .init(startedAt: 0, finishedAt: 138_000, running: false, excerpt: JSONText(item.answer)))
                }
            }, subscribe: { _ in {} }, logo: { id, size in
                id == "codex" ? AnyView(CodexLogo(size: size)) : AnyView(ClaudeLogo(size: size))
            }, execution: { [sample] ref in
                guard let item = sample.executions.first(where: { $0.id == ref.executionID.string }) else { throw PluginContractError("Missing fixture execution") }
                return AnyView(ExecutionReader(execution: item))
            })),
            .init(ApplicationCapabilities.isolatedHTML, value: ApplicationIsolatedHTML { [weak self] source, failure in
                NativeApplicationHTMLSurface(source: source, thread: reference, theme: .light, suppressed: false,
                    readDocument: { source in ApplicationHTMLDocument(html: JSONText(ReportDocument.html), contentRevision: source.contentRevision) },
                    openExternal: { _ in }, onBack: { self?.open = false }, onSettings: {}, onNativeNavigationChange: { _ in }, onFailure: failure)
            })
        ])
        let view = try! NativeReportView(json: .object([
            "emoji": .text(sample.emoji), "shortDescription": .text(sample.shortDescription), "previewText": .text(sample.shortDescription),
            "contentRevision": .text("preview"), "relatedExecutions": .array(refs.map { .object(["thread": $0.thread.json, "executionId": .string($0.executionID)]) })
        ]))
        return .init(entry: .init(ref: reference, revision: 1, createdAt: 0, updatedAt: Date().addingTimeInterval(-46800).timeIntervalSince1970 * 1000,
            title: JSONText(sample.title), archived: false, tags: .init(tags: [], semanticTags: [], directoryTags: [], tagEmojis: [:]), presentations: [], view: view),
            context: .init(theme: .light, locale: "zh-CN", lifetime: PluginLifetime(), domain: .init(pluginID: "report", invoke: { _, _, _, _, _ in throw PluginContractError("Fixture only") }),
                capabilities: capabilities, openThread: { _, _ in }, openExecution: { _ in }))
    }
}

struct ProductionReportPreview: View {
    @State private var fixture = ProductionReportFixture()
    var body: some View {
        ZStack {
            LinearGradient(colors: [.blue.opacity(0.15), .pink.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            if fixture.open {
                NativeReportDetail(props: fixture.props)
                    .modifier(NativeApplicationReadingPanel(enabled: true, identifier: "report-reading-panel", onClose: { fixture.open = false }))
                    .environment(\.nativeApplicationReadingPanel, true)
                    .padding(.horizontal, 48).padding(.top, 74).padding(.bottom, 60)
            } else {
                NativeReportCard(props: fixture.props, projection: .init(previewText: fixture.props.entry.view.shortDescription, relatedThreadCount: 2), openThread: { fixture.open = true })
                    .frame(width: 360, height: 200)
                    .background(NativePalette.overview.surface.swiftUI, in: RoundedRectangle(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(NativePalette.overview.lineSoft.swiftUI))
            }
        }.environment(\.scenePhase, .active).environment(\.locale, Locale(identifier: "zh-Hans"))
            .preferredColorScheme(.light).modifier(NativeWorkspaceWindowSurface())
    }
}
