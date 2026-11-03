import AppKit
import Observation
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

private struct SendFeedbackOtherCard: SidecardPlugin {
    let descriptor = SidecardPluginDescriptor(id: "other", displayName: "Other")
    var icon: some View { Text("O") }
    func makePresentation(context: SidecardContext, lifetime: PluginLifetime) -> SendFeedbackOtherPresentation { .init() }
    func sidecard(context: SidecardContext, presentation: SendFeedbackOtherPresentation) throws -> SidecardView<Text> {
        try SidecardView(available: true, label: "Other", preferredWidth: 1 / 3) { Text("Other activity") }
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

        init(execution: JSONText = "old", status: PublicExecution.Status = .completed, allCards: Bool = false) throws {
            client = RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory))
            let thread = try Self.thread(execution, status: status)
            let owner = SendFeedbackThreadOwner(thread)
            self.owner = owner
            let voice = allCards ? SidecardVoiceCapability(state: .init(phase: .closed, supported: true, available: true,
                loading: false, muted: false, error: "", messages: []), start: {}, stop: {}, toggleMute: {}, refresh: {}) : nil
            services = NativeSidecardWorkspaceServices(send: { _, _ in throw CancellationError() },
                stageAttachments: { _ in [] }, discardAttachments: { _ in }, openExternal: { _ in }, voice: voice)
            host = NativeHarnessHost(client: client, registry: try HarnessPluginRegistry([AnyHarnessPlugin(CodexHarnessPlugin())]), currentThread: { _ in owner.thread },
                callbacks: .init(openExternal: { _ in }, openFollowUp: { _, _ in }, onError: { _ in }))
            configuration = .init(input: .init(thread: thread), executionDisabled: false, suppressed: false,
                enabledIDs: nil, locale: Locale(identifier: "en-US"))
            model = NativeSidecardWorkspaceModel(harnessHost: host,
                registry: try SidecardPluginRegistry([AnySidecardPlugin(NativeConversationSidecard()), AnySidecardPlugin(SendFeedbackOtherCard())]
                    + (allCards ? [AnySidecardPlugin(NativeBrowserSidecard()), AnySidecardPlugin(NativeVoiceSidecard())] : [])),
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
                    let state = contentState
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
                        if published[id] != state {
                            host.receive(.threadContent(subscriptionId: id, state: .ready(state)))
                            published[id] = state
                        }
                    }
                    do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                }
            }
        }
        var contentState: JSONValue {
            .object(["schema": .text("mokusei.harness.codex.thread.v1"), "updatedAt": .integer(4),
                "backgroundTerminals": .array([]), "turns": .array(["old", "new"].map { id in
                    let latest = configuration.input.thread.observation.latestExecution
                    let active = latest?.executionID == JSONText(id) && configuration.input.thread.observation.isExecutionActive
                    let text = id == "old" ? "Previous main execution" : "New execution becomes the main result"
                    var turn: [JSONText: JSONValue] = ["executionId": .text(id), "status": .text(active ? "running" : "completed"),
                        "createdAt": .integer(id == "old" ? 1 : 2), "updatedAt": .integer(4),
                        "answer": .text(text), "reasoning": .text(""),
                        "messages": .array([.object(["id": .text(id + "-reply"), "role": .text("assistant"), "kind": .text("answer"),
                            "content": .text(text), "createdAt": .integer(3), "attachments": .array([])])]),
                        "timeline": .array([.object(["id": .text(id + "-reply"), "kind": .text("assistant"), "itemId": .text(id + "-native-reply"),
                            "content": .text(text), "status": .text("complete"), "createdAt": .integer(3)])]),
                        "activities": .array([]), "interactions": .array([]), "plan": .array([]), "notices": .array([])]
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
        #expect(fixture.model.snapshot?.excludedExecutionIDs == ["new"])
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
            .background(Color(red: 0.2, green: 0.3, blue: 0.4)).environment(\.locale, Locale(identifier: "en-US")),
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
        let responder = window.firstResponder
        let sourceFrame = try #require(accessibilityFrame("conversation-sidecard", in: root))
        fixture.sourceSubscriptions = Set(await fixture.client.sendFeedbackSubscriptions().map(\.0))
        fixture.holdDestination = true
        fixture.destinationError = mode == "error"
        try await capture(window, name: prefix + "-source")
        try fixture.observe(status: .completed)
        let handoff = try #require(fixture.model.snapshot?.handoff)
        try await Task.sleep(for: .milliseconds(150))
        let travelFrame = try #require(accessibilityFrame("conversation-sidecard", in: root))
        if width >= 760 {
            #expect(travelFrame.width > sourceFrame.width && travelFrame.minX < sourceFrame.minX)
        } else { #expect(travelFrame.height > sourceFrame.height) }
        try await capture(window, name: prefix + "-travel")
        try await SwiftUIReplay.wait { fixture.model.snapshot?.handoff?.travelComplete == true }
        #expect(fixture.model.snapshot?.handoff?.id == handoff.id)
        #expect(fixture.model.snapshot?.handoff?.contentReady == false)
        let landedFrame = try #require(accessibilityFrame("conversation-sidecard", in: root))
        try await capture(window, name: prefix + "-waiting-for-main")
        fixture.holdDestination = false
        try await SwiftUIReplay.wait(timeout: .seconds(8)) { fixture.model.snapshot?.handoff == nil }
        #expect(fixture.model.snapshot?.selected == nil)
        #expect(fixture.model.snapshot?.excludedExecutionIDs.isEmpty == true)
        #expect(SwiftUIReplay.text(in: root).contains { $0.contains(mode == "error" ? "Destination fixture error" : "New execution becomes the main result") })
        #expect(!SwiftUIReplay.text(in: root).contains("Previous main execution"))
        // The AX reading group describes the inset viewport, not the paper.
        // Use the production native panel-frame marker for the landing target.
        let mainFrame = try #require(nativePanelFrame(in: root))
        print("THREAD_SEND_GEOMETRY width=\(width) mode=\(mode) source=\(sourceFrame) travel=\(travelFrame) landed=\(landedFrame) main=\(mainFrame)")
        #expect(abs(mainFrame.width - landedFrame.width) < 1 && abs(mainFrame.height - landedFrame.height) < 1)
        #expect(abs(mainFrame.minX - landedFrame.minX) < 1 && abs(mainFrame.minY - landedFrame.minY) < 1)
        #expect(window.firstResponder === responder)
        func blockedText(in view: NSView) -> Bool {
            if let text = view as? MarkdownTextView, text.awaitsLineReveal { return true }
            return view.subviews.contains { blockedText(in: $0) }
        }
        #expect(!blockedText(in: root), "Promoted content must not restart the initial-entry reveal and become blank")
        try await capture(window, name: prefix + "-main")
        print("THREAD_SEND_NATIVE_HANDOFF_CONFIRMED width=\(width) mode=\(mode)")
        await fixture.close()
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
        print("THREAD_SIDECARD_TOGGLES_CONFIRMED card=\(card)")
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

    private func nativePanelFrame(in view: NSView) -> CGRect? {
        if view.identifier?.rawValue == "agent-reading-panel-frame", let window = view.window {
            return window.convertToScreen(view.convert(view.bounds, to: nil))
        }
        for child in view.subviews { if let frame = nativePanelFrame(in: child) { return frame } }
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
        #expect(state.retainedText == "Follow up") // retiring editor keeps its ink during travel
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
}
