import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI
import MokuseiCore
import MokuseiHarnessCodex
import MokuseiPluginAPI
@testable import MokuseiPluginUI
@testable import MokuseiUI

struct DemoThread: Identifiable {
    let id: String
    let emoji: String
    let excerpt: String
    let reply: String
    var running = false
}

@MainActor @Observable final class DemoState {
    let productionMode = CommandLine.arguments.contains("--production")
    let productionMotion = NativeReadingPageMotion()
    let identityRegistry = NativeThreadIdentityRegistry()
    var identityVisit: NativeThreadIdentityVisit?
    let canvas = NativeOverviewCanvasState()
    let scene = NativeMokuSceneState()
    let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
    let harness = AnyHarnessPlugin(CodexHarnessPlugin())
    let presentation = try! composeThreadCard(.standard(identity: .init(), extensions: []), layoutContext: .init(availableCols: 3))
    let threads = [
        DemoThread(id: "让阅读回到工作现场", emoji: "🌱", excerpt: "让 Agent Thread 从原卡片展开，保留工作区与 Moku。", reply: "## 让上下文留在身边\n\n展开后的对话是工作区中的一个面板。原来的卡片仍留在原处，其他任务退到背景，Moku 始终在底部。\n\n### 熟悉的阅读布局\n\n标题与 emoji 从原卡片连续移动到阅读位置，正文载入后按实际排版逐行显现。面板两侧保留相同的空间。\n\n### 为阅读留出空间\n\n标签筛选收起，设置入口退场。右侧的继续对话、浏览器和语音讨论以纵向工具组呈现。\n\n这是一份可交互的原生设计提案。"),
        DemoThread(id: "整理原生交互细节", emoji: "🪴", excerpt: "执行中 · 定位最新消息，由下向上揭示。", reply: "## 原生交互细节\n\n面板保留独立关闭入口。按 Escape 或点击关闭按钮，回到刚才的卡片。\n\n- 窗口红绿灯仍属于窗口\n- 面板有自己的关闭按钮\n- Moku 输入保持可用\n- 窗口改变大小时，面板跟随可用空间调整\n\n卡片外壳展开时，标题与 emoji 保持连续；正文加载完成后逐行显现。\n\n### 当前进展\n\n已完成窗口层级检查，正在检查收起后的再次进入。\n\n底部是这次执行的最新消息。页面先跟随到这里，再从最新一行向上展开已有正文。", running: true),
        DemoThread(id: "梳理工作区信息层级", emoji: "🔭", excerpt: "将当前阅读与背景任务分层，保持位置记忆。", reply: "## 工作区中的阅读\n\n背景卡片保留原有布局，弱化后作为空间参照。\n\n阅读面板与右侧工具栏之间留出清晰间距，底部留给常驻的 Moku bar。\n\n### 返回来源\n\n关闭阅读后，原卡片、筛选栏与设置入口一起恢复，继续浏览其他任务。")
    ]
    var selected: DemoThread?
    var expanded = false
    var loaded = false
    var footerVisible = false
    var closing = false
    var returning = false
    var shellVisible = true
    var sourceVisible = false
    var chromeVisible = false
    var slow = false
    var dark = false
    var sidecards: DemoSidecards?
    var frames: [String: CGRect] = [:]
    var returnPanel = CGRect.zero
    var closeDuration: Double { reduceMotion ? 0 : slow ? 1.2 : 0.42 }
    var resolveDuration: Double { closeDuration * 0.35 }
    var source = CGRect.zero
    var viewport = CGSize.zero
    var filter = ""
    var reduceMotion = false
    var panelFrame = CGRect.zero
    var status = ""
    private var transitionID = UUID()
    var duration: Double { reduceMotion ? 0 : slow ? 1.8 : 0.62 }
    var visibleThreads: [DemoThread] { filter == "设计" ? Array(threads.prefix(2)) : threads }

    func open(_ thread: DemoThread) {
        guard selected == nil, let frame = frames[thread.id], frame.width > 0 else { return }
        transitionID = UUID()
        loaded = false; footerVisible = false
        closing = false; returning = false; chromeVisible = false
        shellVisible = true; sourceVisible = false
        source = frame
        if productionMode { identityVisit = identityRegistry.capture(thread.id) }
        selected = thread
        sidecards = DemoSidecards(thread: thread, onBack: { [weak self] in self?.close() })
        sidecards?.reducedMotion = reduceMotion
        // Mount one carrier at the measured card bounds before changing its target.
        let visit = transitionID
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(25))
            guard visit == transitionID, selected != nil else { return }
            let seconds = duration
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: seconds)) { expanded = true }
            try? await Task.sleep(for: .seconds(seconds))
            guard visit == transitionID, selected != nil else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { chromeVisible = true }
            try? await Task.sleep(for: .seconds(0.6))
            guard visit == transitionID, selected != nil else { return }
            loaded = true
        }
    }
    func close() {
        if productionMode { productionMotion.close(); return }
        guard let thread = selected, !closing else { return }
        transitionID = UUID(); let visit = transitionID
        if let current = frames[thread.id] { source = current }
        returnPanel = panelFrame
        // The shell keeps its spatial return; content only crossfades. Keep
        // the detail at fixed layout width so shrinking never reflows its text.
        closing = true
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { chromeVisible = false }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 16))
            guard visit == transitionID else { return }
            let travel = closeDuration
            withAnimation(.timingCurve(0.3, 0, 0.2, 1, duration: travel)) {
                expanded = false; returning = true
            }
            // Overlap the content handoff with the remaining travel; waiting
            // for arrival leaves an empty white carrier after the detail fades.
            try? await Task.sleep(for: .seconds(travel * 0.65))
            guard visit == transitionID else { return }
            withAnimation(.easeOut(duration: resolveDuration)) {
                shellVisible = false; sourceVisible = true
            }
            try? await Task.sleep(for: .seconds(resolveDuration))
            guard visit == transitionID else { return }
            sidecards?.release(); sidecards = nil
            selected = nil
        }
    }
    func finishProductionClose() {
        transitionID = UUID()
        sidecards?.release(); sidecards = nil
        selected = nil; expanded = false; identityVisit = nil
    }
    func target(in size: CGSize) -> CGRect {
        NativeReadingPanelGeometry.frame(in: size)
    }
}

private struct DemoRevealedReply: View {
    @Bindable var state: DemoState
    let answer: String
    let bottomUp: Bool
    @State private var owner = UUID()
    var body: some View {
        ThreadMessage(id: "answer", author: .assistant, content: answer)
            .environment(\.nativeMarkdownLineRevealOwner, owner)
            .environment(\.nativeMarkdownAwaitsLineReveal, !state.reduceMotion && !state.footerVisible)
            .background(DemoLineReveal(owner: owner, bottomUp: bottomUp, slow: state.slow, reducedMotion: state.reduceMotion) {
                guard state.loaded, !state.closing else { return }
                withAnimation(state.reduceMotion ? nil : .easeOut(duration: state.slow ? 0.65 : 0.28)) {
                    state.footerVisible = true
                }
            })
    }
}

private struct PanelDemo: View {
    @Namespace private var identity
    @Bindable var state: DemoState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        NativeMokuScene(state: state.scene) {
            GeometryReader { geometry in
                if state.productionMode {
                    NativeReadingPageStack(open: state.selected != nil, identity: JSONText(state.selected?.id ?? "overview"),
                        motion: state.productionMotion, stationaryParent: true, emphasizedOpening: true,
                        panel: true, panelSource: state.source, panelIdentity: state.identityVisit, threadPanelMotion: true,
                        onClose: state.finishProductionClose) {
                        overview
                    } front: {
                        if let thread = state.selected, let sides = state.sidecards {
                            productionReader(thread, sides: sides)
                        }
                    }
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { state.viewport = $0 }
                } else {
                ZStack(alignment: .topLeading) {
                    overview
                        .blur(radius: state.expanded ? 5 : 0)
                        .opacity(state.expanded ? 0.22 : 1)
                        .allowsHitTesting(state.selected == nil)
                        .accessibilityHidden(state.selected != nil)
                    if let thread = state.selected, let sidecards = state.sidecards {
                        let bounds = state.target(in: geometry.size)
                        let split = DemoSplitLayout(bounds: bounds, snapshot: sidecards.snapshot)
                        carrier(thread, target: state.closing ? state.returnPanel : split.main)
                        DemoSidecardSurfaces(fixture: sidecards, layout: split)
                            .opacity(state.expanded && !state.closing ? 1 : 0)
                            .allowsHitTesting(!state.closing)
                        tools(target: bounds)
                        NativeReadingPanelCloseButton(label: "关闭 Thread · Esc", onClose: state.close)
                            .position(x: split.main.minX + 30, y: split.main.minY + 30)
                            .opacity(state.chromeVisible ? 1 : 0)
                            .allowsHitTesting(state.chromeVisible && !state.closing)
                            .accessibilityHidden(!state.chromeVisible)
                    }
                }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { state.viewport = $0 }
                }
            }
        } thread: { EmptyView() } dock: {
            NativeMokuDock(state: state.scene, draft: state.draft, cwd: "/demo/Mokusei", mode: .idle,
                loadMentionDirectories: { [] }, onSend: { _ in state.status = "已收到（演示）" }, onCancel: {})
        } settings: { EmptyView() }
        .coordinateSpace(name: "panel-stage")
        .coordinateSpace(name: "workspace")
        .modifier(NativeWorkspaceWindowSurface())
        .environment(state)
        .environment(\.nativeThreadIdentityRegistry, state.productionMode ? state.identityRegistry : nil)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        .preferredColorScheme(state.dark ? .dark : .light)
        .onChange(of: reduceMotion, initial: true) { _, value in state.reduceMotion = value; state.sidecards?.reducedMotion = value }
        .onExitCommand { if state.sidecards?.selected != nil { state.sidecards?.choose(nil) } else { state.close() } }
    }
    private var overview: some View {
        NativeOverviewCanvas(items: state.visibleThreads.map { .init(id: $0.id, columns: state.presentation.size.cols, rows: state.presentation.size.rows) },
            sceneKey: state.filter, state: state.canvas, toolbarBottom: 82, bottomReservedHeight: 88,
            cloudAnimationsEnabled: false, interactionPaused: state.selected != nil) { item in
            let thread = state.threads.first { $0.id == item.id }!
            Button { state.open(thread) } label: {
                HarnessThreadCard(identity: .init(title: thread.id,
                harness: .init(brandKey: "codex", label: "Codex", logoSource: state.harness.logoSource),
                model: "GPT-6", effort: "High", excerpt: thread.excerpt),
                presentation: state.presentation, emoji: thread.emoji, harnessLogo: state.harness.logo(size: 12))
                .environment(\.nativeThreadIdentityKey, thread.id)
                .environment(\.threadIdentityTransition, state.productionMode || state.closing ? nil : .init(namespace: identity, id: thread.id,
                    expanded: state.selected?.id == thread.id && state.expanded))
                .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .accessibilityLabel(thread.id)

                .opacity(!state.productionMode && state.selected?.id == thread.id && !state.sourceVisible ? 0 : 1)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("panel-stage")) } action: { state.frames[thread.id] = $0 }
        }
        .overlay(alignment: .top) {
            NativeOverviewChrome(filters: [.init(tag: "Mokusei", count: 3, isDirectory: true), .init(tag: "设计", count: 2)],
                selectedTag: state.filter, onTagChange: { state.filter = $0?.tag ?? "" }, onSettings: { state.dark.toggle() })
                .scaleEffect(x: 1, y: state.expanded ? 0.1 : 1, anchor: .top)
                .opacity(state.expanded ? 0 : 1)
        }
    }
    private func productionReader(_ thread: DemoThread, sides: DemoSidecards) -> some View {
        GeometryReader { bounds in
            let panel = CGRect(origin: .zero, size: CGSize(width: max(1, bounds.size.width - 76), height: bounds.size.height))
            let split = DemoSplitLayout(bounds: panel, snapshot: sides.snapshot)
            ZStack(alignment: .topLeading) {
                reading(thread)
                    .nativeReadingPanelViewport(balancedVerticalInsets: true)
                    .nativeReadingPanelClose(label: "关闭 Thread", onClose: state.close)
                    .nativeReadingEscape(perform: state.close)
                    .frame(width: split.main.width, height: split.main.height)
                    .background(NativePalette.thread.canvas.swiftUI, in: RoundedRectangle(cornerRadius: 22))
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .position(x: split.main.midX, y: split.main.midY)
                DemoSidecardSurfaces(fixture: sides, layout: split)
                tools(target: panel)
            }
        }
    }
    private func carrier(_ thread: DemoThread, target: CGRect) -> some View {
        let rect = state.expanded ? target : state.source
        let escape: (() -> Void)? = state.expanded && state.sidecards?.selected == nil ? { state.close() } : nil
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 22).fill(state.expanded ? NativePalette.thread.canvas.swiftUI : NativePalette.overview.surface.swiftUI)
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(NativePalette.thread.line.swiftUI.opacity(0.6)))
                .shadow(color: .black.opacity(state.expanded ? 0.14 : 0), radius: 30, y: 14)
            reading(thread)
                .frame(width: target.width, height: target.height)
                .opacity(state.returning ? 0 : 1)
                .animation(.easeOut(duration: state.closeDuration * 0.8), value: state.returning)
                .scaleEffect(state.returning ? state.source.width / max(1, target.width) : 1, anchor: .topLeading)

                .frame(width: rect.width, height: rect.height, alignment: .topLeading)
                .allowsHitTesting(state.expanded)
                .accessibilityHidden(!state.expanded)

        }
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .opacity(state.shellVisible ? 1 : 0)
        .allowsHitTesting(!state.closing)
        .nativeReadingEscape(perform: escape)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("panel-stage")) } action: { state.panelFrame = $0 }
        .position(x: rect.midX, y: rect.midY)
    }
    private func reading(_ thread: DemoThread) -> some View {
        ThreadConversation(threadId: JSONText(thread.id), title: thread.id, icon: thread.emoji,
            rows: [conversationRow(thread, history: true), conversationRow(thread, history: false)],
            readingTarget: thread.running ? .init(requestId: "demo-latest", mode: .current,
                executionId: "current-execution", position: .start, follow: true) : nil,
            running: thread.running, runningTurnId: thread.running ? "current-execution" : nil)
            .environment(\.threadIdentityTransition, state.productionMode || state.closing ? nil : .init(namespace: identity, id: thread.id, expanded: state.expanded))
            .environment(\.threadDetailFooterReveal, state.productionMode || state.footerVisible ? 1 : 0)
            .environment(\.nativeThreadContentReveal, state.productionMode)
    }
    private func conversationRow(_ thread: DemoThread, history: Bool) -> ThreadConversationRow {
        let id: JSONText = history ? "previous-execution" : "current-execution"
        let prompt = history ? "先梳理当前工作区的交互结构。" : thread.excerpt
        let answer = history ? "已梳理 Overview、Agent Thread 和 Moku 的呈现关系。接下来可以进一步细化阅读体验。" : thread.reply
        let running = thread.running && !history
        let timestamp: Double = history ? 1793599200000 : 1793602800000
        return ThreadConversationRow(id: id, createdAt: timestamp,
            execution: .init(id: id, prompt: prompt, answer: answer, completedAt: running ? nil : timestamp + 60000),
            node: AnyView(Group {
                if state.productionMode && !state.loaded { NativeReadingPlaceholder(placement: .inline) }
                else { ThreadDetailTurn(id: id,
                author: .object(["model": .text("GPT-6"), "effort": .text("High")]),
                rows: [
                    .init(id: JSONText(id.string + "-user"), kind: .user,
                        node: AnyView(ThreadMessage(id: "user", author: .user, content: prompt))),
                    .init(id: JSONText(id.string + "-work"), kind: .work,
                        node: AnyView(ThreadMessage(id: "work", author: .assistant, content: "检查了 Overview 与原生阅读组件，确认布局和交互入口。"))),
                    .init(id: JSONText(id.string + "-answer"), kind: .content,
                        node: AnyView(Group {
                            if state.loaded {
                                if state.productionMode { ThreadMessage(id: "answer", author: .assistant, content: answer) }
                                else { DemoRevealedReply(state: state, answer: answer, bottomUp: running) }
                            } else {
                                DemoLoadingSkeleton(reducedMotion: state.reduceMotion)
                            }
                        }), finalReply: true)
                ], createdAt: timestamp, updatedAt: timestamp + 60000, status: running ? "running" : "completed",
                completedAt: running ? nil : timestamp + 60000, active: running)
                }
            }))
    }
    private func tools(target: CGRect) -> some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 14) {
                tool("Activity", label: "执行", id: "conversation")
                tool("Globe", label: "浏览器", id: "iab")
                tool("AudioLines", label: "语音讨论", id: "voice")
            }
        }
        .position(x: target.maxX + 38, y: target.midY)
        .opacity(state.expanded && !state.closing ? 1 : 0)
        .offset(x: state.expanded ? 0 : -16)
        .allowsHitTesting(state.expanded && !state.closing)

    }
    private func tool(_ icon: String, label: String, id: JSONText) -> some View {
        Button { state.sidecards?.activate(id) } label: { NativeIcon(name: icon, size: 18).frame(width: 42, height: 42).contentShape(Circle()) }
            .buttonStyle(.plain).glassEffect(.regular.tint(state.sidecards?.selected == id ? .blue.opacity(0.18) : .clear).interactive(), in: .circle)
            .help(label).accessibilityLabel(label).accessibilityValue(state.sidecards?.selected == id ? "已展开" : "已收起")
    }
}

@MainActor final class DemoController {
    let state = DemoState()
    var window: NSWindow?
    func mount() async {
        guard window == nil else { return }
        NativeTypography.registerFonts()
        for _ in 0..<100 {
            window = NSApp.windows.first { $0.identifier?.rawValue == "thread-panel-demo" }
            if window != nil { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard let window else { return }
        window.setContentSize(CGSize(width: 1200, height: 820))
        window.minSize = CGSize(width: 780, height: 580)
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--verify") {
            if state.productionMode { await verifyProduction(window) } else { await verify(window) }
        }
    }
    func capture(_ name: String, window: NSWindow) async throws {
        let content = try await SCShareableContent.currentProcess
        guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw DemoFailure(message: "Missing own window") }
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * window.backingScaleFactor)
        config.height = Int(window.frame.height * window.backingScaleFactor)
        config.showsCursor = false; config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: config)
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("evidence")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
    }
    private func verifyProductionText(_ window: NSWindow, bottomUp: Bool) async throws {
        var texts: [MarkdownTextView] = []
        func collect(_ view: NSView) {
            if let text = view as? MarkdownTextView, text.threadReveal != nil { texts.append(text) }
            view.subviews.forEach(collect)
        }
        for _ in 0..<180 {
            texts.removeAll()
            if let root = window.contentView { collect(root) }
            if texts.first?.threadReveal?.footerVisible == true, texts.allSatisfy({ $0.layer?.mask == nil }) { break }
            try await Task.sleep(for: .milliseconds(16))
        }
        guard let reveal = texts.first?.threadReveal, reveal.animatedLineCount > 3,
              reveal.initialDrawingProtected, reveal.bottomUp == bottomUp, reveal.footerVisible,
              texts.allSatisfy({ !$0.awaitsLineReveal && $0.layer?.mask == nil }) else {
            throw DemoFailure(message: "Production text entrance failed: texts=\(texts.count), lines=\(texts.first?.threadReveal?.animatedLineCount ?? -1), protected=\(String(describing: texts.first?.threadReveal?.initialDrawingProtected)), direction=\(String(describing: texts.first?.threadReveal?.bottomUp)), footer=\(String(describing: texts.first?.threadReveal?.footerVisible)), blocked=\(texts.filter(\.awaitsLineReveal).count), masks=\(texts.filter { $0.layer?.mask != nil }.count)")
        }
    }
    func verifyProduction(_ window: NSWindow) async {
        do {
            try await Task.sleep(for: .seconds(2))
            guard state.frames.count == 3 else { throw DemoFailure(message: "Production card anchors did not mount") }
            state.open(state.threads[0])
            guard let visit = state.identityVisit else { throw DemoFailure(message: "Production source identity was not captured") }
            let identityEvidence = ["card": NSStringFromRect(state.source),
                "leaves": visit.source.mapValues { ["window": NSStringFromRect($0.frame), "local": NSStringFromSize($0.localSize)] }] as [String: Any]
            let evidence = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("evidence")
            try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: identityEvidence, options: .prettyPrinted)
                .write(to: evidence.appendingPathComponent("production-identity.json"))
            try await Task.sleep(for: .milliseconds(220))
            try await capture("production-01-opening", window: window)
            try await Task.sleep(for: .seconds(2))
            guard state.identityVisit?.usedMeasuredDestination == true, !state.productionMotion.active else {
                throw DemoFailure(message: "Production identity did not hand off to the mounted header")
            }
            try await verifyProductionText(window, bottomUp: false)
            try await capture("production-02-ready", window: window)
            state.close()
            try await Task.sleep(for: .milliseconds(280))
            try await capture("production-03-return", window: window)
            try await Task.sleep(for: .seconds(1))
            guard state.selected == nil else { throw DemoFailure(message: "Production close did not retire") }
            state.open(state.threads[1])
            try await Task.sleep(for: .seconds(2))
            try await verifyProductionText(window, bottomUp: true)
            try await capture("production-04-running", window: window)
            state.close()
            try await Task.sleep(for: .seconds(1))
            state.open(state.threads[0])
            try await Task.sleep(for: .milliseconds(100))
            state.close()
            try await Task.sleep(for: .seconds(1))
            guard state.selected == nil else { throw DemoFailure(message: "Production interrupted open did not retire") }
            finish(true, "PASS: production compositor, source identity capture, reader handoff, completed/running content, close and interrupted open")
        } catch { finish(false, String(describing: error)) }
    }
    func verify(_ window: NSWindow) async {
        do {
            try await Task.sleep(for: .seconds(2))
            guard state.frames.count == 3 else { throw DemoFailure(message: "Card geometry did not mount") }
            try await capture("01-overview", window: window)
            state.slow = true
            state.open(state.threads[0])
            try await Task.sleep(for: .milliseconds(200))
            try await capture("02-expanding", window: window)
            try await Task.sleep(for: .seconds(2))
            guard state.expanded else { throw DemoFailure(message: "Panel did not expand") }
            guard !state.footerVisible else { throw DemoFailure(message: "Completion time appeared during loading") }
            try await capture("03-panel", window: window)
            try await Task.sleep(for: .milliseconds(700))
            guard state.loaded else { throw DemoFailure(message: "Body did not load") }
            guard RevealProbe.admittedBeforeFirstPaint else { throw DemoFailure(message: "Text was visible before line mask admission") }
            guard RevealProbe.revealedLineCount > 3 else { throw DemoFailure(message: "TextKit line reveal did not mount") }
            try await capture("03a-line-reveal", window: window)
            try await Task.sleep(for: .seconds(4))
            guard state.footerVisible else { throw DemoFailure(message: "Completion time did not join the reveal") }
            try await capture("03b-body-ready", window: window)
            try verifyPanelMargins()
            var measurements = [["viewport": NSStringFromSize(state.viewport), "panel": NSStringFromRect(state.panelFrame)]]
            guard let sides = state.sidecards else { throw DemoFailure(message: "Sidecard sessions did not mount") }
            let retained = sides.sessions.mapValues(ObjectIdentifier.init)
            var splitMeasurements: [[String: String]] = []
            for (id, name): (JSONText, String) in [("conversation", "06-input-split"), ("iab", "07-browser-split"), ("voice", "08-voice-split")] {
                sides.activate(id)
                try await Task.sleep(for: .milliseconds(650))
                try await waitForSidecardSettlement()
                try verifySplit(stacked: false)
                splitMeasurements.append(["id": id.string, "main": NSStringFromRect(state.panelFrame), "side": NSStringFromRect(sides.measuredFrames[id]!)])
                try await capture(name, window: window)
            }
            sides.activate("conversation")
            try await Task.sleep(for: .milliseconds(500))
            let layout = DemoSplitLayout(bounds: state.target(in: state.viewport), snapshot: sides.snapshot)
            sides.resize(440, maximum: layout.maximumWidth)
            try await Task.sleep(for: .milliseconds(250))
            try await waitForSidecardSettlement()
            try verifySplit(stacked: false)
            try await capture("09-resized-input", window: window)
            sides.activate("iab")
            try await Task.sleep(for: .milliseconds(80))
            sides.activate("voice")
            try await Task.sleep(for: .milliseconds(80))
            sides.activate("conversation")
            try await Task.sleep(for: .milliseconds(650))
            guard abs((sides.measuredFrames["conversation"]?.width ?? 0) - 440) < 1,
                  sides.sessions.mapValues(ObjectIdentifier.init) == retained,
                  sides.sessions["conversation"]?.context.suppressed == false else {
                throw DemoFailure(message: "Switching lost retained width, plugin sessions or final selection")
            }
            sides.activate("conversation")
            try await Task.sleep(for: .milliseconds(500))
            try verifyPanelMargins()
            state.close()
            try await Task.sleep(for: .milliseconds(220))
            try await capture("04-closing", window: window)
            try await Task.sleep(for: .milliseconds(400))
            try await capture("04a-shell-return", window: window)
            try await Task.sleep(for: .milliseconds(600))
            try await capture("04b-card-resolving", window: window)
            try await Task.sleep(for: .seconds(2))
            guard state.selected == nil else { throw DemoFailure(message: "Close did not restore overview") }
            state.slow = false; state.dark = true
            window.setContentSize(CGSize(width: 820, height: 620))
            try await Task.sleep(for: .seconds(1))
            state.open(state.threads[1])
            try await Task.sleep(for: .seconds(1))
            try await capture("05-narrow-dark", window: window)
            try verifyPanelMargins()
            measurements.append(["viewport": NSStringFromSize(state.viewport), "panel": NSStringFromRect(state.panelFrame)])
            try JSONSerialization.data(withJSONObject: measurements, options: .prettyPrinted).write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("evidence/panel-geometry.json"))
            state.sidecards?.activate("iab")
            try await Task.sleep(for: .milliseconds(650))
            try await waitForSidecardSettlement()
            try verifySplit(stacked: true)
            try await capture("10-narrow-stacked", window: window)
            splitMeasurements.append(["id": "iab-stacked", "main": NSStringFromRect(state.panelFrame), "side": NSStringFromRect(state.sidecards!.measuredFrames["iab"]!)])
            try JSONSerialization.data(withJSONObject: splitMeasurements, options: .prettyPrinted).write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("evidence/split-geometry.json"))
            state.close()
            try await Task.sleep(for: .seconds(1))
            state.open(state.threads[2])
            try await Task.sleep(for: .milliseconds(100))
            state.close()
            try await Task.sleep(for: .seconds(1))
            guard state.selected == nil else { throw DemoFailure(message: "Interrupted opening did not retire") }
            state.slow = true
            state.open(state.threads[1])
            try await Task.sleep(for: .seconds(2.7))
            guard state.loaded, RevealProbe.admittedBeforeFirstPaint,
                  RevealProbe.revealOrder.count > 3,
                  zip(RevealProbe.revealOrder, RevealProbe.revealOrder.dropFirst()).allSatisfy({ $0 >= $1 }) else {
                throw DemoFailure(message: "Running reply did not reveal from its bottom line upward")
            }
            try await capture("11-running-bottom-up", window: window)
            try await Task.sleep(for: .seconds(4))
            state.close()
            try await Task.sleep(for: .seconds(2.5))
            state.reduceMotion = true
            state.open(state.threads[0])
            try await Task.sleep(for: .seconds(1))
            guard state.loaded, state.footerVisible else { throw DemoFailure(message: "Reduced motion did not show body and completion time") }
            state.close()
            try await Task.sleep(for: .milliseconds(100))
            guard state.selected == nil else { throw DemoFailure(message: "Reduced motion did not close") }
            finish(true, "PASS: symmetric margins, three native sidecards, separated split frames, per-card resize retention, rapid switching, stacked narrow layout, close and interrupted opening")
        } catch { finish(false, String(describing: error)) }
    }
    private func waitForSidecardSettlement() async throws {
        // Native/WebKit mounting can occupy the main actor beyond the nominal
        // animation sleep. Assert after its real lifecycle settles, not a timer guess.
        for _ in 0..<125 {
            guard let fixture = state.sidecards else { throw DemoFailure(message: "Sidecard visit retired while settling") }
            if !fixture.transitioning { return }
            try await Task.sleep(for: .milliseconds(16))
        }
        throw DemoFailure(message: "Sidecard transition did not settle within two seconds")
    }
    private func verifySplit(stacked: Bool) throws {
        guard let fixture = state.sidecards, let id = fixture.selected, let side = fixture.measuredFrames[id] else {
            throw DemoFailure(message: "Selected sidecard did not mount: selected=\(String(describing: state.sidecards?.selected)), frames=\(String(describing: state.sidecards?.measuredFrames)), cards=\(String(describing: state.sidecards?.cards.map(\.id)))")
        }
        let main = state.panelFrame
        let bounds = state.target(in: state.viewport)
        let gap = stacked ? side.minY - main.maxY : side.minX - main.maxX
        guard !main.intersects(side), abs(gap - 16) < 1,
              abs(main.minX - bounds.minX) < 1, abs(side.maxX - bounds.maxX) < 1,
              abs(main.minY - bounds.minY) < 1, abs(side.maxY - bounds.maxY) < 1,
              stacked || (main.width >= 359 && side.width >= 319),
              fixture.sessions[id]?.context.expanded == true,
              fixture.sessions[id]?.context.suppressed == false else {
            throw DemoFailure(message: "Split geometry or plugin visibility failed: main=\(main), side=\(side), bounds=\(bounds), selected=\(id), expanded=\(String(describing: fixture.sessions[id]?.context.expanded)), suppressed=\(String(describing: fixture.sessions[id]?.context.suppressed)), transitioning=\(fixture.transitioning), dragging=\(fixture.dragging)")
        }
    }
    private func verifyPanelMargins() throws {
        let left = state.panelFrame.minX
        let right = state.viewport.width - state.panelFrame.maxX
        guard abs(left - 76) < 1, abs(left - right) < 1,
              abs(state.panelFrame.minY - 58) < 1,
              state.panelFrame.maxY < state.viewport.height - 70 else {
            throw DemoFailure(message: "Panel margins are unequal or cover the Dock seat")
        }
    }
    private func finish(_ ok: Bool, _ message: String) {
        let result = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("result.json")
        try? JSONSerialization.data(withJSONObject: ["ok": ok, "message": message], options: .prettyPrinted).write(to: result)
        exit(ok ? 0 : 1)
    }
}
private struct DemoFailure: Error { let message: String }

@main @MainActor private struct Demo: App {
    @State private var controller = DemoController()
    init() {
        do { try prepareIsolatedNativeReplay() } catch { print(error); exit(1) }
    }
    var body: some Scene {
        Window("Agent Thread · Panel Transition", id: "thread-panel-demo") {
            PanelDemo(state: controller.state).task { await controller.mount() }
        }.nativeWorkspaceWindowStyle().defaultSize(width: 1200, height: 820)
        .commands {
            CommandMenu("演示") {
                Button("打开第一个 Thread") { controller.state.open(controller.state.threads[0]) }.keyboardShortcut("1")
                Button("关闭面板") { controller.state.close() }.keyboardShortcut("w", modifiers: [.command, .shift])
                Toggle("慢速转场", isOn: Binding(get: { controller.state.slow }, set: { controller.state.slow = $0 })).keyboardShortcut("s", modifiers: [.command, .shift])
                Toggle("深色外观", isOn: Binding(get: { controller.state.dark }, set: { controller.state.dark = $0 })).keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }
}
