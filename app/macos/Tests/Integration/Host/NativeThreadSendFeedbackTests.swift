import AppKit
import Observation
import QuartzCore
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiCore
import MokuseiPluginAPI
@testable import MokuseiPluginUI
import MokuseiSidecardConversation
import MokuseiSidecardBrowser
import MokuseiSidecardVoice
@testable import MokuseiHarnessCodex
@testable import MokuseiUI

@MainActor @Observable private final class SendFeedbackOtherPresentation {}
@MainActor private final class SendFeedbackThreadOwner {
    var thread: HarnessThread
    var backs = 0
    var voiceMediaActions = 0
    weak var voicePresentation: VoiceSidecardPresentation?
    weak var voiceLifetime: PluginLifetime?
    init(_ thread: HarnessThread) { self.thread = thread }
}

extension RuntimeClient {
    fileprivate func sendFeedbackSubscriptions() -> [(String, RuntimeContentScope)] {
        contentResources.map { ($0.key, $0.value.scope) }
    }
}

private struct SendFeedbackLayout: View {
    let model: NativeSidecardWorkspaceModel
    let reduceMotion: Bool
    var body: some View {
        if let snapshot = model.snapshot { NativeSidecardWorkspaceLayout(model: model, snapshot: snapshot, motionReduced: reduceMotion) }
    }
}

@MainActor @Observable private final class SendFeedbackComposerMount {
    var visible = true
}

private struct SendFeedbackComposerLayout: View {
    let mount: SendFeedbackComposerMount
    let model: NativeSidecardWorkspaceModel
    let presentation: NativeWorkspacePresentation
    let scene: NativeMokuSceneState
    let draft: NativeComposerDraft
    let onSend: (NativeComposerSubmission) async throws -> Void

    var body: some View {
        let route = presentation.navigationRouteID
        if mount.visible {
            VStack(spacing: 0) {
                SendFeedbackLayout(model: model, reduceMotion: false)
                    .environment(\.nativeAgentInputTargetChanged, { owner, target in
                        presentation.updateAgentInput(owner: owner, target: target, route: route)
                        print("COMPOSER_TARGET time=\(ProcessInfo.processInfo.systemUptime) owner=\(owner) execution=\(String(describing: target?.executionID?.string)) ready=\(String(describing: target?.ready))")
                    })
                NativeMokuDock(state: scene, draft: draft, cwd: "/tmp", threadTitle: "Thread",
                    disabled: !presentation.dockInputAvailable, onSend: onSend, onCancel: {})
                    .frame(height: 100)
            }
            .environment(\.scenePhase, .active)
        }
    }
}

@MainActor @Observable private final class FoldProbeState {
    var available: Set<JSONText> = ["a", "b", "c"]
    var presses = 0
    var size: CGSize?
    @ObservationIgnored var viewBuilds = 0
}

private struct FoldProbeLayout: View {
    let model: NativeSidecardWorkspaceModel
    let state: FoldProbeState
    let width: CGFloat
    var body: some View {
        SendFeedbackLayout(model: model, reduceMotion: false)
            .frame(width: state.size?.width ?? width, height: state.size?.height ?? 620)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct FoldProbeCard: SidecardPlugin {
    let id: JSONText
    let state: FoldProbeState
    var descriptor: SidecardPluginDescriptor { .init(id: id, displayName: id) }
    var icon: some View { Text(id.string) }
    func makePresentation(context: SidecardContext, lifetime: PluginLifetime) -> SendFeedbackOtherPresentation { .init() }
    func sidecard(context: SidecardContext, presentation: SendFeedbackOtherPresentation) throws -> SidecardView<some View> {
        state.viewBuilds += 1
        return try SidecardView(available: state.available.contains(id), label: id, preferredWidth: 0.4) {
            Color(red: 1, green: 0, blue: 1).overlay {
                Button("Probe action") { state.presses += 1 }
            }
        }
    }
}

private struct SendFeedbackOtherCard: SidecardPlugin {
    let descriptor = SidecardPluginDescriptor(id: "other", displayName: "Other")
    var icon: some View { Text("O") }
    func makePresentation(context: SidecardContext, lifetime: PluginLifetime) -> SendFeedbackOtherPresentation { .init() }
    func sidecard(context: SidecardContext, presentation: SendFeedbackOtherPresentation) throws -> SidecardView<Text> {
        try SidecardView(available: true, label: "Other", preferredWidth: 1 / 3) { Text("Other activity") }
    }
}

/// Capture the owner created by the production plugin without replacing its
/// update, rendering or scroll implementation with a test surface.
private struct SendFeedbackVoiceCard: SidecardPlugin {
    let owner: SendFeedbackThreadOwner
    private let plugin = NativeVoiceSidecard()
    var descriptor: SidecardPluginDescriptor { plugin.descriptor }
    var icon: some View { plugin.icon }
    func makePresentation(context: SidecardContext, lifetime: PluginLifetime) -> VoiceSidecardPresentation {
        let presentation = plugin.makePresentation(context: context, lifetime: lifetime)
        owner.voicePresentation = presentation; owner.voiceLifetime = lifetime
        return presentation
    }
    func updatePresentation(_ presentation: VoiceSidecardPresentation, context: SidecardContext) {
        plugin.updatePresentation(presentation, context: context)
    }
    func sidecard(context: SidecardContext, presentation: VoiceSidecardPresentation) throws -> SidecardView<VoiceSidecardContent> {
        try plugin.sidecard(context: context, presentation: presentation)
    }
}

@MainActor @Suite(.serializedNative, .serialized)
struct NativeThreadSendFeedbackTests {
    @MainActor private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let client: RuntimeClient
        let host: NativeHarnessHost
        let model: NativeSidecardWorkspaceModel
        let owner: SendFeedbackThreadOwner
        let services: NativeSidecardWorkspaceServices
        var configuration: NativeSidecardWorkspaceConfiguration
        var pump: Task<Void, Never>?
        var holdDestination = false
        var destinationError = false
        var sourceSubscriptions: Set<String> = []
        var settleNewRow = false
        var publishedSettledNewRow = false
        var additionalReply: String?

        init(execution: JSONText = "old", status: PublicExecution.Status = .completed, allCards: Bool = false, foldProbe: FoldProbeState? = nil) throws {
            client = RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory))
            let thread = try Self.thread(execution, status: status)
            let owner = SendFeedbackThreadOwner(thread)
            self.owner = owner
            let transcript = try VoiceTranscriptMessage(id: "retained-reply", sessionID: "past-call", role: .assistant,
                text: "Retained voice transcript", complete: true, createdAt: 1)
            let voice = allCards ? SidecardVoiceCapability(state: .init(phase: .closed, supported: false, available: false,
                loading: false, muted: false, error: "", messages: [transcript]),
                start: { owner.voiceMediaActions += 1 }, stop: { owner.voiceMediaActions += 1 },
                toggleMute: { owner.voiceMediaActions += 1 }, refresh: {}) : nil
            services = NativeSidecardWorkspaceServices(send: { _, _ in throw CancellationError() },
                stageAttachments: { _ in [] }, discardAttachments: { _ in }, openExternal: { _ in }, voice: voice)
            host = NativeHarnessHost(client: client, registry: try HarnessPluginRegistry([AnyHarnessPlugin(CodexHarnessPlugin())]), currentThread: { _ in owner.thread },
                callbacks: .init(openExternal: { _ in }, openFollowUp: { _, _ in }, onError: { _ in }))
            configuration = .init(input: .init(thread: thread), executionDisabled: false, suppressed: false,
                enabledIDs: nil, locale: Locale(identifier: "en-US"))
            let modules = foldProbe.map { state in
                ["a", "b", "c"].map { AnySidecardPlugin(FoldProbeCard(id: JSONText($0), state: state)) }
            } ?? ([AnySidecardPlugin(NativeConversationSidecard()), AnySidecardPlugin(SendFeedbackOtherCard())]
                + (allCards ? [AnySidecardPlugin(NativeBrowserSidecard()), AnySidecardPlugin(SendFeedbackVoiceCard(owner: owner))] : []))
            model = NativeSidecardWorkspaceModel(harnessHost: host,
                registry: try SidecardPluginRegistry(modules),
                configuration: configuration, services: services, onBack: { owner.backs += 1 }, onVisibilityChange: { _ in })
            update()
        }
        static func thread(_ execution: JSONText, status: PublicExecution.Status, archived: Bool = false) throws -> HarnessThread {
            try HarnessThread(id: "thread", harnessID: "codex", revision: 1, sessionState: .null,
                observation: .init(latestExecution: try .init(executionID: execution, status: status, startedAt: 1,
                    finishedAt: status == .running || status == .waitingForUser ? nil : 2,
                    interactions: status == .waitingForUser ? [.init(id: "permission", kind: .permission, title: "Allow?",
                        actions: [.init(id: "allow", intent: .allow, label: "Allow")], questions: [])] : [])),
                cwd: "/tmp", settings: .object([:]), createdAt: 0, updatedAt: 1, title: "Thread", tags: [], archived: archived)
        }
        func update() {
            owner.thread = configuration.input.thread
            model.update(configuration: configuration, services: services, onBack: { [owner] in owner.backs += 1 }, onVisibilityChange: { _ in })
        }
        func observe(_ execution: JSONText = "new", status: PublicExecution.Status = .running, archived: Bool = false) throws {
            configuration.input = .init(thread: try Self.thread(execution, status: status, archived: archived),
                readingTarget: configuration.input.readingTarget)
            update()
        }
        func index(_ ids: [JSONText] = ["old", "new"]) async throws {
            let index = ThreadConversationIndex(executionIDs: ids, hasInheritedHistory: false)
            model.receiveIndex(index)
            // receiveIndex deliberately defers publication out of View.body.
            try await Task.sleep(for: .milliseconds(10))
        }
        func request(_ id: UUID, accepted: JSONText? = nil) {
            configuration.executionReveal = .init(id: id, receipt: accepted.map(SidecardSendReceipt.init))
            update()
        }
        func startContentPump() {
            pump = Task { @MainActor [weak self] in
                var published: [String: JSONValue] = [:]
                while !Task.isCancelled {
                    guard let self else { return }
                    for (id, scope) in await client.sendFeedbackSubscriptions() {
                        if scope == .turn(key: "turn:new"), !sourceSubscriptions.contains(id) {
                            if holdDestination { continue }
                            if destinationError {
                                if published[id] != .text("destination-error") {
                                    host.receive(.threadContent(subscriptionId: id, state: .error("Destination fixture error")))
                                    published[id] = .text("destination-error")
                                }
                                continue
                            }
                        }
                        let state = contentState(for: scope)
                        if published[id] != state {
                            host.receive(.threadContent(subscriptionId: id, state: .ready(state)))
                            published[id] = state
                            if scope == .turn(key: "turn:new"), settleNewRow { publishedSettledNewRow = true }
                        }
                    }
                    do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                }
            }
        }
        func contentState(for scope: RuntimeContentScope) -> JSONValue {
            let state = contentState
            switch scope {
            case .thread: return state
            case .turn(let key), .execution(let key):
                let turns = state["turns"]!.arrayValue!.filter { JSONText("turn:" + $0["executionId"]!.stringValue!) == key }
                let row = JSONValue.object(["schema": state["schema"]!, "updatedAt": state["updatedAt"]!,
                    "backgroundTerminals": .array([]), "turns": .array(turns)])
                // Match the runtime's completed-row envelope. Execution detail
                // stays full; active rows become deferred at settlement.
                if case .turn = scope, let turn = turns.first,
                   !["running", "waiting-input"].contains(turn["status"]!.stringValue!) {
                    return .object(["kind": .text("deferred-execution"), "state": row, "nonempty": .array([])])
                }
                return row
            }
        }
        var contentState: JSONValue {
            .object(["schema": .text("mokusei.harness.codex.thread.v1"), "updatedAt": .integer(additionalReply == nil ? 4 : 5),
                "backgroundTerminals": .array([]), "turns": .array(["old", "new"].map { id in
                    let latest = configuration.input.thread.observation.latestExecution
                    let active = latest?.executionID == JSONText(id) && configuration.input.thread.observation.isExecutionActive && !(id == "new" && settleNewRow)
                    let text = id == "old" ? "Previous main execution" : "New execution becomes the main result"
                    var turn: [JSONText: JSONValue] = ["executionId": .text(id), "status": .text(active ? "running" : "completed"),
                        "createdAt": .integer(id == "old" ? 1 : 2), "updatedAt": .integer(4),
                        "answer": .text(text), "reasoning": .text(""),
                        "author": .object(["model": .text(id == "new" && settleNewRow ? "settled-model" : "gpt-6.1-sol"), "effort": .text("high")]),
                        "messages": .array([.object(["id": .text(id + "-reply"), "role": .text("assistant"), "kind": .text("answer"),
                            "content": .text(text), "createdAt": .integer(3), "attachments": .array([])])]),
                        "timeline": .array([.object(["id": .text(id + "-reply"), "kind": .text("assistant"), "itemId": .text(id + "-native-reply"),
                            "content": .text(text), "status": .text("complete"), "createdAt": .integer(3)])]),
                        "activities": .array([]), "interactions": .array([]), "plan": .array([]), "notices": .array([])]
                    if id == "new", let additionalReply {
                        turn["updatedAt"] = .integer(5)
                        turn["answer"] = .text(text + "\n\n" + additionalReply)
                        turn["messages"] = .array(turn["messages"]!.arrayValue! + [.object([
                            "id": .text("new-reply-2"), "role": .text("assistant"), "kind": .text("answer"),
                            "content": .text(additionalReply), "createdAt": .integer(4), "attachments": .array([])])])
                        turn["timeline"] = .array(turn["timeline"]!.arrayValue! + [.object([
                            "id": .text("new-reply-2"), "kind": .text("assistant"), "itemId": .text("new-native-reply-2"),
                            "content": .text(additionalReply), "status": .text("complete"), "createdAt": .integer(4)])])
                    }
                    if !active { turn["finishedAt"] = .integer(4) }
                    return .object(turn)
                })])
        }
        func close() async {
            pump?.cancel(); await pump?.value
            model.release(); await host.releaseAll(); await client.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test(.requiresDisplay)
    func settlingScopedContentPreservesTheMountedReplyAndSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.pump?.cancel(); fixture.model.release() }
        fixture.request(UUID(), accepted: "new")
        try fixture.observe()
        _ = try CodexState(fixture.contentState)
        fixture.startContentPump()
        let window = SwiftUIReplay.window(SendFeedbackLayout(model: fixture.model, reduceMotion: false)
            .environment(\.locale, Locale(identifier: "en-US")), width: 1180, height: 620)
        defer { window.close() }
        let root = try #require(window.contentView)
        func reply(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, text.string == "New execution becomes the main result" { return text }
            return view.subviews.lazy.compactMap { reply(in: $0) }.first
        }
        do {
            try await SwiftUIReplay.wait(timeout: .seconds(8)) {
                fixture.model.snapshot?.selected == "conversation" && reply(in: root) != nil
            }
        } catch {
            print("SETTLEMENT_ADMISSION selected=\(String(describing: fixture.model.snapshot?.selected)) text=\(SwiftUIReplay.text(in: root)) subscriptions=\(await fixture.client.sendFeedbackSubscriptions())")
            await fixture.close()
            throw error
        }
        let original = try #require(reply(in: root))
        let selection = NSRange(location: 4, length: 9)
        original.setSelectedRange(selection)
        // Scoped row settlement can precede the catalog's completion/handoff.
        // Observe this boundary on the actual Codex reader, including its async
        // decoder and native Markdown, rather than a duplicate row classifier.
        fixture.settleNewRow = true
        _ = try CodexState(fixture.contentState)
        try await SwiftUIReplay.wait { fixture.publishedSettledNewRow }
        var retained = true
        try await SwiftUIReplay.wait {
            retained = retained && original.isDescendant(of: root) && reply(in: root) === original
                && original.selectedRange() == selection
            // The author preference confirms the completed row was actually
            // decoded and applied, rather than only delivered to the resource.
            return SwiftUIReplay.text(in: root).contains { $0.contains("Author:") && $0.contains("settled-model") }
        }
        for _ in 0..<20 {
            root.layoutSubtreeIfNeeded()
            retained = retained && original.isDescendant(of: root) && reply(in: root) === original
                && original.selectedRange() == selection
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(retained, "Settlement detached the reply or lost its native selection")
        #expect(fixture.model.snapshot?.selected == "conversation")
        await fixture.close()
    }

    @Test(arguments: [true, false])
    func exactReceiptAndObservedExecutionCanArriveInEitherOrder(receiptFirst: Bool) async throws {
        let fixture = try Fixture()
        let request = UUID()
        fixture.request(request)
        if receiptFirst { fixture.request(request, accepted: "new") }
        else { try fixture.observe() }
        #expect(fixture.model.snapshot?.selected == nil)
        if receiptFirst { try fixture.observe() }
        else { fixture.request(request, accepted: "new") }
        #expect(fixture.model.snapshot?.selected == nil) // full index still loading
        try await fixture.index()
        #expect(fixture.model.snapshot?.selected == "conversation")
        #expect(fixture.model.snapshot?.excludedExecutionIDs == ["new"])
        fixture.model.close("conversation"); fixture.update()
        #expect(fixture.model.snapshot?.selected == nil) // streaming cannot reopen it
        fixture.request(UUID(), accepted: "new") // steering the same execution is a new local send
        #expect(fixture.model.snapshot?.selected == "conversation")
        try fixture.observe(status: .waitingForUser)
        #expect(fixture.model.snapshot?.selected == "conversation")
        try fixture.observe(status: .completed)
        let handoff = try #require(fixture.model.snapshot?.handoff)
        #expect(fixture.model.snapshot?.selected == "conversation")
        fixture.model.completeHandoffTravel(handoff.id)
        fixture.model.receiveMainExecutionReady("new", handoffID: handoff.id)
        try await Task.sleep(for: .milliseconds(10))
        fixture.model.finishHandoff(handoff.id)
        #expect(fixture.model.snapshot?.selected == nil)
        await fixture.close()
    }

    @Test(arguments: ["failure", "choice", "covered", "target", "archived", "disabled", "terminal", "wrong-receipt", "released"])
    func pendingSendCannotStealANewerReadingChoiceOrRevealAnInvalidExecution(reason: String) async throws {
        let fixture = try Fixture()
        let request = UUID()
        fixture.request(request)
        switch reason {
        case "failure": fixture.configuration.executionReveal = nil
        case "choice": fixture.model.activate("other")
        case "covered": fixture.configuration.suppressed = true
        case "target": fixture.configuration.input = .init(thread: fixture.configuration.input.thread,
            readingTarget: .init(executionID: "old", requestID: "visit", mode: .history))
        case "disabled": fixture.configuration.executionDisabled = true
        case "released": fixture.model.release()
        default: break
        }
        fixture.update()
        if reason != "failure" { fixture.request(request, accepted: reason == "wrong-receipt" ? "unrelated" : "new") }
        try fixture.observe(status: reason == "terminal" ? .failed : .running, archived: reason == "archived")
        if reason != "released" { try await fixture.index() }
        #expect(fixture.model.snapshot?.selected == (reason == "choice" ? "other" : nil))
        if reason == "covered" {
            fixture.configuration.suppressed = false; fixture.update()
            #expect(fixture.model.snapshot?.selected == nil)
        }
        await fixture.close()
    }

    @Test func predecessorCompletionDoesNotCancelTheSuccessorReveal() async throws {
        let fixture = try Fixture()
        try fixture.observe("old")
        try await fixture.index(["inherited", "old"])
        fixture.model.activate("conversation")
        let request = UUID()
        fixture.request(request)
        try fixture.observe("old", status: .completed)
        #expect(fixture.model.snapshot?.handoff?.executionID == "old")
        fixture.request(request, accepted: "new")
        try fixture.observe()
        #expect(fixture.model.snapshot?.selected == "conversation")
        await fixture.close()
    }

    @Test(arguments: [false, true])
    func singleExecutionStaysInMainAndExplicitActiveResultOpensItsSidecard(result: Bool) async throws {
        let fixture = try Fixture()
        if result {
            fixture.configuration.input = .init(thread: fixture.configuration.input.thread,
                readingTarget: .init(executionID: "new", requestID: "result", mode: .current, position: .result))
        }
        fixture.request(UUID(), accepted: "new")
        try fixture.observe()
        fixture.model.receiveIndex(.init(executionIDs: result ? ["old", "new"] : ["new"], hasInheritedHistory: false))
        await Task.yield()
        fixture.update()
        #expect(fixture.model.snapshot?.selected == (result ? "conversation" : nil))
        #expect(fixture.model.snapshot?.excludedExecutionIDs == (result ? ["new"] : []))
        await fixture.close()
    }

    @Test(arguments: ["default", "current", "result", "historical", "single"])
    func activeExecutionEntryIsExactAndClosingIsRememberedForTheVisit(entry: String) async throws {
        let fixture = try Fixture(execution: entry == "default" ? "new" : "old", status: entry == "default" ? .running : .completed)
        // Establish an explicit entry request while its catalog/index may lag.
        if entry != "default" {
            fixture.configuration.input = .init(thread: fixture.configuration.input.thread,
                readingTarget: .init(executionID: entry == "historical" ? "old" : "new", requestID: "entry", mode: .current,
                    position: entry == "result" ? .result : .start))
        }
        fixture.update()
        try fixture.observe()
        try await fixture.index(entry == "single" ? ["new"] : ["old", "new"])
        #expect(fixture.model.snapshot?.selected == (["default", "current", "result"].contains(entry) ? "conversation" : nil))
        fixture.model.close("conversation")
        fixture.update(); try fixture.observe(status: .waitingForUser)
        #expect(fixture.model.snapshot?.selected == nil)
        // A fresh explicit request may reveal again; ordinary payload updates cannot.
        if entry == "current" {
            fixture.configuration.input = .init(thread: fixture.configuration.input.thread,
                readingTarget: .init(executionID: "new", requestID: "second-visit", mode: .current))
            fixture.update()
            #expect(fixture.model.snapshot?.selected == "conversation")
        }
        await fixture.close()
    }

    @Test(arguments: ["normal", "close", "successor", "history", "covered", "release"])
    func completionHandoffRetainsIdentityUntilTravelAndDestinationAreReady(change: String) async throws {
        let fixture = try Fixture()
        fixture.request(UUID(), accepted: "new")
        try fixture.observe(); try await fixture.index()
        #expect(fixture.model.snapshot?.selected == "conversation")
        if change == "history" { fixture.configuration.mainReadingHistory = true; fixture.update() }
        try fixture.observe(status: .completed)
        if change == "history" {
            #expect(fixture.model.snapshot?.handoff == nil)
            #expect(fixture.model.snapshot?.selected == nil)
            await fixture.close(); return
        }
        let handoff = try #require(fixture.model.snapshot?.handoff)
        #expect(handoff.executionID == "new")
        // Preparation admits the destination immediately; the native host,
        // rather than an exclusion in its content request, retains old main.
        #expect(fixture.model.snapshot?.excludedExecutionIDs.isEmpty == true)
        fixture.model.receiveMainExecutionReady("old", handoffID: handoff.id)
        fixture.model.finishHandoff(handoff.id)
        #expect(fixture.model.snapshot?.handoff?.id == handoff.id)
        switch change {
        case "close": fixture.model.close("conversation")
        case "successor": try fixture.observe("successor")
        case "covered": fixture.configuration.suppressed = true; fixture.update()
        case "release": fixture.model.release()
        default: break
        }
        fixture.model.completeHandoffTravel(handoff.id)
        fixture.model.receiveMainExecutionReady("new", handoffID: handoff.id)
        try await Task.sleep(for: .milliseconds(10))
        if change == "normal" {
            #expect(fixture.model.snapshot?.excludedExecutionIDs.isEmpty == true)
            #expect(fixture.model.snapshot?.handoff?.contentReady == true)
        } else if change != "release" { #expect(fixture.model.snapshot?.handoff == nil) }
        fixture.model.finishHandoff(handoff.id)
        if change == "normal" {
            #expect(fixture.model.snapshot?.selected == nil && fixture.model.snapshot?.handoff == nil)
            #expect(fixture.model.snapshot?.focusLauncherOnClose == false)
        }
        if change == "successor" { #expect(fixture.model.snapshot?.excludedExecutionIDs == ["successor"]) }
        await fixture.close()
    }

    @Test(.requiresDisplay, arguments: [CGFloat(700), 1180], ["animated", "reduced", "error", "result"])
    func mountedProductionReadersHandOffAfterContentAdmission(width: CGFloat, mode: String) async throws {
        let fixture = try Fixture()
        defer { fixture.pump?.cancel(); fixture.model.release() }
        let reduceMotion = mode == "reduced"
        if mode == "result" {
            fixture.configuration.input = .init(thread: fixture.configuration.input.thread,
                readingTarget: .init(executionID: "new", requestID: "active-result", mode: .current, position: .result))
            fixture.update()
        }
        fixture.request(UUID(), accepted: "new")
        try fixture.observe()
        _ = try CodexState(fixture.contentState)
        fixture.startContentPump()
        let window = SwiftUIReplay.window(SendFeedbackLayout(model: fixture.model, reduceMotion: reduceMotion)
            .background(Color(red: 0.2, green: 0.3, blue: 0.4)).environment(\.locale, Locale(identifier: "en-US"))
            .environment(\.scenePhase, .active),
            width: width, height: 620)
        defer { window.close() }
        let root = try #require(window.contentView)
        let prefix = "\(Int(width))-\(mode)"
        do {
            try await SwiftUIReplay.wait(timeout: .seconds(8)) {
                fixture.model.snapshot?.selected == "conversation"
                    && SwiftUIReplay.text(in: root).contains("New execution becomes the main result")
            }
        } catch {
            print("SEND_HANDOFF_DIAGNOSTIC selected=\(String(describing: fixture.model.snapshot?.selected)) text=\(SwiftUIReplay.text(in: root)) subscriptions=\(await fixture.client.sendFeedbackSubscriptions())")
            try? await capture(window, name: prefix + "-admission-failure")
            await fixture.close()
            throw error
        }
        try await Task.sleep(for: .milliseconds(450))
        if width == 1180 && mode == "animated" {
            try await resizeExecutionReader(window, fixture: fixture)
        }
        let sourceFrame = try #require(nativeFrame("sidecard-aperture-conversation-frame", in: root))
        let sourceMainFrame = try #require(nativeFrame("agent-reading-panel-frame", in: root))
        let launcherFrame = try #require(accessibilityFrame("sidecard-toggle-conversation", in: root))
        let reader = try #require(handoffReader(in: root))
        try #require(reader.subviews.count == 1)
        let outgoing = try #require(reader.subviews.first)
        let outgoingSize = outgoing.frame.size
        #expect(SwiftUIReplay.text(in: outgoing).contains("Previous main execution"))
        fixture.sourceSubscriptions = Set(await fixture.client.sendFeedbackSubscriptions().map(\.0))
        fixture.holdDestination = true
        fixture.destinationError = mode == "error"
        try await capture(window, name: prefix + "-source")
        // Promotion deliberately hides the Sidecard's AX contents. Its native
        // aperture folds to the actual launcher while old main stays mounted;
        // the hidden incoming host prepares at the final width independently.
        var sampledFold: CGRect?
        var sampledMain: CGRect?
        var sampledHandoff: UUID?
        var foldSamples: [CGRect] = []
        let foldObserver = SwiftUIReplay.FrameObserver(view: root) {
            guard reader.subviews.count == 2,
                  let current = fixture.model.snapshot?.handoff else { return false }
            if reduceMotion && current.travelComplete {
                // A nil-animation completion can publish before AppKit lays out
                // the new pose. Settle that pending nonanimated layout before
                // sampling; animated travel must remain passively observed.
                root.layoutSubtreeIfNeeded()
            }
            guard let frame = nativeFrame("sidecard-aperture-conversation-frame", in: root),
                  let main = nativeFrame("agent-reading-panel-frame", in: root) else { return false }
            if foldSamples.count < 120 { foldSamples.append(frame) }
            let fraction = (sourceFrame.width - frame.width) / (sourceFrame.width - launcherFrame.width)
            // A nil animation completes its state transaction before the
            // hosting tree necessarily commits the destination geometry.
            // Reduced Motion must observe that native final pose, while the
            // animated case still requires an actual intermediate frame.
            let observed = reduceMotion
                ? current.travelComplete && abs(main.width - (root.bounds.width - 76)) < 2
                    && abs(main.height - root.bounds.height) < 2
                    && abs(frame.width - launcherFrame.width) < 2
                    && abs(frame.height - launcherFrame.height) < 2
                : fraction > 0.08 && fraction < 0.92
            guard observed else { return false }
            sampledFold = frame; sampledMain = main; sampledHandoff = current.id
            return true
        }
        defer { foldObserver.stop() }
        try fixture.observe(status: .completed)
        let handoff = try #require(fixture.model.snapshot?.handoff)
        do {
            try await SwiftUIReplay.wait(timeout: .seconds(2), driveLayout: false) {
                sampledFold != nil
            }
        } catch {
            print("THREAD_SEND_FOLD_SAMPLES width=\(width) mode=\(mode) source=\(sourceFrame) launcher=\(launcherFrame) frames=\(foldSamples)")
            try? await capture(window, name: prefix + "-fold-failure")
            throw error
        }
        let travelFrame = try #require(sampledFold)
        let travelMainFrame = try #require(sampledMain)
        #expect(sampledHandoff == handoff.id)
        if !reduceMotion {
            let fraction = (sourceFrame.width - travelFrame.width) / (sourceFrame.width - launcherFrame.width)
            let expectedX = sourceFrame.midX + (launcherFrame.midX - sourceFrame.midX) * fraction
            let expectedY = sourceFrame.midY + (launcherFrame.midY - sourceFrame.midY) * fraction
            #expect(abs(travelFrame.midX - expectedX) < 12 && abs(travelFrame.midY - expectedY) < 12)
            #expect(travelFrame.height < sourceFrame.height && travelFrame.height > launcherFrame.height)
        }
        if width >= 760 {
            #expect(travelMainFrame.width > sourceMainFrame.width)
        } else { #expect(travelMainFrame.height > sourceMainFrame.height) }
        let incoming = try #require(reader.subviews.first { $0 !== outgoing })
        #expect(outgoing.superview === reader && incoming.alphaValue == 0)
        #expect(abs(outgoing.frame.width - outgoingSize.width) < 1 && abs(outgoing.frame.height - outgoingSize.height) < 1)
        try await capture(window, name: prefix + "-travel")
        try await SwiftUIReplay.wait { fixture.model.snapshot?.handoff?.travelComplete == true }
        #expect(fixture.model.snapshot?.handoff?.id == handoff.id)
        #expect(fixture.model.snapshot?.handoff?.contentReady == false)
        let foldedFrame = try #require(nativeFrame("sidecard-aperture-conversation-frame", in: root))
        #expect(abs(foldedFrame.midX - launcherFrame.midX) < 2 && abs(foldedFrame.midY - launcherFrame.midY) < 2)
        #expect(abs(foldedFrame.width - launcherFrame.width) < 2 && abs(foldedFrame.height - launcherFrame.height) < 2)
        let landedFrame = try #require(nativeFrame("agent-reading-panel-frame", in: root))
        #expect(abs(landedFrame.width - (width - 76)) < 1 && abs(landedFrame.height - 620) < 1)
        #expect(outgoing.superview === reader && incoming.superview === reader && incoming.alphaValue == 0)
        #expect(outgoing.layer?.animation(forKey: "execution.handoff.page") == nil)
        #expect(incoming.layer?.animation(forKey: "execution.handoff.page") == nil)
        #expect(SwiftUIReplay.text(in: outgoing).contains("Previous main execution"))
        try await capture(window, name: prefix + "-waiting-for-main")
        fixture.holdDestination = false
        if !reduceMotion {
            var pageFrames: (outgoing: CGRect, incoming: CGRect, oldY: CGFloat, newY: CGFloat)?
            try await SwiftUIReplay.wait(timeout: .seconds(8), driveLayout: false) {
                guard let old = outgoing.layer?.presentation(), let new = incoming.layer?.presentation(),
                      new.transform.m42 > reader.bounds.height * 0.08,
                      new.transform.m42 < reader.bounds.height * 0.92 else { return false }
                pageFrames = (old.frame, new.frame, old.transform.m42, new.transform.m42)
                return true
            }
            let pages = try #require(pageFrames)
            #expect(fixture.model.snapshot?.handoff?.id == handoff.id)
            #expect(fixture.model.snapshot?.handoff?.travelComplete == true && fixture.model.snapshot?.handoff?.contentReady == true)
            #expect(pages.oldY < 0 && abs(pages.newY - pages.oldY - reader.bounds.height) < 1)
            #expect(abs(pages.outgoing.width - outgoingSize.width) < 1 && abs(pages.incoming.width - landedFrame.width) < 1)
            #expect(outgoing.superview === reader && incoming.superview === reader && incoming.alphaValue == 1)
            #expect(outgoing.frame.minY == 0 && incoming.frame.minY == 0, "TextKit model viewports stay onscreen during compositor travel")
            print("THREAD_SEND_PAGE_GEOMETRY width=\(width) mode=\(mode) outgoing=\(pages.outgoing) incoming=\(pages.incoming) translationY=\(pages.oldY),\(pages.newY)")
            try await capture(window, name: prefix + "-page-travel")
        }
        try await SwiftUIReplay.wait(timeout: .seconds(8)) { fixture.model.snapshot?.handoff == nil }
        #expect(fixture.model.snapshot?.selected == nil)
        #expect(fixture.model.snapshot?.excludedExecutionIDs.isEmpty == true)
        #expect(reader.subviews.count == 1 && reader.subviews.first === incoming && outgoing.superview == nil)
        let finalReply = fixture.additionalReply ?? "New execution becomes the main result"
        #expect(SwiftUIReplay.text(in: incoming).contains { $0.contains(mode == "error" ? "Destination fixture error" : finalReply) })
        #expect(!SwiftUIReplay.text(in: root).contains("Previous main execution"))
        let mainFrame = try #require(nativeFrame("agent-reading-panel-frame", in: root))
        print("THREAD_SEND_GEOMETRY width=\(width) mode=\(mode) source=\(sourceFrame) travel=\(travelFrame) folded=\(foldedFrame) waiting=\(landedFrame) main=\(mainFrame)")
        #expect(abs(mainFrame.width - landedFrame.width) < 1 && abs(mainFrame.height - landedFrame.height) < 1)
        #expect(abs(mainFrame.minX - landedFrame.minX) < 1 && abs(mainFrame.minY - landedFrame.minY) < 1)
        try await capture(window, name: prefix + "-main")
        print("THREAD_SEND_NATIVE_HANDOFF_CONFIRMED width=\(width) mode=\(mode)")
        await fixture.close()
    }

    private func resizeExecutionReader(_ window: NSWindow, fixture: Fixture) async throws {
        let root = try #require(window.contentView)
        func divider(in view: NSView) -> NSView? {
            if view.accessibilityRole() == .splitter { return view }
            return view.subviews.lazy.compactMap { divider(in: $0) }.first
        }
        func reply(_ text: String, in view: NSView) -> NSTextView? {
            if let result = view as? NSTextView, result.string == text { return result }
            return view.subviews.lazy.compactMap { reply(text, in: $0) }.first
        }
        let divider = try #require(divider(in: root))
        let main = try #require(reply("Previous main execution", in: root))
        var sidecardReply = "New execution becomes the main result"
        var sidecard = try #require(reply(sidecardReply, in: root))
        let originalMain = main.bounds.width
        let originalSidecard = sidecard.bounds.width
        let mainReader = try #require(handoffReader(in: root))
        let originalReaderWidth = mainReader.bounds.width
        let originalShell = try #require(nativeFrame("sidecard-aperture-conversation-frame", in: root))
        let origin = divider.convert(CGPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, delta: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: origin.x - delta, y: origin.y),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        divider.mouseDown(with: try event(.leftMouseDown, delta: 0))
        let liveReply = "A new settled reply arrives while the execution is running and the divider is held. Its content must appear immediately and wrap to the current column width."
        for delta in [CGFloat(40), 80, 120] {
            divider.mouseDragged(with: try event(.leftMouseDragged, delta: delta))
            do {
                try await SwiftUIReplay.wait {
                    guard let shell = nativeFrame("sidecard-aperture-conversation-frame", in: root) else { return false }
                    return abs(shell.width - originalShell.width - delta) < 1
                        && abs(main.bounds.width - originalMain + delta) < 1
                        && abs(sidecard.bounds.width - originalSidecard - delta) < 1
                }
            } catch {
                print("THREAD_SIDECARD_LIVE_REFLOW_FAILURE delta=\(delta) shell=\(String(describing: nativeFrame("sidecard-aperture-conversation-frame", in: root))) originalShell=\(originalShell) main=\(originalMain)->\(main.bounds.width) reader=\(originalReaderWidth)->\(mainReader.bounds.width) sidecard=\(originalSidecard)->\(sidecard.bounds.width) mainRetained=\(reply("Previous main execution", in: root) === main) sidecardRetained=\(reply("New execution becomes the main result", in: root) === sidecard) widths=\(String(describing: fixture.model.snapshot?.widths))")
                try? await capture(window, name: "live-resize-failure")
                throw error
            }
            #expect(fixture.model.snapshot?.dragging == true)
            #expect(reply(sidecardReply, in: root) === sidecard)
            if delta == 80 {
                fixture.additionalReply = liveReply
                try await SwiftUIReplay.wait { reply(liveReply, in: root) != nil }
                #expect(fixture.model.snapshot?.input.thread.observation.latestExecution?.status == .running)
                // New content moves the result anchor to a different row.
                // Track that new native tail before checking further resizing;
                // the previous tail may be remounted by the anchor change.
                sidecardReply = liveReply
                sidecard = try #require(reply(sidecardReply, in: root))
            }
            if delta >= 80 {
                try await SwiftUIReplay.wait {
                    guard let newReply = reply(liveReply, in: root) else { return false }
                    return abs(newReply.bounds.width - sidecard.bounds.width) < 1
                }
            }
        }
        divider.mouseUp(with: try event(.leftMouseUp, delta: 120))
        try await SwiftUIReplay.wait {
            abs(main.bounds.width - originalMain + 120) < 1 && abs(sidecard.bounds.width - originalSidecard - 120) < 1
        }
        #expect(fixture.model.snapshot?.dragging == false)
        #expect(reply("Previous main execution", in: root) === main)
        #expect(reply(sidecardReply, in: root) === sidecard)
        // Keyboard/accessibility adjustments do not enter a pointer drag and
        // must still commit their width immediately. Measure the viewport here:
        // main's responsive text padding can change at the narrower width.
        #expect(divider.accessibilityPerformIncrement())
        try await SwiftUIReplay.wait {
            abs(mainReader.bounds.width - originalReaderWidth + 144) < 1
                && abs(sidecard.bounds.width - originalSidecard - 144) < 1
        }
        print("THREAD_SIDECARD_LIVE_REFLOW_CONFIRMED main=\(originalMain)->\(main.bounds.width) sidecard=\(originalSidecard)->\(sidecard.bounds.width) runningReply=true")
    }

    @Test(.requiresDisplay, arguments: ["conversation", "iab", "voice"])
    func rightSidecardButtonsToggleRetainedPluginsWithoutCloseIcons(card: String) async throws {
        let fixture = try Fixture(allCards: true)
        defer { fixture.pump?.cancel(); fixture.model.release() }
        fixture.request(UUID(), accepted: "new")
        try fixture.observe()
        fixture.startContentPump()
        if card == "iab" { try await fixture.model.routes.openExternal?("http://127.0.0.1:9/") }
        if card == "voice" { fixture.model.activate("voice") }
        let window = SwiftUIReplay.window(SendFeedbackLayout(model: fixture.model, reduceMotion: true), width: 1180, height: 620)
        defer { window.close() }
        let root = try #require(window.contentView)
        let id = JSONText(card)
        try await SwiftUIReplay.wait(timeout: .seconds(8)) { fixture.model.snapshot?.selected == id }
        if card == "voice" {
            try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains { $0.contains("Retained voice transcript") } }
            #expect(fixture.model.snapshot?.available.contains { $0.id == "voice" } == true)
            #expect(fixture.services.voice?.state.supported == false && fixture.services.voice?.state.available == false)
        }
        #expect(element("conversation-sidecard-close", in: root) == nil)
        #expect(element("browser-sidecard-close", in: root) == nil)
        #expect(!SwiftUIReplay.text(in: root).contains("Collapse card"))
        let press = NSSelectorFromString("accessibilityPerformPress")
        func toggle(_ card: String) throws {
            let button = try #require(element("sidecard-toggle-" + card, in: root))
            try #require(button.responds(to: press))
            _ = button.perform(press)
        }
        try toggle(card)
        try await SwiftUIReplay.wait { fixture.model.snapshot?.selected == nil }
        try toggle(card)
        try await SwiftUIReplay.wait { fixture.model.snapshot?.selected == id }
        try toggle("other")
        try await SwiftUIReplay.wait { fixture.model.snapshot?.selected == "other" }
        try toggle(card)
        try await SwiftUIReplay.wait { fixture.model.snapshot?.selected == id }
        #expect(fixture.owner.backs == 0)
        #expect(fixture.configuration.input.thread.observation.latestExecution?.executionID == "new")
        #expect(fixture.configuration.input.thread.observation.isExecutionActive)
        #expect(fixture.services.voice?.state.phase == .closed)
        #expect(fixture.owner.voiceMediaActions == 0)
        if card == "voice" {
            try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains { $0.contains("Retained voice transcript") } }
            #expect(fixture.services.voice?.state.messages.map(\.id) == ["retained-reply"])
            #expect(element("moku-voice-start", in: root) == nil && element("moku-voice-stop", in: root) == nil)
            try await verifyVoiceJumpOwnership(fixture, in: root)
        }
        print("THREAD_SIDECARD_TOGGLES_CONFIRMED card=\(card)")
        await fixture.close()
    }

    private func verifyVoiceJumpOwnership(_ fixture: Fixture, in root: NSView) async throws {
        let presentation = try #require(fixture.owner.voicePresentation)
        let lifetime = try #require(fixture.owner.voiceLifetime)
        let capability = try #require(fixture.services.voice)
        try await SwiftUIReplay.wait { presentation.context.expanded && !presentation.context.suppressed }
        func publish(paragraphs: Int) throws {
            let message = try VoiceTranscriptMessage(id: "retained-reply", sessionID: "past-call", role: .assistant,
                text: JSONText("Retained voice transcript\n\n" + String(repeating: "Voice scroll ownership paragraph.\n\n", count: paragraphs)),
                complete: true, createdAt: 1)
            capability.publish(.init(phase: .closed, supported: false, available: false,
                loading: false, muted: false, error: "", messages: [message]))
        }
        func voiceScroll(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView,
               SwiftUIReplay.text(in: scroll).contains(where: { $0.contains("Retained voice transcript") }) { return scroll }
            return view.subviews.lazy.compactMap { voiceScroll(in: $0) }.first
        }
        try publish(paragraphs: 80)
        try await SwiftUIReplay.wait { voiceScroll(in: root) != nil }
        let scroll = try #require(voiceScroll(in: root))
        let document = try #require(scroll.documentView)
        func bottom() -> CGFloat { max(0, document.frame.height - scroll.contentView.bounds.height) }
        func offset() -> CGFloat { scroll.contentView.bounds.minY }
        func takeUserOwnership() {
            presentation.userScrollBegan(offset: offset(), contentHeight: document.frame.height,
                viewportHeight: scroll.contentView.bounds.height)
        }
        func position(_ y: CGFloat) {
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { presentation.scrollPosition.scrollTo(y: y) }
        }
        try await SwiftUIReplay.wait { bottom() > 1_000 && abs(bottom() - offset()) < 5 }
        // A tracking phase at the bottom need not move a pixel. Subsequent
        // content must still follow in the real retained ScrollView.
        takeUserOwnership()
        #expect(presentation.pinned && !presentation.away)
        let oldBottom = bottom()
        try publish(paragraphs: 100)
        try await SwiftUIReplay.wait { bottom() > oldBottom && abs(bottom() - offset()) < 5 }
        #expect(presentation.pinned && !presentation.newMessages)

        func startJump(_ action: @escaping @MainActor () -> Void) async throws {
            position(0)
            try await SwiftUIReplay.wait { abs(offset()) < 5 && presentation.away }
            var delivered = false
            // Mutate in the display callback: an async waiter can resume only
            // after the short-lived animated pose has already completed.
            let observer = SwiftUIReplay.FrameObserver(view: scroll) {
                guard offset() > 20 && offset() < bottom() - 64 else { return false }
                action()
                delivered = true
                return true
            }
            defer { observer.stop() }
            presentation.jumpToLatest(bottom: bottom(), reduceMotion: false)
            try await SwiftUIReplay.wait(driveLayout: false) { delivered }
        }
        var takenOffset: CGFloat = 0
        try await startJump {
            takeUserOwnership()
            #expect(!presentation.pinned && presentation.away)
            takenOffset = max(0, offset() - 10)
            position(takenOffset)
        }
        try await SwiftUIReplay.wait { abs(offset() - takenOffset) < 5 }
        try await Task.sleep(for: .milliseconds(450))
        #expect(!presentation.pinned && presentation.away && abs(offset() - takenOffset) < 5,
            "An old jump completion must not reacquire scrolling after user takeover")
        #expect(SwiftUIReplay.text(in: root).contains(presentation.translate("回到最新")))

        for boundary in ["suppressed", "folded", "released"] {
            try await startJump {
                switch boundary {
                case "suppressed":
                    fixture.configuration.suppressed = true; fixture.update()
                    #expect(presentation.context.suppressed)
                case "folded":
                    presentation.close()
                    #expect(!presentation.context.expanded)
                default:
                    fixture.model.release()
                    #expect(lifetime.isCancelled)
                }
                // A late Reduce Motion receipt and the actual animation callback
                // must both leave a replacement fixed-offset request untouched.
                position(12)
                presentation.finishLatestTransition()
                #expect(presentation.scrollPosition.edge == nil,
                    "The \(boundary) boundary must revoke the old jump before late completion")
            }
            try await Task.sleep(for: .milliseconds(450))
            #expect(presentation.scrollPosition.edge == nil)
            if boundary == "suppressed" {
                fixture.configuration.suppressed = false; fixture.update()
                try await SwiftUIReplay.wait { !presentation.context.suppressed }
            } else if boundary == "folded" {
                fixture.model.activate("voice")
                try await SwiftUIReplay.wait { presentation.context.expanded && !presentation.context.suppressed }
                #expect(fixture.owner.voicePresentation === presentation)
            }
        }
        print("VOICE_TRANSCRIPT_JUMP_OWNERSHIP_CONFIRMED")
    }

    @Test(.requiresDisplay, arguments: [1180.0, 800.0])
    func sidecardApertureTravelsBetweenItsActualLauncherAndPanel(width: CGFloat) async throws {
        let probe = FoldProbeState()
        let fixture = try Fixture(foldProbe: probe)
        defer { fixture.model.release() }
        let window = SwiftUIReplay.window(FoldProbeLayout(model: fixture.model, state: probe, width: width), width: width, height: 620)
        defer { window.close() }
        let root = try #require(window.contentView)
        // AppKit first constrains a wide window to the CI display before
        // NSHostingView applies its requested extent. Do not mix an AX source
        // from that transient 1024pt seat with the later 1180pt animation.
        var initialLauncher: CGRect?
        var stableSamples = 0
        do {
            try await SwiftUIReplay.wait {
                guard abs(root.bounds.width - width) < 1, abs(root.bounds.height - 620) < 1,
                      let frame = accessibilityFrame("sidecard-toggle-c", in: root) else {
                    initialLauncher = nil; stableSamples = 0
                    return false
                }
                stableSamples = initialLauncher == frame ? stableSamples + 1 : 0
                initialLauncher = frame
                return stableSamples >= 2
            }
        } catch {
            print("FOLD_INITIAL_LAYOUT requested=\(width)x620 root=\(root.bounds) window=\(window.frame) launcher=\(String(describing: initialLauncher)) stableSamples=\(stableSamples)")
            try? await capture(window, name: "fold-\(Int(width))-initial-layout-failure")
            throw error
        }
        let press = NSSelectorFromString("accessibilityPerformPress")
        func toggle(_ id: String) throws {
            let button = try #require(element("sidecard-toggle-" + id, in: root))
            _ = button.perform(press)
        }
        func launcher(_ id: String) throws -> CGRect {
            let screen = try #require(accessibilityFrame("sidecard-toggle-" + id, in: root))
            let local = root.convert(window.convertFromScreen(screen), from: nil)
            return root.isFlipped ? local : CGRect(x: local.minX, y: root.bounds.height - local.maxY, width: local.width, height: local.height)
        }
        var observedCard = "a"
        // The production aperture owns this noninteractive native frame marker.
        // Sample its mounted layout through actual SwiftUI animation ticks;
        // AppKit cacheDisplay cannot capture SwiftUI compositor layers reliably.
        func aperture() -> CGRect? {
            func find(_ view: NSView) -> NSView? {
                if view.identifier?.rawValue == "sidecard-aperture-" + observedCard + "-frame" { return view }
                return view.subviews.lazy.compactMap(find).first
            }
            guard let view = find(root) else { return nil }
            let rect = root.convert(view.bounds, from: view)
            return root.isFlipped ? rect : CGRect(x: rect.minX, y: root.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        }
        func expectFolded(at source: CGRect) throws {
            let frame = try #require(aperture())
            #expect(abs(frame.midX - source.midX) < 2 && abs(frame.midY - source.midY) < 2, "Folded \(observedCard): \(frame), source \(source)")
            #expect(abs(frame.width - source.width) < 2 && abs(frame.height - source.height) < 2)
        }
        func destination() throws -> CGRect {
            let snapshot = try #require(fixture.model.snapshot)
            let size = probe.size ?? CGSize(width: width, height: 620)
            let geometry = NativeSidecardWorkspaceGeometry(size: .init(width: size.width - 76, height: size.height), snapshot: snapshot)
            return CGRect(x: geometry.surfaceX, y: geometry.surfaceY, width: geometry.surfaceWidth, height: geometry.surfaceHeight)
        }
        func intermediate(source: CGRect, target: CGRect, name: String) async throws {
            let deadline = ContinuousClock.now + .seconds(2)
            var observed = false
            var samples: [CGRect] = []
            while ContinuousClock.now < deadline {
                if let frame = aperture() {
                    if samples.count < 10 { samples.append(frame) }
                    let fraction = (frame.width - source.width) / (target.width - source.width)
                    if fraction > 0.08 && fraction < 0.92 {
                        // An aperture travelling between two frames
                        // must stay on their line, for every launcher and layout.
                        let expectedY = source.midY + (target.midY - source.midY) * fraction
                        let expectedX = source.midX + (target.midX - source.midX) * fraction
                        #expect(abs(frame.midY - expectedY) < 12, "\(name): aperture \(frame), launcher \(source), panel \(target)")
                        #expect(abs(frame.midX - expectedX) < 12)
                        observed = true
                        try await capture(window, name: name)
                        break
                    }
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            if !observed { try await capture(window, name: name + "-failure") }
            print("FOLD_APERTURE_SAMPLES name=\(name) source=\(source) target=\(target) frames=\(samples)")
            try #require(observed, "No intermediate native aperture observed: \(name)")
        }
        for id in ["a", "b", "c"] {
            observedCard = id
            let source = try launcher(id)
            try toggle(id)
            let target = try destination()
            try await intermediate(source: source, target: target, name: "fold-\(Int(width))-\(id)-open")
            try await Task.sleep(for: .milliseconds(420))
            let settled = try #require(aperture())
            #expect(abs(settled.minX - target.minX) < 4 && abs(settled.minY - target.minY) < 4)
            try toggle(id)
            try await intermediate(source: source, target: target, name: "fold-\(Int(width))-\(id)-close")
            try await Task.sleep(for: .milliseconds(420))
            try expectFolded(at: source)
        }
        // Reverse and switch before travel completes. Plugin sessions survive.
        try toggle("a")
        try await Task.sleep(for: .milliseconds(40))
        try toggle("a")
        try toggle("c")
        observedCard = "c"
        try await Task.sleep(for: .milliseconds(420))
        #expect(fixture.model.snapshot?.selected == "c")
        // Removing an earlier button moves c. Its next return must use the new
        // real bounds rather than its old index or cached original window size.
        probe.available.remove("a")
        try await SwiftUIReplay.wait { fixture.model.snapshot?.available.count == 2 }
        try await Task.sleep(for: .milliseconds(100))
        let movedSource = try launcher("c")
        let target = try destination()
        try toggle("c")
        try await intermediate(source: movedSource, target: target, name: "fold-\(Int(width))-relayout-close")
        try await Task.sleep(for: .milliseconds(420))
        try expectFolded(at: movedSource)
        // Resize during opening, including the wide-to-stacked breakpoint,
        // then retain a divider width and return using the resized button.
        try toggle("c")
        try await Task.sleep(for: .milliseconds(40))
        probe.size = CGSize(width: width == 1180 ? 800 : 700, height: 500)
        try await Task.sleep(for: .milliseconds(450))
        let beforeDrag = probe.viewBuilds
        fixture.model.setDragging(true)
        #expect(probe.viewBuilds > beforeDrag)
        let duringDrag = probe.viewBuilds
        for dragWidth in 351...360 { fixture.model.resize(CGFloat(dragWidth), maximum: 600) }
        #expect(probe.viewBuilds == duringDrag)
        #expect(fixture.model.snapshot?.widths["c"] == 360)
        fixture.model.setDragging(false)
        #expect(probe.viewBuilds > duringDrag)
        try await Task.sleep(for: .milliseconds(80))
        let resizedSource = try launcher("c")
        let resizedTarget = try destination()
        try toggle("c")
        try await intermediate(source: resizedSource, target: resizedTarget, name: "fold-\(Int(width))-resize-close")
        try await Task.sleep(for: .milliseconds(420))
        try expectFolded(at: resizedSource)
        if width == 1180 {
            probe.size = nil
            try await Task.sleep(for: .milliseconds(420))
            let restoredSource = try launcher("c")
            try toggle("c")
            let retainedTarget = try destination()
            #expect(retainedTarget.width == 360)
            try await intermediate(source: restoredSource, target: retainedTarget, name: "fold-1180-retained-width-open")
            try await Task.sleep(for: .milliseconds(420))
            try toggle("c")
            try await Task.sleep(for: .milliseconds(420))
            try expectFolded(at: restoredSource)
        }
        try toggle("b")
        try await Task.sleep(for: .milliseconds(420))
        observedCard = "b"
        let retiringSource = try launcher("b")
        probe.available.remove("b")
        try await SwiftUIReplay.wait { fixture.model.snapshot?.selected == nil }
        try await Task.sleep(for: .milliseconds(420))
        try expectFolded(at: retiringSource)
        #expect(fixture.owner.backs == 0 && probe.presses == 0)
        print("THREAD_SIDECARD_ORIGIN_GEOMETRY_CONFIRMED width=\(width)")
        await fixture.close()
    }

    private func element(_ id: String, in root: NSView) -> NSObject? {
        var seen = Set<ObjectIdentifier>()
        func visit(_ object: AnyObject) -> NSObject? {
            guard seen.insert(ObjectIdentifier(object)).inserted, seen.count < 10_000,
                  let element = object as? NSObject else { return nil }
            let identifier = NSSelectorFromString("accessibilityIdentifier")
            if element.responds(to: identifier), element.perform(identifier)?.takeUnretainedValue() as? String == id { return element }
            let children = NSSelectorFromString("accessibilityChildren")
            if element.responds(to: children), let items = element.perform(children)?.takeUnretainedValue() as? [AnyObject] {
                for item in items { if let frame = visit(item) { return frame } }
            }
            let legacy = NSSelectorFromString("accessibilityAttributeValue:")
            if element.responds(to: legacy), let items = element.perform(legacy, with: "AXChildren")?.takeUnretainedValue() as? [AnyObject] {
                for item in items { if let found = visit(item) { return found } }
            }
            if let view = element as? NSView {
                for child in view.subviews { if let frame = visit(child) { return frame } }
            }
            return nil
        }
        return visit(root)
    }

    private func accessibilityFrame(_ id: String, in root: NSView) -> CGRect? {
        guard let element = element(id, in: root) else { return nil }
        if let accessible = element as? any NSAccessibilityProtocol { return accessible.accessibilityFrame() }
        let selector = NSSelectorFromString("accessibilityFrame")
        guard let method = class_getInstanceMethod(type(of: element), selector) else { return nil }
        typealias FrameFunction = @convention(c) (AnyObject, Selector) -> CGRect
        return unsafeBitCast(method_getImplementation(method), to: FrameFunction.self)(element, selector)
    }

    private func nativeFrame(_ identifier: String, in view: NSView) -> CGRect? {
        if view.identifier?.rawValue == identifier, let window = view.window {
            return window.convertToScreen(view.convert(view.bounds, to: nil))
        }
        for child in view.subviews { if let frame = nativeFrame(identifier, in: child) { return frame } }
        return nil
    }

    private func handoffReader(in view: NSView) -> ExecutionHandoffReaderView? {
        if let reader = view as? ExecutionHandoffReaderView { return reader }
        for child in view.subviews { if let reader = handoffReader(in: child) { return reader } }
        return nil
    }

    private func capture(_ window: NSWindow, name: String) async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MOKUSEI_READING_MOTION_ARTIFACTS"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("moku-send-frames").path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image: CGImage
        let windowServer = ProcessInfo.processInfo.environment["MOKUSEI_THREAD_SEND_WINDOWSERVER"] == "1"
        if windowServer {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let own = try #require(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
            let configuration = SCStreamConfiguration()
            configuration.width = Int(own.frame.width * window.backingScaleFactor)
            configuration.height = Int(own.frame.height * window.backingScaleFactor)
            configuration.showsCursor = false
            image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: configuration)
        } else {
            let root = try #require(window.contentView)
            root.layoutSubtreeIfNeeded()
            let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            image = try #require(bitmap.cgImage)
        }
        let destination = try #require(CGImageDestinationCreateWithURL(directory.appendingPathComponent(name + ".png") as CFURL,
            UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        print("THREAD_SEND_CAPTURE name=\(name) source=\(windowServer ? "WindowServer" : "AppKit-render")")
    }

    @Test(.requiresDisplay, arguments: ["success", "failure", "switch"])
    func productionDockFoldsOnSendAndOnlyRestoresAFailedCurrentDraft(outcome: String) async throws {
        let state = NativeMokuSceneState()
        let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
        draft.text = "Follow up"
        state.readingPanelVisible = true; state.overviewVisible = false; state.setWindowVisible(true)
        state.setComposerContext(draft, opensInput: true)
        var receipt: CheckedContinuation<Void, Error>?
        var submissions = 0
        let window = SwiftUIReplay.window(NativeMokuDock(state: state, draft: draft, cwd: "/tmp", threadTitle: "Thread",
            onSend: { _ in
                submissions += 1
                try await withCheckedThrowingContinuation { receipt = $0 }
            }, onCancel: {}), width: 800, height: 500)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { SwiftUIReplay.editor(in: root) != nil }
        let editor = try #require(SwiftUIReplay.editor(in: root))
        window.makeFirstResponder(editor)
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        editor.keyDown(with: enter)
        try await SwiftUIReplay.wait { receipt != nil }
        #expect(!state.inputOpen && state.inputLeaving)
        #expect(state.retainedText.isEmpty && draft.inputText.isEmpty) // submission clears both live and retiring ink
        #expect(draft.text == "Follow up") // pending admission still owns the durable payload
        #expect(state.retainedAttachments.isEmpty && state.retainedDirectories.isEmpty)
        #expect(draft.submitting)
        editor.keyDown(with: enter)
        #expect(submissions == 1)
        if outcome == "switch" {
            let replacement = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
            replacement.text = "Other thread"
            state.setComposerContext(replacement, opensInput: false)
        }
        if outcome == "success" { receipt?.resume() }
        else { receipt?.resume(throwing: PluginContractError("admission failed")) }
        receipt = nil
        try await SwiftUIReplay.wait { !draft.submitting }
        #expect(submissions == 1)
        #expect(state.inputOpen == (outcome == "failure"))
        #expect(draft.text == (outcome == "success" ? "" : "Follow up"))
        #expect(draft.error == (outcome == "success" ? nil : "admission failed"))
        await draft.dispose()
        state.overviewState.camera.dispose()
        print("THREAD_SEND_DOCK_FEEDBACK_CONFIRMED outcome=\(outcome)")
    }

    @Test(.requiresDisplay, arguments: [false, true], [false, true])
    func completedSendAllowsClickingAndTypingIntoTheResidentComposer(exactExecution: Bool, cancelHandoff: Bool) async throws {
        // This foreground replay must not ingest unrelated physical typing while
        // its asynchronous reader handoff runs. Only this app's test key is tagged;
        // other applications and system input-source preferences are untouched.
        let keyTag: Int64 = 0x4D4F4B555245504C
        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            event.cgEvent?.getIntegerValueField(.eventSourceUserData) == keyTag ? event : nil
        }
        defer { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
        let fixture = try Fixture()
        defer { fixture.pump?.cancel(); fixture.model.release() }
        let preferences = DesktopPreferences(directory: fixture.directory)
        try preferences.setOnboardingCompleted(true)
        let workspace = NativeWorkspaceModel(client: fixture.client, preferences: preferences,
            plugins: try .init(harnesses: [AnyHarnessPlugin(CodexHarnessPlugin())], sidecards: [], applications: []))
        try workspace.catalog.install(.object(["revision": .integer(1), "settingsRevision": .integer(0),
            "defaultCwd": .text(fixture.directory.path), "settings": .object([:]),
            "threads": .array([fixture.owner.thread.json]), "executions": .array([]), "applicationThreads": .array([])]))
        let presentation = NativeWorkspacePresentation(workspace: workspace)
        func visit(_ execution: JSONText) {
            let target: HarnessReadingTarget? = exactExecution
                ? .init(executionID: execution, requestID: execution, mode: .current, position: .result) : nil
            fixture.configuration.input = .init(thread: fixture.owner.thread, readingTarget: target)
            fixture.update()
            presentation.open(.init(threadID: "thread", typeID: "agent"), target: target)
        }
        visit("old")
        fixture.startContentPump()
        let scene = NativeMokuSceneState()
        let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
        scene.readingPanelVisible = true; scene.overviewVisible = false; scene.setWindowVisible(true)
        scene.setComposerContext(draft, opensInput: true, keepsInputOpen: true)
        draft.text = "Follow up"
        var submissions: [NativeComposerSubmission] = []
        let mount = SendFeedbackComposerMount()
        let window = SwiftUIReplay.window(SendFeedbackComposerLayout(mount: mount, model: fixture.model, presentation: presentation,
            scene: scene, draft: draft, onSend: { submission in
                submissions.append(submission)
                fixture.request(UUID(), accepted: "new")
                try fixture.observe()
                if exactExecution { visit("new") }
            }), width: 1180, height: 760)
        defer { window.close(); scene.overviewState.camera.dispose() }
        let root = try #require(window.contentView)
        // This lookup must not focus the editor: the regression is ordinary
        // pointer acquisition after the old reader has actually disappeared.
        func editor(in view: NSView) -> ComposerTextView? {
            if let editor = view as? ComposerTextView { return editor }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        try await SwiftUIReplay.wait { presentation.dockInputAvailable && editor(in: root)?.isEditable == true }
        let initialEditor = try #require(editor(in: root))
        window.makeFirstResponder(initialEditor)
        initialEditor.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)))
        try await SwiftUIReplay.wait { submissions.count == 1 && !draft.submitting && fixture.model.snapshot?.selected == "conversation" }
        #expect(submissions.first?.text == "Follow up")
        #expect(draft.text.isEmpty)
        #expect(scene.inputOpen)
        try fixture.observe(status: .completed)
        try #require(fixture.model.snapshot?.handoff != nil)
        if cancelHandoff {
            // Interrupt after the incoming reader has published, while the
            // original reader is still retained for the outgoing animation.
            try await SwiftUIReplay.wait { fixture.model.snapshot?.handoff?.contentReady == true }
            fixture.model.close("conversation")
        }
        // Canceling handoff also starts the ordinary card fold and its launcher
        // focus restoration. Wait for that production transition to finish.
        try await SwiftUIReplay.wait(timeout: .seconds(8)) {
            fixture.model.snapshot?.handoff == nil && fixture.model.snapshot?.selected == nil
                && fixture.model.snapshot?.transitioning == false
        }
        // Let native teardown and its deferred preference/disappearance reports
        // drain before inspecting availability or attempting another click.
        try await Task.sleep(for: .milliseconds(150))
        #expect(presentation.dockInputAvailable)
        #expect(presentation.dockExecution?.executionID == (exactExecution ? "new" : nil))
        let input = try #require(editor(in: root))
        #expect(input === initialEditor)
        try #require(input.isEditable && input.isSelectable)
        // An inactive-window click may only activate the app. Establish the
        // fixture's foreground window without focusing the editor under test.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await SwiftUIReplay.wait { NSApp.isActive && window.isKeyWindow }
        window.makeFirstResponder(nil)
        let visible = input.visibleRect
        let point = input.convert(CGPoint(x: visible.minX + 20, y: visible.midY), to: nil)
        let hit = root.hitTest(root.superview?.convert(point, from: nil) ?? point)
        print("COMPOSER_CLICK time=\(ProcessInfo.processInfo.systemUptime) exact=\(exactExecution) cancel=\(cancelHandoff) key=\(window.isKeyWindow) editable=\(input.isEditable) visible=\(visible) hitsEditor=\(hit === input)")
        try #require(hit === input)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        // NSTextView's synchronous mouse tracking needs its release queued first.
        NSApp.postEvent(up, atStart: true)
        NSApp.sendEvent(down)
        print("COMPOSER_CLICK_DISPATCH time=\(ProcessInfo.processInfo.systemUptime) focus=\(window.firstResponder === input)")
        try await Task.sleep(for: .milliseconds(100))
        print("COMPOSER_CLICK_RESULT time=\(ProcessInfo.processInfo.systemUptime) editable=\(input.isEditable) available=\(presentation.dockInputAvailable) focus=\(window.firstResponder === input)")
        if window.firstResponder !== input { try await capture(window, name: "composer-focus-failure-\(exactExecution)-\(cancelHandoff)") }
        try #require(window.firstResponder === input)
        let typedKey = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 7, keyDown: true))
        typedKey.setIntegerValueField(.eventSourceUserData, value: keyTag)
        typedKey.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(ProcessInfo.processInfo.processIdentifier))
        let characters: [UniChar] = [0x78]
        characters.withUnsafeBufferPointer { typedKey.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress!) }
        NSApp.sendEvent(try #require(NSEvent(cgEvent: typedKey)))
        print("COMPOSER_TYPE_DISPATCH exact=\(exactExecution) cancel=\(cancelHandoff) text=\(input.string.debugDescription) draft=\(draft.text.debugDescription) marked=\(input.hasMarkedText()) key=\(window.isKeyWindow)")
        do { try await SwiftUIReplay.wait { draft.text == "x" && input.string == "x" } }
        catch {
            print("COMPOSER_TYPE_FAILURE text=\(input.string.debugDescription) draft=\(draft.text.debugDescription) marked=\(input.hasMarkedText()) owns=\(scene.ownsComposer(draft)) leaving=\(scene.inputLeaving) sealed=\(scene.capsuleSealed)")
            try await capture(window, name: "composer-typing-failure-\(exactExecution)-\(cancelHandoff)")
            throw error
        }
        #expect(submissions.count == 1)
        mount.visible = false
        try await SwiftUIReplay.wait { presentation.agentInputTarget == nil }
        await draft.dispose()
        await fixture.close()
        print("THREAD_SEND_COMPOSER_REFOCUS_CONFIRMED exactExecution=\(exactExecution) cancelHandoff=\(cancelHandoff)")
    }
}
