// Shared production glass fixture; current Dock retained during tool integration.
import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import MokuseiHarnessCodex
import MokuseiHarnessClaude
import MokuseiHarnessPi
import MokuseiHarnessOpenCode
@testable import MokuseiApplications
@testable import MokuseiUI

@MainActor @Observable final class GlassFixture {
    let state = NativeOverviewCanvasState()
    let moku = NativeMokuSceneState()
    let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
    var glassWorld = true
    var dark = false
    @ObservationIgnored var frames: [String: CGRect] = [:]
    @ObservationIgnored var appearances: [String: Int] = [:]
    let standard = try! composeThreadCard(.standard(identity: .init(), extensions: []), layoutContext: .init(availableCols: 3))
    let plan = try! composeThreadCard(.standard(identity: .init(), extensions: [.todo(steps: [
        .init(step: "Inspect the production canvas", status: .completed),
        .init(step: "Keep semantic controls visible", status: .inProgress),
        .init(step: "Review light and dark appearance", status: .pending),
    ])]), layoutContext: .init(availableCols: 3))
    var items: [NativeOverviewItem] {
        [.init(id: "codex", columns: plan.size.cols, rows: plan.size.rows, completed: true),
         .init(id: "claude", completed: false), .init(id: "pi", completed: true),
         .init(id: "opencode", completed: false), .init(id: "report")]
    }
    let report: ApplicationThreadProps<NativeReportView>
    init() {
        let reference = ApplicationThreadRef(threadID: "fixture-report", typeID: "report.document")
        let references = ApplicationExecutionReferencesUI(read: { _ in [] }, subscribe: { _ in {} },
            logo: { _, _ in AnyView(EmptyView()) })
        let capabilities = try! ApplicationCapabilityAccess<ApplicationRendererPhase>(
            scope: .init(pluginID: "report", thread: reference), requires: [
                ApplicationCapabilities.executionReferencesUI.requirement,
                ApplicationCapabilities.threadUserActions.requirement,
            ], registrations: [
                .init(ApplicationCapabilities.executionReferencesUI, value: references),
                .init(ApplicationCapabilities.threadUserActions, value: ApplicationThreadUserActions(
                    setArchived: { _, _, _ in }, initializeConversation: { _, _ in })),
            ])
        let view = try! NativeReportView(json: .object([
            "previewText": .text("Production Report summary. The document title, excerpt, archive and open actions remain readable."),
            "contentRevision": .text("fixed-revision"), "relatedExecutions": .array([]),
        ]))
        report = .init(entry: .init(ref: reference, revision: 1, createdAt: 1, updatedAt: 1,
            title: "Report · Glass review", archived: false,
            tags: .init(tags: [], semanticTags: [], directoryTags: [], tagEmojis: [:]), presentations: [], view: view),
            context: .init(theme: .light, locale: "en-US", lifetime: PluginLifetime(),
                domain: .init(pluginID: "report", invoke: { _, _, _, _, _ in throw PluginContractError("No runtime in this fixture") }),
                capabilities: capabilities, openThread: { _, _ in }, openExecution: { _ in }))
    }
}

struct GlassSurface: View {
    let fixture: GlassFixture
    var body: some View {
        ZStack {
            // A fixed backdrop makes the material difference reviewable in each
            // screenshot without depending on the user's desktop wallpaper.
            LinearGradient(colors: [Color(red: 0.72, green: 0.80, blue: 0.87),
                                    Color(red: 0.68, green: 0.71, blue: 0.82),
                                    Color(red: 0.85, green: 0.77, blue: 0.69)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(fixture.dark ? Color.black.opacity(0.65) : Color.clear)
            NativeOverviewCanvas(items: fixture.items, sceneKey: "glass-fixed", state: fixture.state,
                                 selectionID: "all", cloudAnimationsEnabled: false, glassWorld: fixture.glassWorld) { item in
                card(item.id)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("glass-capture")) } action: { fixture.frames[item.id] = $0 }
                    .onAppear { fixture.appearances[item.id, default: 0] += 1 }
            }
        }
        .overlay(alignment: .top) {
            NativeOverviewChrome(filters: [
                .init(tag: "OpenAgent", scope: "fixture", count: 5, isDirectory: true),
                .init(tag: "Review", emoji: "🔎", count: 3),
            ], onTagChange: { _ in }, onSettings: {}, onRestart: {})
        }
        .overlay {
            // Use the workspace Dock, including its own bottom-center layout.
            // An inactive scene freezes blinking without copying the brand drawing.
            NativeMokuDock(state: fixture.moku, draft: fixture.draft, cwd: "/isolated/glass",
                onSend: { _ in }, onCancel: {})
                .environment(\.scenePhase, .inactive)
        }
        .coordinateSpace(name: "glass-capture")
        .preferredColorScheme(fixture.dark ? .dark : .light)
        .environment(\.locale, Locale(identifier: "en-US"))
    }
    @ViewBuilder private func card(_ id: String) -> some View {
        switch id {
        case "report":
            NativeReportCard(props: fixture.report,
                projection: .init(previewText: fixture.report.entry.view.previewText, relatedThreadCount: 0), openThread: {})
        case "codex":
            harness("Codex · Canvas material", brand: .init(brandKey: "codex", label: "Codex", logoSource: CodexHarnessPlugin().logoSource),
                model: "GPT-6", emoji: "🔬", completed: true, plan: true,
                logo: AnyView(CodexHarnessPlugin().logo(size: 12)))
        case "claude":
            harness("Claude · Running review", brand: .init(brandKey: "claude", label: "Claude", logoSource: ClaudeHarnessPlugin().logoSource),
                model: "Claude Sonnet", emoji: "🧭", completed: false,
                logo: AnyView(ClaudeHarnessPlugin().logo(size: 12)))
        case "pi":
            harness("Pi · Completed inspection", brand: .init(brandKey: "pi", label: "Pi Agent", logoSource: PiHarnessPlugin().logoSource),
                model: "Gemini Pro", emoji: "🧩", completed: true,
                logo: AnyView(PiHarnessPlugin().logo(size: 12)))
        default:
            harness("OpenCode · Running checks", brand: .init(brandKey: "opencode", label: "OpenCode", logoSource: OpenCodeHarnessPlugin().logoSource),
                model: "GPT-6", emoji: "🛠️", completed: false,
                logo: AnyView(OpenCodeHarnessPlugin().logo(size: 12)))
        }
    }
    private func harness(_ title: String, brand: ThreadCardHarnessBrand, model: String, emoji: String,
                         completed: Bool, plan: Bool = false, logo: AnyView) -> some View {
        HarnessThreadCard(identity: .init(title: title, harness: brand, model: model, effort: "High",
            runtime: .init(startedAt: 0, endedAt: 362_000),
            excerpt: completed ? "Completed work stays visible. Emoji, completion mark and follow-up remain production controls."
                               : "Running work keeps its semantic content and controls while the outer card material changes."),
            presentation: plan ? fixture.plan : fixture.standard, onFollowUp: {},
            status: completed ? .init(kind: .completed, label: "Completed", terminal: .completed)
                              : .init(kind: .running, label: "Running"),
            emoji: emoji, harnessLogo: logo)
    }
}
