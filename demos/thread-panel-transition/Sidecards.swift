import Observation
import SwiftUI
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import MokuseiSidecardConversation
import MokuseiSidecardBrowser
import MokuseiSidecardVoice
@testable import MokuseiUI

/// The fixture owns only selection and mock capabilities. Actual plugin sessions
/// remain mounted while folded, so their editors and drafts survive switching.
@MainActor @Observable final class DemoSidecards {
    let thread: HarnessThread
    let modules = [AnySidecardPlugin(NativeConversationSidecard()), AnySidecardPlugin(NativeBrowserSidecard()), AnySidecardPlugin(NativeVoiceSidecard())]
    var selected: JSONText?
    var lastSelected: JSONText?
    var widths: [JSONText: CGFloat] = [:]
    var dragging = false
    var transitioning = false
    var revision = 0
    var reducedMotion = false
    var sessions: [JSONText: SidecardSession] = [:]
    var measuredFrames: [JSONText: CGRect] = [:]
    @ObservationIgnored private var transitionTask: Task<Void, Never>?
    @ObservationIgnored private var handlers: [JSONText: [UUID: (SidecardIntent) -> Bool]] = [:]
    @ObservationIgnored private var retired = false
    @ObservationIgnored private let onBack: () -> Void
    @ObservationIgnored private var muted = false
    @ObservationIgnored lazy var voice: SidecardVoiceCapability = SidecardVoiceCapability(
        state: voiceState(.closed),
        start: { [weak self] in await MainActor.run { self?.setVoicePhase(.listening) } },
        stop: { [weak self] in await MainActor.run { self?.setVoicePhase(.closed) } },
        toggleMute: { [weak self] in guard let self else { return }; muted.toggle(); voice.publish(voiceState(voice.state.phase)) },
        refresh: {})

    init(thread: DemoThread, onBack: @escaping () -> Void) {
        self.thread = try! HarnessThread(id: JSONText(thread.id), harnessID: "codex", revision: 0,
            sessionState: .null, observation: .init(latestExecution: try! .init(executionID: "demo-running-execution", status: .running, startedAt: 1793602800000)), cwd: "/demo/Mokusei", settings: .object([:]),
            createdAt: 0, updatedAt: 0, title: JSONText(thread.id), tags: [])
        self.onBack = onBack
        for module in modules { sessions[module.descriptor.id] = try! module.makeSession(context: context(module.descriptor.id)) }
    }
    var cards: [NativeSidecardWorkspaceCard] {
        modules.compactMap { module in
            guard let session = sessions[module.descriptor.id], !session.isReleased else { return nil }
            return NativeSidecardWorkspaceCard(id: module.descriptor.id, icon: module.icon, view: try! session.view())
        }
    }
    var snapshot: NativeSidecardWorkspaceSnapshot {
        .init(input: .init(thread: thread), cards: cards, selected: selected, lastSelected: lastSelected,
            selectionRevision: revision, transitioning: transitioning, dragging: dragging, widths: widths,
            executionDisabled: false, suppressed: false, handoff: nil, focusLauncherOnClose: true)
    }
    func activate(_ id: JSONText) {
        choose(selected == id ? nil : id)
        if selected == id {
            for handler in handlers[id]?.values ?? [:].values { _ = handler(try! SidecardIntent(.activate)) }
        }
    }
    func choose(_ id: JSONText?) {
        guard !retired, selected != id else { return }
        transitionTask?.cancel()
        revision += 1
        let visit = revision
        withAnimation(reducedMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.38)) {
            selected = id
            if let id { lastSelected = id }
            transitioning = !reducedMotion
            update()
        }
        transitionTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(self?.reducedMotion == true ? 0 : 380)) } catch { return }
            guard let self, !retired, revision == visit else { return }
            transitioning = false; update()
        }
    }
    func resize(_ width: CGFloat, maximum: CGFloat) {
        guard let id = selected ?? lastSelected else { return }
        widths[id] = min(max(320, maximum), max(320, width))
    }
    func setDragging(_ value: Bool) { dragging = value; update() }
    func release() {
        retired = true; transitionTask?.cancel()
        for session in sessions.values { session.release() }
        sessions = [:]; handlers = [:]
    }
    private func update() {
        for (id, session) in sessions { try! session.update(context: context(id)) }
    }
    private func setVoicePhase(_ phase: SidecardVoiceState.Phase) { voice.publish(voiceState(phase)) }
    private func voiceState(_ phase: SidecardVoiceState.Phase) -> SidecardVoiceState {
        .init(phase: phase, supported: true, available: true, loading: false, muted: muted, error: "",
            messages: [try! .init(id: "demo-voice-note", sessionID: "demo-voice", role: .assistant,
                text: "这里是本地语音讨论示例。演示不会开启麦克风或连接语音服务。", complete: true, createdAt: 1793602800000)])
    }
    private func context(_ id: JSONText) -> SidecardContext {
        let actions = HarnessThreadActions(interrupt: {}, respond: { _ in }, invokeHarnessExtension: { _, _ in .null },
            forkThread: { _ in "demo-fork" }, openExternal: { _ in }, openFollowUp: { _ in })
        return SidecardContext(thread: thread, conversationIndex: .init(executionIDs: ["previous-execution", "current-execution", "demo-running-execution"], hasInheritedHistory: false),
            actions: actions, readingTarget: nil, executionDisabled: false, expanded: selected == id,
            transitioning: transitioning, suppressed: selected != id || transitioning || dragging,
            conversation: { _, _ in AnyView(ThreadMessage(id: "demo-execution", author: .assistant,
                content: "正在整理交互细节。\n\n这是本地执行 fixture，不会提交真实任务。").padding(24)) }, voice: voice,
            open: { [weak self] in self?.choose(id); return self?.revision ?? 0 },
            close: { [weak self] in if self?.selected == id { self?.choose(nil) } },
            selectionRevision: { [weak self] in self?.revision ?? 0 },
            onIntent: { [weak self] handler in
                let token = UUID(); self?.handlers[id, default: [:]][token] = handler
                return { [weak self] in self?.handlers[id]?[token] = nil }
            }, send: { _ in .init(executionID: "demo-submitted") },
            stageAttachments: { _ in [] }, discardAttachments: { _ in }, backToOverview: onBack)
    }
}

@MainActor struct DemoSplitLayout {
    let main: CGRect
    let side: CGRect
    let stacked: Bool
    let maximumWidth: CGFloat
    let cardWidth: CGFloat
    init(bounds: CGRect, snapshot: NativeSidecardWorkspaceSnapshot) {
        let geometry = NativeSidecardWorkspaceGeometry(size: bounds.size, snapshot: snapshot)
        stacked = geometry.stacked; maximumWidth = geometry.maximumCardWidth; cardWidth = geometry.cardWidth
        main = CGRect(x: bounds.minX, y: bounds.minY, width: geometry.mainWidth, height: geometry.mainHeight)
        side = CGRect(x: bounds.minX + geometry.surfaceX, y: bounds.minY + geometry.surfaceY,
                      width: geometry.surfaceWidth, height: geometry.surfaceHeight)
    }
}

@MainActor struct DemoSidecardSurfaces: View {
    let fixture: DemoSidecards
    let layout: DemoSplitLayout
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(fixture.cards) { card in
                let open = fixture.selected == card.id
                card.view.content
                    .frame(width: layout.side.width, height: layout.side.height, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .background(NativePalette.thread.canvas.swiftUI, in: RoundedRectangle(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(NativePalette.thread.line.swiftUI.opacity(0.6)))
                    .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
                    .scaleEffect(open ? 1 : 0.96, anchor: .trailing)
                    .opacity(open ? 1 : 0)
                    .allowsHitTesting(open)
                    .disabled(!open || fixture.dragging)
                    .accessibilityHidden(!open)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("panel-stage")) } action: { fixture.measuredFrames[card.id] = $0 }
                    .position(x: layout.side.midX, y: layout.side.midY)
            }
            if fixture.selected != nil && !layout.stacked {
                NativeSidecardDivider(width: layout.cardWidth, maximumWidth: layout.maximumWidth,
                    onWidthChange: { fixture.resize($0, maximum: layout.maximumWidth) }, onDraggingChange: fixture.setDragging)
                    .frame(width: 6, height: layout.main.height)
                    .position(x: layout.main.maxX + 8, y: layout.main.midY)
                    .accessibilityLabel("调整侧栏卡片宽度")
            }
        }
        .animation(fixture.reducedMotion || fixture.dragging ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.38), value: layout.stacked)
    }
}
