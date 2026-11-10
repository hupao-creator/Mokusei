import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import MokuseiHarnessCodex
import MokuseiHarnessClaude
import SwiftUI
@testable import MokuseiApplications

@MainActor final class ReportFixture {
    let props: ApplicationThreadProps<NativeReportView>

    init(_ sample: ReportSample, now: Date) throws {
        let reference = ApplicationThreadRef(threadID: JSONText(sample.id), typeID: "report.document")
        let refs = ["codex", "claude"].map { harness in
            ApplicationExecutionRef(thread: .init(threadID: JSONText("\(sample.id)-\(harness)"), typeID: "agent"),
                                    executionID: JSONText("\(sample.id)-\(harness)-execution"))
        }
        let capabilities = try ApplicationCapabilityAccess<ApplicationRendererPhase>(
            scope: .init(pluginID: "report", thread: reference), requires: [
                ApplicationCapabilities.executionReferencesUI.requirement,
                ApplicationCapabilities.threadUserActions.requirement
            ], registrations: [
                .init(ApplicationCapabilities.threadUserActions, value: ApplicationThreadUserActions(
                    setArchived: { _, _, _ in throw PluginContractError("Demo does not archive reports") },
                    initializeConversation: { _, _ in throw PluginContractError("Demo has no conversation") })),
                .init(ApplicationCapabilities.executionReferencesUI, value: ApplicationExecutionReferencesUI(
                    read: { requested in requested.map { ref in
                        let codex = ref.thread.threadID.string.hasSuffix("codex")
                        return .init(reference: ref, title: JSONText(sample.title), emoji: sample.emoji,
                                     missing: false, running: false,
                                     harness: .init(id: codex ? "codex" : "claude", displayName: codex ? "Codex" : "Claude"), preview: nil)
                    } }, subscribe: { _, _ in {} }, logo: { id, size in
                        id == "codex" ? AnyView(CodexLogo(size: size)) : AnyView(ClaudeLogo(size: size))
                    }, execution: { _ in throw PluginContractError("Demo has no live execution") }))
            ])
        let view = try NativeReportView(json: .object([
            "coverRevision": .text("cover-\(sample.id)"), "contentRevision": .text("demo-v1"),
            "emoji": .text(sample.emoji), "shortDescription": .text(sample.summary), "previewText": .text(sample.summary),
            "relatedExecutions": .array(refs.map { .object(["thread": $0.thread.json, "executionId": .string($0.executionID)]) })
        ]))
        let cardProps = ApplicationThreadProps(entry: .init(ref: reference, revision: 1, createdAt: 0,
            updatedAt: now.addingTimeInterval(-3600).timeIntervalSince1970 * 1000,
            title: JSONText(sample.title), archived: false,
            tags: .init(tags: sample.tags.map { JSONText($0) }, semanticTags: [], directoryTags: [], tagEmojis: [:]),
            presentations: [], view: view), context: .init(theme: .light, locale: "zh-CN", lifetime: PluginLifetime(),
                domain: .init(pluginID: "report", invoke: { _, operation, _, _, _ in
                    guard operation == "report.cover" else { throw PluginContractError("Demo supports only report.cover") }
                    return .object(["html": .text(Self.cover(sample)), "contentRevision": .text("cover-\(sample.id)")])
                }), capabilities: capabilities, openThread: { _, _ in }, openExecution: { _ in }))
        props = cardProps

    }

    private static func cover(_ sample: ReportSample) -> String {
        // All interpolated values are authored fixture constants; no external HTML input.
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>*{box-sizing:border-box}html,body{margin:0;width:100%;height:100%;overflow:hidden}
        body{background:\(sample.color);color:#f6efdd;font-family:Georgia,serif;padding:27px 28px}
        .label{font:10px -apple-system,sans-serif;letter-spacing:2.5px;opacity:.75}
        .symbol{height:169px;display:flex;align-items:center;font-size:116px;letter-spacing:-9px}
        .caption{font-size:19px;letter-spacing:-.4px}.line{height:1px;background:#ffffff35;margin:17px 0 14px}
        </style></head><body><div class="label">SUPER THREAD / FIELD NOTES</div>
        <div class="symbol">\(sample.symbol)</div><div class="caption">\(sample.caption)</div>
        <div class="line"></div></body></html>
        """
    }
}

struct ProductionCard: View {
    let fixture: ReportFixture
    let open: () -> Void
    var body: some View {
        NativeReportCard(props: fixture.props,
            projection: .init(previewText: fixture.props.entry.view.shortDescription, relatedThreadCount: 2), openThread: open)
            .frame(width: 360, height: 456)
    }
}
