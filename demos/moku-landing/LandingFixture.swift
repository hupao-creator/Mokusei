import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI
import MokuseiCore
import MokuseiHarnessCodex
import MokuseiPluginAPI
@testable import MokuseiPluginUI
@testable import MokuseiUI

@MainActor @Observable final class LandingFixture {
    enum Outcome: String, CaseIterable { case success = "创建成功", failure = "创建前失败", waiting = "保持派发中" }
    let scene = NativeMokuSceneState()
    let canvas = NativeOverviewCanvasState()
    let draft = NativeComposerDraft(services: .init(stageFiles: { files, _ in
        files.map { .init(id: JSONText(UUID().uuidString), path: "/fixture/attachment",
            name: JSONText($0.name), mimeType: JSONText($0.mimeType), size: $0.size,
            kind: $0.mimeType.hasPrefix("image/") ? .image : .file) }
    }, discardAttachments: { _ in }))
    let card = try! composeThreadCard(.standard(identity: .init(), extensions: []),
                                    layoutContext: .init(availableCols: 3))
    var outcome = Outcome.success
    var hasThread = false
    var archived = false
    var filteredEmpty = false
    var original = false
    var dark = false
    var running = false
    var prompt = "优化 landing page，让首个任务从 Moku 开始。"
    var status = "没有会话 · 中心输入"
    var openControls: () -> Void = {}
    var dispatchHarness = AnyHarnessPlugin(CodexHarnessPlugin())
    var dispatchModel = "GPT-6"
    @ObservationIgnored private var epoch = 0
    var landing: Bool { !original && (!hasThread || archived) }
    var items: [NativeOverviewItem] {
        hasThread && !archived && !filteredEmpty ? [.init(id: "first-task", columns: card.size.cols, rows: card.size.rows)] : []
    }
    let directories: [NativeComposerDirectory] = [
        .init(name: "Mokusei", path: "/demo/Mokusei"),
        .init(name: "Design", path: "/demo/Design"),
        .init(name: "Research", path: "/demo/Research"),
    ]

    func reset() {
        epoch += 1; running = false; hasThread = false; archived = false
        filteredEmpty = false; original = false; draft.text = ""; draft.clearError()
        for directory in draft.directories { draft.removeDirectory(directory.path) }
        scene.dismissTalk()
        scene.setInputOpen(true)
        status = "没有会话 · 中心输入"
        Task { for attachment in draft.attachments { await draft.removeAttachment(attachment.id) } }
    }
    func archive() {
        epoch += 1; running = false; archived = true; filteredEmpty = false; original = false
        status = "全部会话已归档 · 重新居中"
    }
    func filterToEmpty() {
        epoch += 1; running = false; hasThread = true; archived = false
        original = false; filteredEmpty = true; status = "会话仍存在 · 筛选无结果"
    }
    func send(_ submission: NativeComposerSubmission) async throws {
        let captured = epoch
        let selected = outcome
        prompt = submission.text.isEmpty ? "整理选中的目录与附件" : submission.text
        running = true; status = "Moku 已收到输入 · 正在派发"
        let pending = operation(completed: false, success: false)
        precondition(NativeMokuDispatch(operation: pending, executionIsActive: true)?.phase == .dispatching)
        try await Task.sleep(for: .milliseconds(1300))
        while selected == .waiting && captured == epoch {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard captured == epoch else { throw CancellationError() }
        running = false
        let dispatch = NativeMokuDispatch(operation: operation(completed: true, success: selected == .success), executionIsActive: false)!
        if dispatch.phase == .started {
            // The fixture publishes a successful public create_thread result;
            // the real Dock owns the resulting geometry and input transition.
            scene.retainDraft(draft, seal: true)
            hasThread = true; archived = false; filteredEmpty = false
            status = "首个任务创建成功 · Moku 回到底部"
        } else {
            status = "创建前失败 · 中心输入和草稿保留"
            throw PluginContractError("任务未创建，请调整后重试。")
        }
    }
    func stop() { epoch += 1; running = false; status = "已停止 · 尚未创建任务" }
    func simulate(_ outcome: Outcome) {
        guard !draft.submitting else { return }
        reset(); self.outcome = outcome
        draft.text = "优化 landing page，让首个任务从 Moku 开始。"
        // Demo controls only submit fixture data. Return and the arrow in the
        // main window still go through the production Dock's send path.
        Task { await draft.submit { try await self.send($0) } }
    }
    func addContext() async {
        _ = draft.insertDirectory(directories[0])
        if draft.attachments.isEmpty {
            await draft.importFiles([.init(data: Data("Moku landing notes".utf8), name: "landing-notes.txt", mimeType: "text/plain")])
        }
    }
    private func operation(completed: Bool, success: Bool) -> JSONValue {
        var value: [JSONText: JSONValue] = ["name": .text("create_thread"),
            "arguments": .object(["harnessId": .string(dispatchHarness.descriptor.id), "prompt": .text(prompt)])]
        if completed {
            value["completedAt"] = .integer(1)
            value["isError"] = .bool(!success)
            value["result"] = .object(["ok": .bool(success), "threadId": success ? .text("first-task") : .null])
        }
        return .object(value)
    }
}

struct LandingSurface: View {
    let fixture: LandingFixture
    var showsDock = true
    var dockOpacity = 1.0
    var glassWorld = true
    var body: some View {
        NativeMokuScene(state: fixture.scene) {
            GeometryReader { geometry in
                let viewport = NativeOverviewWorkspaceView.viewport(in: geometry.size,
                    hasFilters: fixture.hasThread && !fixture.archived, hasDock: true)
                ZStack {
                    NativeOverviewCanvas(items: fixture.items, sceneKey: fixture.filteredEmpty ? "filtered" : "all", state: fixture.canvas,
                        toolbarBottom: viewport.toolbarBottom, bottomReservedHeight: viewport.bottomReservedHeight,
                        cloudAnimationsEnabled: false, glassWorld: glassWorld, interactionPaused: fixture.scene.interactionPaused) { _ in
                        HarnessThreadCard(identity: .init(title: "优化 landing page",
                            harness: .init(brandKey: fixture.dispatchHarness.descriptor.id.string,
                                label: fixture.dispatchHarness.descriptor.displayName.string, logoSource: fixture.dispatchHarness.logoSource),
                            model: fixture.dispatchModel, effort: "High", excerpt: fixture.prompt),
                            presentation: fixture.card, onFollowUp: { fixture.scene.setInputOpen(true) },
                            status: .init(kind: .running, label: "进行中"), emoji: "🌱",
                            harnessLogo: fixture.dispatchHarness.logo(size: 12))
                    }
                    if fixture.original && fixture.items.isEmpty {
                        NativeOverviewEmptyState(title: "还没有会话", detail: "切换标签筛选以查看其他 Thread。")
                    } else if fixture.filteredEmpty && !fixture.landing {
                        NativeOverviewEmptyState(title: "没有匹配的会话", detail: "试试其他关键词、清空搜索，或切换标签范围。")
                    }
                }
                .overlay(alignment: .top) {
                    NativeOverviewChrome(filters: fixture.hasThread && !fixture.archived
                        ? [.init(tag: "Mokusei", scope: "demo", count: 1, isDirectory: true)] : [],
                        onTagChange: { _ in fixture.filteredEmpty = false }, onSettings: fixture.openControls)
                }
            }
        } thread: { EmptyView() } dock: {
            if showsDock {
                NativeMokuDock(state: fixture.scene, draft: fixture.draft, cwd: "/demo",
                    landing: fixture.landing, mode: fixture.running ? .running : .idle, running: fixture.running,
                    loadMentionDirectories: { fixture.directories },
                    onSend: fixture.send, onCancel: fixture.stop)
                    .opacity(dockOpacity)
                    .allowsHitTesting(dockOpacity == 1)
                    .accessibilityHidden(dockOpacity < 1)
            }
        } settings: { EmptyView() }
        .overlay(alignment: .topLeading) { NativeWindowNavigationView(action: nil) }
        .coordinateSpace(name: "workspace")
        .modifier(NativeWorkspaceWindowSurface())
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        .preferredColorScheme(fixture.dark ? .dark : .light)
    }
}
