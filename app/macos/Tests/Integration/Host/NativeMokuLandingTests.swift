import AppKit
import Foundation
import SwiftUI
import ScreenCaptureKit
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiCore
import MokuseiPluginAPI
@testable import MokuseiPluginUI
import MokuseiHarnessCodex
import MokuseiApplications
import MokuseiSidecardConversation
@testable import MokuseiUI

// Catalog fixtures still need the real connection event: loading must retire
// on disconnect, even when a retained snapshot says its execution is running.
extension RuntimeClient {
    fileprivate func connectLandingFixture() { setStatus(.connected) }
    fileprivate func disconnectLandingFixture() { setStatus(.disconnected) }
    fileprivate func landingContentSubscriptions() -> [(String, JSONText)] {
        contentResources.map { ($0.key, $0.value.threadID) }
    }
    fileprivate func deliverLandingContent(_ state: JSONValue, subscription: String) {
        guard contentResources[subscription] != nil else { return }
        contentResources[subscription]?.value = state
        // Use the workspace's ordered event stream, after subscribe's loading
        // event, rather than racing a direct call into its Harness host.
        emit(.threadContent(subscriptionId: subscription, state: .ready(state)))
    }
}

@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeMokuLandingTests {
    @MainActor private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace: NativeWorkspaceModel
        let presentation: NativeWorkspacePresentation
        let authority = UUID()
        var window: NSWindow?
        var rejectSubmission = false
        var submissions = 0
        var stops = 0
        var revision = 0
        var contentPump: Task<Void, Never>?
        var scene: NativeMokuSceneState { presentation.scene }
        var overview: NativeOverviewWorkspaceModel { presentation.overview }
        var moku: NativeMokuWorkspacePresentation { presentation.moku }

        init(onboarding: Bool = false) throws {
            workspace = NativeWorkspaceModel(client: RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory, homeDirectory: directory)),
                preferences: DesktopPreferences(directory: directory), plugins: try .init(
                    harnesses: [AnyHarnessPlugin(CodexHarnessPlugin())], sidecards: [AnySidecardPlugin(NativeConversationSidecard())], applications: NativeApplicationModules.make()))
            if !onboarding { try workspace.preferences.setOnboardingCompleted(true) }
            presentation = NativeWorkspacePresentation(workspace: workspace)
            presentation.start()
            presentation.setScenePhase(.active)
            workspace.start()
        }
        func thread(_ id: JSONText = "child", status: PublicExecution.Status? = .running,
                    archived: Bool = false, history: Bool = false) throws -> HarnessThread {
            let execution = try status.map { try PublicExecution(executionID: JSONText("run-\(id.string)"), status: $0,
                startedAt: 1, finishedAt: $0 == .running || $0 == .waitingForUser ? nil : 2) }
            return try HarnessThread(id: id, harnessID: "codex", revision: revision + 1, sessionState: .null,
                observation: .init(latestExecution: execution), cwd: JSONText(directory.path), settings: .object([:]),
                createdAt: 1, updatedAt: Double(revision + 2), title: JSONText("Task \(id.string)"), tags: ["Work"],
                archived: archived, mokuHistory: history, tagEmojis: ["Work": "🛠️"],
                directoryTag: "Fixture", directoryScope: JSONText(directory.path))
        }
        func report() -> JSONValue {
            .object([
                "id": .text("report"),
                "ref": ApplicationThreadRef(threadID: "report", typeID: "report.document").json,
                "revision": .integer(1), "createdAt": .integer(1), "updatedAt": .integer(1), "title": .text("Report"),
                "archived": .bool(false), "scope": .text(directory.path),
                "tags": .object(["tags": .array([.text("Fixture")]), "directoryTags": .array([.text("Fixture")]),
                    "semanticTags": .array([]), "tagEmojis": .object([:])]),
                "presentations": .array([.object(["id": .text("mokusei.overview"), "apiVersion": .integer(1),
                    "schemaVersion": .integer(1), "value": .object(["visible": .bool(true), "tagFilter": .text("directory"),
                        "coversExecutions": .array([])])])]),
                "view": .object(["previewText": .text("Report"), "contentRevision": .text("one"), "relatedExecutions": .array([])])])
        }
        func install(_ threads: [HarnessThread] = [], operations: [JSONValue] = [], applications: [JSONValue] = [],
                     includeMoku: Bool = true, execution: JSONText = "moku-run", running: Bool = false) async throws {
            await workspace.client.connectLandingFixture()
            try await SwiftUIReplay.wait { self.workspace.connection == .connected && !self.workspace.synchronizing }
            revision += 1
            let coordinator = try HarnessThread(id: "moku", harnessID: "codex", revision: revision, sessionState: .null,
                observation: .init(latestExecution: operations.isEmpty && !running ? nil : try .init(executionID: execution, status: .running, startedAt: 1)),
                cwd: JSONText(directory.path), settings: .object([:]), createdAt: 0, updatedAt: Double(revision),
                title: "Moku", tags: [], moku: true, transcript: .array(operations))
            let snapshot: JSONValue = .object(["revision": .integer(revision), "settingsRevision": .integer(0),
                "defaultCwd": .text(directory.path), "settings": .object([:]),
                "threads": .array((includeMoku ? [coordinator.json] : []) + threads.map(\.json)),
                "executions": .array([]), "applicationThreads": .array(applications),
                "plugins": .array([.object(["key": .text("sidecard:conversation"), "enabled": .bool(true)])])])
            let event: RuntimeClientEvent = revision == 1 ? .snapshot(snapshot, authority: authority)
                : .mutation(.object([:]), state: snapshot, authority: authority)
            await workspace.installPrepared(snapshot, event: event)
            try #require(workspace.state == snapshot && workspace.catalog.revision == revision,
                         "Catalog installation failed: \(workspace.connectionError ?? "unknown")")
            #expect(overview.error == nil && workspace.runtimeAvailable)
        }
        func provideReadingContent() {
            contentPump = Task { @MainActor [weak self] in
                var published: [String: JSONValue] = [:]
                while !Task.isCancelled {
                    guard let self else { return }
                    for (subscription, threadID) in await workspace.client.landingContentSubscriptions() {
                        guard let thread = workspace.catalog.thread(threadID), thread.moku != true else { continue }
                        let activeID = thread.observation.latestExecution?.executionID
                        let ids = [JSONText("previous-" + threadID.string), JSONText("run-" + threadID.string)]
                        let turns = ids.enumerated().map { index, id -> JSONValue in
                            let active = thread.observation.isExecutionActive && activeID == id
                            let text = index == 0 ? "Previous execution for panel navigation" : "Current execution for panel navigation"
                            var turn: [JSONText: JSONValue] = ["executionId": .string(id),
                                "status": .text(active ? "running" : "completed"),
                                "createdAt": .integer(index + 1), "updatedAt": .integer(4),
                                "answer": .text(text), "reasoning": .text(""),
                                "messages": .array([.object(["id": .text(id.string + "-reply"), "role": .text("assistant"),
                                    "kind": .text("answer"), "content": .text(text), "createdAt": .integer(3), "attachments": .array([])])]),
                                "timeline": .array([.object(["id": .text(id.string + "-reply"), "kind": .text("assistant"),
                                    "itemId": .text(id.string + "-native"), "content": .text(text), "status": .text("complete"), "createdAt": .integer(3)])]),
                                "activities": .array([]), "interactions": .array([]), "plan": .array([]), "notices": .array([])]
                            if !active { turn["finishedAt"] = .integer(4) }
                            return .object(turn)
                        }
                        let state: JSONValue = .object(["schema": .text("mokusei.harness.codex.thread.v1"),
                            "updatedAt": .integer(4), "backgroundTerminals": .array([]), "turns": .array(turns)])
                        if published[subscription] != state {
                            await workspace.client.deliverLandingContent(state, subscription: subscription)
                            published[subscription] = state
                        }
                    }
                    do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                }
            }
        }
        func mount(fullWorkspace: Bool = false, width: CGFloat = 900, height: CGFloat = 620) {
            // Match SwiftUIReplay.window's self-inspection prerequisite for the
            // production panel Close and native Escape focus boundary.
            let enableAX = NSSelectorFromString("accessibilitySetValue:forAttribute:")
            if NSApp.responds(to: enableAX) { _ = NSApp.perform(enableAX, with: true, with: "AXEnhancedUserInterface") }
            let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: width, height: height),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Moku landing integration"
            window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
            if fullWorkspace {
                window.contentView = NSHostingView(rootView: NativeWorkspaceView(model: workspace, presentation: presentation)
                    .modifier(NativeWorkspaceWindowSurface()))
            } else {
                window.contentView = NSHostingView(rootView: Surface(fixture: self).modifier(NativeWorkspaceWindowSurface()))
            }
            self.window = window
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        func submit(_ submission: NativeComposerSubmission) async throws {
            submissions += 1
            if rejectSubmission { throw PluginContractError("fixture admission failed") }
        }
        func close() async {
            contentPump?.cancel(); await contentPump?.value
            window?.close()
            await presentation.release()
            try? await workspace.stop()
            scene.overviewState.camera.dispose()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private struct Surface: View {
        let fixture: Fixture
        var body: some View {
            NativeMokuScene(state: fixture.scene) {
                NativeOverviewWorkspaceView(model: fixture.overview, callbacks: .init(
                    openThread: { _, _ in }, openApplication: { _, _ in }, onSettings: { fixture.scene.openSettings() }),
                    interactionPaused: fixture.scene.interactionPaused, landing: fixture.moku.landing)
            } thread: { Text("History fixture") } dock: {
                if fixture.workspace.catalog.moku != nil {
                    NativeMokuDock(state: fixture.scene, draft: fixture.presentation.draft, cwd: JSONText(fixture.directory.path),
                        landing: fixture.moku.landing, mode: fixture.moku.dockMode, running: fixture.moku.running,
                        presentation: fixture.moku, onSend: fixture.submit, onCancel: { fixture.stops += 1 })
                }
            } settings: { Color.gray.overlay { Text("Settings fixture") } }
            .environment(\.locale, Locale(identifier: "zh-Hans"))
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture()
        do { try await body(fixture) }
        catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func detailCoalescesHiddenOverviewAndPreparesLatestReturnFrame() async throws {
        try await withFixture { fixture in
            try await fixture.install([fixture.thread("a", status: .completed), fixture.thread("b", status: .completed)])
            fixture.mount(fullWorkspace: true)
            let state = fixture.presentation.canvas
            try await SwiftUIReplay.wait { state.mountedCardIDs == ["a", "b"] && !state.isLayingOut && !state.camera.isAnimating }
            state.camera.setManualTransform(.init(scale: 1, x: 60, y: 100))
            let camera = state.camera.liveTransform
            fixture.presentation.open(.init(threadID: "a", typeID: "agent"))
            try await SwiftUIReplay.wait { !fixture.overview.presentationActive && !fixture.presentation.messageMotion.active }
            let retained = fixture.overview.items, solves = state.layoutSolveCount
            for _ in 0..<3 {
                try await fixture.install([fixture.thread("a", status: .completed), fixture.thread("b", archived: true),
                                           fixture.thread("c", status: .completed)], operations: [dispatch("hidden")])
            }
            fixture.window?.setContentSize(.init(width: 980, height: 700))
            try await Task.sleep(for: .milliseconds(150))
            #expect(fixture.overview.items == retained && state.layoutSolveCount == solves)
            #expect(state.mountedCardIDs == ["a", "b"])
            #expect(fixture.overview.featuredOperation?.id == "hidden" && fixture.overview.featuredOperation?.phase == .running)
            fixture.presentation.showOverview()
            try await SwiftUIReplay.wait {
                fixture.presentation.messageMotion.active && !state.isLayingOut
                    && Set(state.presentedPlacements.map(\.id)) == ["a", "c"]
                    && fixture.presentation.readingPanelSource == state.displayedFrame(for: "a")
            }
            #expect(fixture.overview.presentationActive && state.camera.manual && state.camera.liveTransform == camera)
            try await SwiftUIReplay.wait {
                fixture.presentation.selected == nil && !fixture.presentation.messageMotion.active && state.mountedCardIDs == ["a", "c"]
            }
            // Switching an already settled detail must retain the pause, and a
            // deleted selected route must still force a fresh direct return.
            fixture.presentation.open(.init(threadID: "a", typeID: "agent"))
            try await SwiftUIReplay.wait { !fixture.overview.presentationActive && !fixture.presentation.messageMotion.active }
            fixture.presentation.open(.init(threadID: "c", typeID: "agent"))
            try await SwiftUIReplay.wait { !fixture.overview.presentationActive && !fixture.presentation.messageMotion.active }
            await fixture.workspace.client.disconnectLandingFixture()
            try await SwiftUIReplay.wait { fixture.workspace.connection == .disconnected }
            try await fixture.install([fixture.thread("a", status: .completed), fixture.thread("c", status: .completed)])
            let snapshot = try #require(fixture.workspace.state)
            await fixture.workspace.installPrepared(snapshot, event: .snapshot(snapshot, authority: UUID()))
            #expect(!fixture.overview.presentationActive && fixture.presentation.selected?.threadID == "c")
            try await fixture.install([fixture.thread("a", status: .completed)])
            try await SwiftUIReplay.wait {
                fixture.presentation.selected == nil && fixture.overview.presentationActive && state.mountedCardIDs == ["a"] && !state.isLayingOut
            }
            #expect(fixture.overview.items.map(\.id) == ["a"])
            fixture.presentation.open(.init(threadID: "a", typeID: "agent"))
            let openingSource = fixture.presentation.readingPanelSource
            try await SwiftUIReplay.wait { fixture.presentation.messageMotion.active }
            #expect(!fixture.overview.presentationActive, "Panel opening freezes Overview projection before deferred reader admission")
            fixture.presentation.showOverview()
            #expect(fixture.presentation.readingPanelSource == openingSource)
            try await SwiftUIReplay.wait { fixture.presentation.selected == nil && !fixture.presentation.messageMotion.active }
            #expect(fixture.overview.presentationActive)
        }
    }
    private func dispatch(_ id: String = "create", completed: Bool = false, ok: Bool = false, thread: String = "child") -> JSONValue {
        var value: [JSONText: JSONValue] = ["type": .text("tool-operation"), "id": .text(id),
            "executionId": .text("moku-run"), "name": .text("create_thread"),
            "arguments": .object(["harnessId": .text("codex"), "prompt": .text("A first task"), "worktree": .bool(false)])]
        if completed {
            value["completedAt"] = .integer(2)
            value["isError"] = .bool(!ok)
            value["result"] = .object(["ok": .bool(ok), "threadId": ok ? .text(thread) : .null,
                "error": ok ? .null : .text("fixture rejected dispatch")])
        }
        return .object(value)
    }
    private func talk(_ text: String) -> JSONValue {
        .object(["type": .text("tool-operation"), "id": .text("talk-\(text)"), "executionId": .text("moku-run"),
            "name": .text("talk"), "completedAt": .integer(2), "arguments": .object(["text": .text(text)])])
    }
    private func press(_ key: UInt16, characters: String, window: NSWindow) throws {
        window.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: key)))
    }

    private func click(_ point: CGPoint, window: NSWindow) throws {
        let root = try #require(window.contentView)
        let location = root.convert(CGPoint(x: point.x, y: root.isFlipped ? point.y : root.bounds.height - point.y), to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type,
                location: location, modifierFlags: [],
                timestamp: timestamp + (type == .leftMouseUp ? 0.01 : 0), windowNumber: window.windowNumber,
                context: nil, eventNumber: type == .leftMouseUp ? 1 : 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        }
        // Native text selection may synchronously track until mouse-up; SwiftUI
        // buttons can leave the release queued for the app event loop instead.
        NSApp.postEvent(try event(.leftMouseUp), atStart: true)
        NSApp.sendEvent(try event(.leftMouseDown))
        if let release = NSApp.nextEvent(matching: .leftMouseUp, until: nil, inMode: .default, dequeue: true) { NSApp.sendEvent(release) }
    }

    @Test func firstRunOwnsAdmissionWithoutMountingTheHiddenComposer() async throws {
        let fixture = try Fixture(onboarding: true)
        do {
            fixture.mount(fullWorkspace: true)
            try await fixture.install(includeMoku: false)
            #expect(!fixture.presentation.onboarding.admitted)
            try await fixture.install()
            try await SwiftUIReplay.wait { fixture.presentation.onboarding.mounted && fixture.presentation.onboarding.admitted }
            #expect(fixture.presentation.interactionPage == "onboarding")
            #expect(!fixture.scene.inputOpen && !fixture.presentation.onboarding.mountDock)
            #expect(SwiftUIReplay.editor(in: try #require(fixture.window?.contentView)) == nil)
            #expect(!fixture.presentation.canOpenSettings)
            #expect(!fixture.presentation.interactionActions.contains("moku.input"))
            #expect(throws: NativeInteractionError.self) { try fixture.presentation.performInteraction(.openSettings) }
            let preferences = fixture.workspace.preferences
            #expect(preferences.onboardingPending && !preferences.onboardingCompleted)
            try preferences.setAppearance(.dark)
            try preferences.selectThread(nil)
            let reopened = DesktopPreferences(directory: fixture.directory)
            #expect(reopened.onboardingPending && !reopened.onboardingCompleted)
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func archivedHistoryBypassesFirstRunButPendingSetupDoesNot() async throws {
        for pending in [false, true] {
            let fixture = try Fixture(onboarding: true)
            do {
                if pending { try fixture.workspace.preferences.setOnboardingCompleted(false) }
                try await fixture.install([fixture.thread(status: .completed, archived: true)])
                #expect(fixture.presentation.onboarding.blocksWorkspace == pending)
                #expect(fixture.workspace.preferences.onboardingCompleted == !pending)
            } catch { await fixture.close(); throw error }
            await fixture.close()
        }
    }

    @Test func failedPendingMarkerWriteKeepsFirstRunRetryable() async throws {
        let fixture = try Fixture(onboarding: true)
        do {
            let marker = fixture.directory.appendingPathComponent("desktop-preferences.json")
            try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
            try await fixture.install()
            #expect(!fixture.presentation.onboarding.admitted)
            #expect(fixture.presentation.onboarding.blocksWorkspace)
            #expect(fixture.presentation.onboarding.error != nil)
            try FileManager.default.removeItem(at: marker)
            fixture.presentation.onboarding.retry()
            #expect(fixture.presentation.onboarding.admitted)
            #expect(DesktopPreferences(directory: fixture.directory).onboardingPending)
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOKUSEI_READING_PRESENTATION_NATIVE_REPLAY"] == "1",
        "Requires the isolated AppKit event loop for native landing input: python3 tools/verification/reading-presentation/run.py --moku-landing"))
    func realWorkspaceWaitsForHydrationAndCentersItsEmptyComposer() async throws {
        try await withFixture { fixture in
            fixture.mount(fullWorkspace: true)
            #expect(!fixture.moku.landing && !fixture.scene.inputOpen)
            try await fixture.install(includeMoku: false)
            #expect(!fixture.moku.landing && !fixture.workspace.hasInitialContent)
            try await fixture.install([fixture.thread("old-moku", status: .completed, archived: true, history: true)])
            try await SwiftUIReplay.wait { fixture.scene.inputOpen && fixture.scene.capsuleFrame.width == 680 }
            let height = try #require(fixture.window?.contentView).bounds.height
            #expect(fixture.moku.landing && fixture.overview.globalConversationCount == 0)
            #expect(fixture.scene.capsuleFrame.height == 76 && abs(fixture.scene.capsuleFrame.midY - height / 2) < 1)
            let window = try #require(fixture.window), root = try #require(window.contentView)
            let editor = try #require(SwiftUIReplay.editor(in: root))
            editor.insertText("保留 landing 草稿", replacementRange: .init(location: 0, length: 0))
            let capsule = fixture.scene.capsuleFrame
            try click(CGPoint(x: capsule.midX, y: capsule.midY), window: window)
            #expect(fixture.scene.inputOpen)
            try click(CGPoint(x: 30, y: capsule.minY - 40), window: window)
            #expect(fixture.scene.inputOpen)
            #expect(fixture.moku.landing && fixture.presentation.draft.text == "保留 landing 草稿")
            let other = NSWindow(contentRect: CGRect(x: 1000, y: 100, width: 160, height: 100),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            other.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 160, height: 100))
            other.makeKeyAndOrderFront(nil)
            defer { other.close() }
            #expect(fixture.scene.inputOpen)
            try click(CGPoint(x: 50, y: 50), window: other)
            #expect(fixture.scene.inputOpen)
            #expect(fixture.presentation.draft.text == "保留 landing 草稿")
        }
        try await withFixture { fixture in
            try await fixture.install(running: true); fixture.mount(fullWorkspace: true)
            let root = try #require(fixture.window?.contentView)
            try await SwiftUIReplay.wait { faces(in: root).first?.controller.input?.running == true }
            #expect(fixture.moku.landing && !fixture.scene.inputOpen && fixture.scene.dockHitRects.count == 1)
            #expect(fixture.scene.capsuleFrame.width > NativeMokuCapsuleLayout.idleSize.width)
        }
        try await withFixture { fixture in
            try fixture.workspace.preferences.setAppearance(.light)
            // The execution launcher requires an observed active execution and
            // real loaded history. A completed catalog-only fixture has neither.
            try await fixture.install([fixture.thread(status: .running)])
            fixture.provideReadingContent()
            fixture.mount(fullWorkspace: true, width: 1100, height: 760)
            let root = try #require(fixture.window?.contentView)
            try await SwiftUIReplay.wait { fixture.presentation.canvas.allowsActivation(cardID: "child") && fixture.presentation.canvas.displayedFrame(for: "child") != nil }
            let origin = try #require(fixture.presentation.canvas.displayedFrame(for: "child"))
            let face = try #require(faces(in: root).first)
            fixture.presentation.open(.init(threadID: "child", typeID: "agent"))
            #expect(fixture.presentation.readingPanelSource == origin)
            try await SwiftUIReplay.wait {
                fixture.presentation.mountedReadingThread?.threadID == "child" && !fixture.presentation.messageMotion.active
                    && readingPanel(in: root) != nil
            }
            // Active entry now opens its execution sidecard once. Fold it via
            // the real launcher before testing the existing reopen/close cycle.
            let initialPanel = NativeReadingPanelGeometry.frame(in: root.bounds.size)
            try await SwiftUIReplay.wait {
                (readingPanel(in: root)?.bounds.width ?? initialPanel.width) < initialPanel.width - 300
            }
            #expect(!fixture.presentation.followUpVisible, "The read-only execution sidecard does not own input visibility")
            try click(CGPoint(x: initialPanel.maxX + 38, y: initialPanel.midY), window: try #require(fixture.window))
            try await SwiftUIReplay.wait {
                !fixture.presentation.followUpVisible && abs((readingPanel(in: root)?.bounds.width ?? 0) - initialPanel.width) < 1
            }
            let captureContent = try await SCShareableContent.currentProcess
            if let own = captureContent.windows.first(where: { $0.windowID == CGWindowID(fixture.window!.windowNumber) }) {
                let config = SCStreamConfiguration(); config.width = 1100; config.height = 760; config.ignoreShadowsSingleWindow = true
                let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: config)
                let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("evidence/agent-panel")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let bitmap = NSBitmapImageRep(cgImage: image)
                try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("root.png"))
                let panelBounds = NativeReadingPanelGeometry.frame(in: root.bounds.size)
                let centerX = Int((panelBounds.maxX + 38) * CGFloat(image.width) / root.bounds.width)
                let centerY = Int(panelBounds.midY * CGFloat(image.height) / root.bounds.height)
                var ink = 0
                for y in (centerY - 9)...(centerY + 9) {
                    for x in (centerX - 9)...(centerX + 9) {
                        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                           color.redComponent < 0.4 && color.greenComponent < 0.4 && color.blueComponent < 0.4 { ink += 1 }
                    }
                }
                #expect(ink > 5, "The external launcher's icon must be visibly painted, not merely present in AX")
            }
            #expect(fixture.scene.dockRouteVisible && !fixture.scene.overviewVisible)
            #expect(!fixture.presentation.canOpenSettings && !fixture.scene.canOpenSettings)
            #expect(fixture.presentation.interactionActions.contains("moku.input.toggle"))
            #expect(faces(in: root).contains { $0 === face }, "The resident Moku must survive entry into an Agent panel")
            let panel = try #require(readingPanel(in: root))
            let frame = panel.convert(panel.bounds, to: root)
            let expected = NativeReadingPanelGeometry.frame(in: root.bounds.size)
            let top = root.isFlipped ? frame.minY : root.bounds.height - frame.maxY
            #expect(abs(frame.width - expected.width) < 1 && abs(frame.height - expected.height) < 1
                && abs(frame.minX - expected.minX) < 1 && abs(top - expected.minY) < 1)
            // This is a real pointer event outside the main panel, not an AX
            // invocation: it catches ancestor clipping of the external launcher.
            let toolbarPoint = CGPoint(x: expected.maxX + 38, y: expected.midY)
            try click(toolbarPoint, window: try #require(fixture.window))
            try await SwiftUIReplay.wait { (readingPanel(in: root)?.bounds.width ?? expected.width) < expected.width - 300 }
            #expect(!fixture.presentation.followUpVisible, "Execution display must not advertise an input sidecard")
            try click(toolbarPoint, window: try #require(fixture.window))
            try await SwiftUIReplay.wait { !fixture.presentation.followUpVisible && abs((readingPanel(in: root)?.bounds.width ?? 0) - expected.width) < 1 }
            try fixture.presentation.performInteraction(.toggleMokuInput)
            try await SwiftUIReplay.wait { fixture.scene.inputOpen && SwiftUIReplay.editor(in: root) != nil }
            let input = try #require(SwiftUIReplay.editor(in: root))
            input.insertText("Moku remains usable in the reading panel", replacementRange: NSRange(location: 0, length: 0))
            try await SwiftUIReplay.wait { fixture.presentation.dockDraft.text == "Moku remains usable in the reading panel" }
            #expect(fixture.presentation.dockDraft !== fixture.presentation.draft,
                "Agent input belongs to its Thread and must not overwrite the Overview draft")
            fixture.scene.setInputOpen(false)
            fixture.presentation.open(.init(threadID: "child", typeID: "agent"), target: .init(
                executionID: "run-child", requestID: "same-thread-result", mode: .history, position: .result))
            #expect(fixture.presentation.readingPanelSource == origin, "Same-thread reading targets retain their return origin")
            fixture.window?.setContentSize(CGSize(width: 980, height: 700))
            try await SwiftUIReplay.wait { root.bounds.width == 980 && fixture.presentation.canvas.displayedFrame(for: "child") != nil }
            let returnOrigin = fixture.presentation.canvas.displayedFrame(for: "child")
            try closeAgentPanel(in: try #require(fixture.window))
            #expect(fixture.presentation.readingPanelSource == returnOrigin)
            try await SwiftUIReplay.wait { fixture.presentation.selected == nil && !fixture.presentation.messageMotion.active }
            #expect(fixture.scene.overviewVisible && fixture.scene.dockRouteVisible)
            #expect(faces(in: root).contains { $0 === face })
            // Direct result visits have no Overview card prerequisite and retain
            // the same close route while their Harness loads the target.
            fixture.presentation.open(.init(threadID: "child", typeID: "agent"), target: .init(
                executionID: "run-child", requestID: "panel-result", mode: .history, position: .result))
            try await SwiftUIReplay.wait { fixture.presentation.navigation != nil && !fixture.presentation.messageMotion.active }
            try closeAgentPanel(in: try #require(fixture.window))
            try #require(fixture.presentation.messageMotion.active, "The icon-center click must start the real return")
            fixture.window?.setContentSize(CGSize(width: 940, height: 680))
            try await SwiftUIReplay.wait { fixture.presentation.selected == nil }
            try await Task.sleep(for: .milliseconds(450))
            #expect(fixture.presentation.selected == nil, "Layout updates must not restore the closed route")
            for interruption in ["mutation", "same-snapshot", "reconnect", "disconnect", "appearance"] {
                fixture.presentation.open(.init(threadID: "child", typeID: "agent"))
                try await SwiftUIReplay.wait {
                    fixture.presentation.mountedReadingThread?.threadID == "child" && !fixture.presentation.messageMotion.active
                        && readingPanel(in: root) != nil
                }
                let panel = try #require(readingPanel(in: root))
                // An active execution opens its sidecard after reader admission;
                // wait for that second layout transition before targeting Close.
                var lastFrame = panel.convert(panel.bounds, to: root)
                var stableSince = ContinuousClock.now
                try await SwiftUIReplay.wait {
                    let frame = panel.convert(panel.bounds, to: root)
                    if frame != lastFrame { lastFrame = frame; stableSince = .now }
                    return stableSince.duration(to: .now) > .milliseconds(450)
                }
                let settledFrame = panel.convert(panel.bounds, to: root)
                try await Task.sleep(for: .milliseconds(100))
                try #require(panel.convert(panel.bounds, to: root) == settledFrame, "Close target must be settled before input")
                try closeAgentPanel(in: try #require(fixture.window))
                try #require(fixture.presentation.messageMotion.active, "The settled icon click must be accepted before recovery")
                var interruptedReturn = false
                if interruption == "disconnect" {
                    let callback = fixture.workspace.onConnectionChange
                    fixture.workspace.onConnectionChange = { status in
                        if status == .disconnected { interruptedReturn = interruptedReturn || fixture.presentation.messageMotion.active }
                        callback?(status)
                    }
                    await fixture.workspace.client.disconnectLandingFixture()
                    try await SwiftUIReplay.wait { fixture.workspace.connection == .disconnected }
                    fixture.workspace.onConnectionChange = callback
                } else if interruption == "appearance" {
                    interruptedReturn = fixture.presentation.messageMotion.active
                    try fixture.workspace.preferences.setAppearance(.dark)
                } else {
                    let snapshot = try #require(fixture.workspace.state)
                    let authority = try #require(fixture.workspace.snapshotAuthority)
                    let callback = fixture.workspace.onCatalogChange
                    fixture.workspace.onCatalogChange = { event in
                        interruptedReturn = interruptedReturn || fixture.presentation.messageMotion.active
                        callback?(event)
                    }
                    let event: RuntimeClientEvent = interruption == "mutation"
                        ? .mutation(.object([:]), state: snapshot, authority: authority)
                        : .snapshot(snapshot, authority: interruption == "reconnect" ? UUID() : authority)
                    await fixture.workspace.installPrepared(snapshot, event: event)
                    fixture.workspace.onCatalogChange = callback
                }
                try #require(interruptedReturn, "The event must arrive before the accepted return finishes")
                try await SwiftUIReplay.wait { fixture.presentation.selected == nil && !fixture.presentation.messageMotion.active }
                if interruption == "disconnect" {
                    await fixture.workspace.client.connectLandingFixture()
                    try await SwiftUIReplay.wait { fixture.workspace.connection == .connected }
                }
            }
        }
        for type in ["report.document", "git.worktree"] {
            try await withFixture { fixture in
                fixture.presentation.applicationHost.git.stop()
                let report = fixture.report()
                try await fixture.install([fixture.thread(status: .completed)], applications: [report])
                if type == "git.worktree" {
                    let repository = try NativeGitRepository(.object([
                        "id": .text("git-fixture"), "available": .bool(true), "directories": .array([.text(fixture.directory.path)]),
                        "snapshot": .object(["root": .text(fixture.directory.path), "branch": .text("main"), "head": .null,
                            "upstream": .null, "ahead": .null, "behind": .null, "additions": .integer(2), "deletions": .integer(1),
                            "lineStatsError": .null, "changed": .integer(1), "staged": .integer(0), "unstaged": .integer(1),
                            "untracked": .integer(0), "conflicts": .integer(0)]),
                        "sync": .object(["attemptedAt": .integer(1), "observedAt": .integer(1), "error": .null])]))
                    fixture.presentation.applicationHost.git.install([repository])
                    fixture.overview.refreshCardExtensions()
                }
                let directoryFilter = try #require(fixture.overview.filters.first(where: { $0.isDirectory }))
                fixture.overview.selectTag(directoryFilter)
                fixture.mount(fullWorkspace: true, width: 1100, height: 760)
                let window = try #require(fixture.window), root = try #require(window.contentView)
                let sourceID = type == "report.document" ? "report" : "child"
                let ref = ApplicationThreadRef(threadID: type == "report.document" ? "report" : "git-fixture", typeID: JSONText(type))
                let identifier = type == "report.document" ? "report-reading-panel-frame" : "git-reading-panel-frame"
                try await SwiftUIReplay.wait {
                    fixture.presentation.canvas.allowsActivation(cardID: sourceID)
                        && fixture.presentation.canvas.displayedFrame(for: sourceID) != nil
                }
                let origin = try #require(fixture.presentation.canvas.displayedFrame(for: sourceID))
                let face = try #require(faces(in: root).first)
                fixture.presentation.open(ref, sourceCardID: sourceID)
                #expect(fixture.presentation.usesReadingPanel && fixture.presentation.readingPanelSource == origin)
                try await SwiftUIReplay.wait {
                    fixture.presentation.mountedReadingThread == ref && !fixture.presentation.messageMotion.active
                        && readingPanel(in: root, identifier: identifier) != nil
                }
                for width: CGFloat in [1100, 540, 980] {
                    window.setContentSize(CGSize(width: width, height: 700))
                    try await SwiftUIReplay.wait { abs(root.bounds.width - width) < 1 }
                    try await Task.sleep(for: .milliseconds(100))
                    let panel = try #require(readingPanel(in: root, identifier: identifier))
                    let frame = panel.convert(panel.bounds, to: root)
                    let expected = NativeReadingPanelGeometry.frame(in: root.bounds.size)
                    let top = root.isFlipped ? frame.minY : root.bounds.height - frame.maxY
                    #expect(abs(frame.width - expected.width) < 1 && abs(frame.height - expected.height) < 1
                        && abs(frame.minX - expected.minX) < 1 && abs(top - expected.minY) < 1)
                    #expect(fixture.scene.dockRouteVisible && !fixture.scene.overviewVisible && !fixture.presentation.canOpenSettings)
                    #expect(!fixture.presentation.nativeApplicationNavigation)
                    #expect(faces(in: root).contains { $0 === face })
                }
                #expect(!fixture.overview.presentationActive)
                let retainedItems = fixture.overview.items
                try await fixture.install([fixture.thread(status: .completed), fixture.thread("added-while-hidden", status: .completed)], applications: [report])
                #expect(fixture.overview.items == retainedItems)
                try fixture.presentation.performInteraction(.toggleMokuInput)
                try await SwiftUIReplay.wait { fixture.scene.inputOpen && SwiftUIReplay.editor(in: root) != nil }
                fixture.scene.setInputOpen(false)
                let panel = try #require(readingPanel(in: root, identifier: identifier))
                let point = panel.convert(CGPoint(x: panel.bounds.minX + 30,
                    y: panel.isFlipped ? 30 : panel.bounds.maxY - 30), to: root)
                try click(CGPoint(x: point.x, y: root.isFlipped ? point.y : root.bounds.height - point.y), window: window)
                try #require(fixture.presentation.messageMotion.active)
                try await SwiftUIReplay.wait {
                    fixture.overview.presentationActive && !fixture.presentation.canvas.isLayingOut
                        && fixture.overview.items.contains { $0.id == "added-while-hidden" }
                        && fixture.presentation.readingPanelSource == fixture.presentation.canvas.displayedFrame(for: sourceID)
                        && fixture.presentation.readingPanelSource != nil
                }
                window.setContentSize(CGSize(width: 940, height: 680))
                try await SwiftUIReplay.wait { fixture.presentation.selected == nil && !fixture.presentation.messageMotion.active }
                #expect(fixture.scene.overviewVisible && faces(in: root).contains { $0 === face })
                try await SwiftUIReplay.wait { readingPanel(in: root, identifier: identifier) == nil }
                fixture.presentation.open(ref, sourceCardID: sourceID)
                do {
                    try await SwiftUIReplay.wait {
                        let labels = SwiftUIReplay.text(in: root)
                        return fixture.presentation.mountedReadingThread == ref && !fixture.presentation.messageMotion.active
                            && (labels.contains("关闭面板") || labels.contains("Close panel"))
                    }
                } catch {
                    print("PANEL_REOPEN type=\(type) selected=\(String(describing: fixture.presentation.selected)) mounted=\(String(describing: fixture.presentation.mountedReadingThread)) content=\(fixture.workspace.hasInitialContent) scene=\(fixture.scene.overviewVisible)/\(fixture.scene.readingPanelVisible)/\(fixture.scene.mokuOpen)/\(fixture.scene.cameraActive)/\(fixture.scene.inputOpen) frame=\(String(describing: readingPanel(in: root, identifier: identifier)?.frame)) labels=\(SwiftUIReplay.text(in: root))")
                    if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                        root.cacheDisplay(in: root.bounds, to: bitmap)
                        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("evidence/panel-reopen")
                        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(type + ".png"))
                    }
                    throw error
                }
                window.makeFirstResponder(root)
                let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
                // Native reading Escape is an application-level event monitor.
                // Window.sendEvent would bypass the production owner entirely.
                NSApp.sendEvent(escape)
                try await SwiftUIReplay.wait { fixture.presentation.selected == nil && !fixture.presentation.messageMotion.active }
            }
        }
    }

    @Test func pendingShellAndFailureStayCenteredUntilExplicitDispatchSuccess() async throws {
        try await withFixture { fixture in
            try await fixture.install(); fixture.mount()
            try await SwiftUIReplay.wait { fixture.scene.inputOpen }
            fixture.scene.setInputOpen(false)
            try await fixture.install(operations: [dispatch()])
            try await fixture.install([fixture.thread(status: nil)], operations: [dispatch()])
            #expect(fixture.moku.landing && fixture.overview.globalConversationCount == 1)
            try await fixture.install([fixture.thread(status: nil)], operations: [dispatch(completed: true)])
            #expect(fixture.moku.landing && fixture.moku.talkMessage?.dispatch?.phase == .failed)
            try await fixture.install([fixture.thread()], operations: [dispatch("retry")])
            #expect(fixture.moku.landing) // A running public record still precedes native admission.
            // A later Talk and another pending creation must not hide the first
            // successful result from the landing decision.
            try await fixture.install([fixture.thread()], operations: [dispatch("retry", completed: true, ok: true),
                talk("任务已交给执行者"), dispatch("parallel", thread: "next")])
            try await SwiftUIReplay.wait { !fixture.moku.landing && !fixture.scene.inputOpen }
            try await SwiftUIReplay.wait {
                fixture.scene.overviewState.mountedCardIDs.contains("child")
                    && fixture.scene.overviewState.allowsActivation(cardID: "child")
            }
            fixture.scene.dismissTalk()
            try await SwiftUIReplay.wait { fixture.scene.capsuleFrame.size == NativeMokuCapsuleLayout.idleSize }
            let bounds = try #require(fixture.window?.contentView).bounds
            #expect(fixture.scene.capsuleFrame == NativeMokuCapsuleLayout.idleSurface(in: bounds))
        }
    }

    @Test func filteredResultsDoNotReenterButArchivingAndDeletingAllDo() async throws {
        try await withFixture { fixture in
            try await fixture.install([fixture.thread(), fixture.thread("second")]); fixture.mount()
            #expect(!fixture.moku.landing && fixture.overview.globalConversationCount == 2)
            let directory = try #require(fixture.overview.filters.first { $0.isDirectory })
            fixture.overview.selectTag(directory)
            fixture.overview.beginSearch(); fixture.overview.updateSearch("unmatched-keyword")
            #expect(fixture.overview.items.isEmpty && fixture.overview.globalConversationCount == 2 && !fixture.moku.landing)
            fixture.overview.endSearch()
            try await fixture.install([fixture.thread(archived: true), fixture.thread("second", archived: true)],
                operations: [dispatch(completed: true, ok: true)])
            try await SwiftUIReplay.wait { fixture.moku.landing && fixture.scene.talkPresentation.presented }
            #expect(!fixture.scene.inputOpen)
            try await fixture.install([fixture.thread()], operations: [])
            try await SwiftUIReplay.wait { !fixture.moku.landing }
            try await fixture.install()
            try await SwiftUIReplay.wait { fixture.moku.landing && fixture.scene.inputOpen }
        }
    }

    private func closeAgentPanel(in window: NSWindow) throws {
        let root = try #require(window.contentView)
        let panel = try #require(readingPanel(in: root))
        // The production Close circle has 14pt inset and 16pt radius. Measure
        // its mounted panel, including any outer panel animation/transform.
        let point = panel.convert(CGPoint(x: panel.bounds.minX + 30,
            y: panel.isFlipped ? 30 : panel.bounds.maxY - 30), to: root)
        try click(CGPoint(x: point.x, y: root.isFlipped ? point.y : root.bounds.height - point.y), window: window)
    }

    private func faces(in view: NSView) -> [NativeMokuCharacterCanvas] {
        if let canvas = view as? NativeMokuCharacterCanvas { return canvas.seat == .face ? [canvas] : [] }
        return view.subviews.flatMap { faces(in: $0) }
    }
    private func readingPanel(in view: NSView, identifier: String = "agent-reading-panel-frame") -> NSView? {
        if view.identifier?.rawValue == identifier { return view }
        return view.subviews.lazy.compactMap { readingPanel(in: $0, identifier: identifier) }.first
    }
    private func element(id: String, in object: NSObject) -> NSObject? {
        let identifier = NSSelectorFromString("accessibilityIdentifier")
        if object.responds(to: identifier), object.perform(identifier)?.takeUnretainedValue() as? String == id { return object }
        let children = NSSelectorFromString("accessibilityChildren")
        if object.responds(to: children), let values = object.perform(children)?.takeUnretainedValue() as? [NSObject] {
            for child in values { if let found = element(id: id, in: child) { return found } }
        }
        if let view = object as? NSView {
            for child in view.subviews { if let found = element(id: id, in: child) { return found } }
        }
        return nil
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOKUSEI_READING_PRESENTATION_NATIVE_REPLAY"] == "1",
        "Requires the isolated AppKit event loop for native landing input: python3 tools/verification/reading-presentation/run.py --moku-landing"))
    func oneResidentOwnsSubmissionRunningTalkDispatchAndStop() async throws {
        try await withFixture { fixture in
            try await fixture.install(); fixture.mount()
            try await SwiftUIReplay.wait { fixture.scene.inputOpen }
            let window = try #require(fixture.window), root = try #require(window.contentView)
            let face = try #require(faces(in: root).first)
            let input = try #require(SwiftUIReplay.editor(in: root))
            input.insertText("继续完善需求", replacementRange: NSRange(location: 0, length: 0))
            fixture.rejectSubmission = true
            try press(36, characters: "\r", window: window)
            try await SwiftUIReplay.wait { fixture.presentation.draft.error != nil && fixture.scene.inputOpen }
            #expect(fixture.submissions == 1 && fixture.presentation.draft.text == "继续完善需求")
            fixture.rejectSubmission = false
            try await SwiftUIReplay.wait { SwiftUIReplay.editor(in: root) != nil }
            try press(36, characters: "\r", window: window)
            try await SwiftUIReplay.wait { fixture.submissions == 2 && !fixture.scene.inputOpen && !fixture.scene.inputLeaving }
            try await fixture.install(running: true)
            try await SwiftUIReplay.wait { face.controller.input?.running == true }
            #expect(fixture.moku.landing && fixture.presentation.draft.text.isEmpty)
            #expect(fixture.scene.dockHitRects.count == 1 && faces(in: root).count == 1 && faces(in: root).first === face)
            #expect(fixture.scene.capsuleFrame.width > NativeMokuCapsuleLayout.idleSize.width)
            #expect(abs(fixture.scene.capsuleFrame.midY - root.bounds.midY) < 1)
            let enableAX = NSSelectorFromString("accessibilitySetValue:forAttribute:")
            if NSApp.responds(to: enableAX) { _ = NSApp.perform(enableAX, with: true, with: "AXEnhancedUserInterface") }
            try await SwiftUIReplay.wait { element(id: "moku-stop", in: root) != nil }
            _ = try #require(element(id: "moku-stop", in: root)).perform(NSSelectorFromString("accessibilityPerformPress"))
            #expect(fixture.stops == 1)
            try await fixture.install(operations: [talk("你希望任务在哪个目录进行？")])
            try await SwiftUIReplay.wait { fixture.scene.talkPresentation.presented }
            #expect(!fixture.scene.inputOpen && fixture.scene.dockHitRects.count == 1)
            #expect(element(id: "moku-landing-notice", in: root) == nil)
            #expect(SwiftUIReplay.text(in: root).contains("你希望任务在哪个目录进行？"))
            #expect(faces(in: root).count == 1 && faces(in: root).first === face)
            try await SwiftUIReplay.wait { element(id: "moku-open-input", in: root) != nil }
            _ = try #require(element(id: "moku-open-input", in: root)).perform(NSSelectorFromString("accessibilityPerformPress"))
            try await SwiftUIReplay.wait { fixture.scene.inputOpen && SwiftUIReplay.editor(in: root) != nil }
            let followup = try #require(SwiftUIReplay.editor(in: root))
            followup.insertText("保留这份补充", replacementRange: .init(location: 0, length: 0))
            try await fixture.install(operations: [dispatch()])
            #expect(!fixture.scene.talkPresentation.presented && fixture.scene.dockHitRects.count == 1)
            #expect(fixture.presentation.draft.text == "保留这份补充" && SwiftUIReplay.editor(in: root) === followup)
            try press(53, characters: "\u{1b}", window: window)
            try await SwiftUIReplay.wait { !fixture.scene.inputOpen && fixture.scene.talkPresentation.presented }
            #expect(fixture.moku.talkMessage?.dispatch?.phase == .dispatching && fixture.scene.dockHitRects.count == 1)
            #expect(faces(in: root).count == 1 && faces(in: root).first === face)
            window.setContentSize(CGSize(width: 480, height: 360))
            try await SwiftUIReplay.wait { fixture.scene.capsuleFrame.width == 400 }
            #expect(abs(fixture.scene.capsuleFrame.midY - root.bounds.midY) < 1)
            fixture.scene.dismissTalk()
            fixture.scene.toggleInput()
            try await SwiftUIReplay.wait { fixture.scene.inputOpen && fixture.scene.capsuleFrame.width == 432 }
            #expect(fixture.presentation.draft.text == "保留这份补充")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOKUSEI_READING_PRESENTATION_NATIVE_REPLAY"] == "1",
        "Requires the isolated AppKit event loop for native landing input: python3 tools/verification/reading-presentation/run.py --moku-landing"))
    func centerSurvivesEscapeResizeCoveringRoutesAndRemount() async throws {
        try await withFixture { fixture in
            try await fixture.install(); fixture.mount()
            try await SwiftUIReplay.wait { fixture.scene.inputOpen }
            let window = try #require(fixture.window), root = try #require(window.contentView)
            let input = try #require(SwiftUIReplay.editor(in: root))
            input.insertText("保留草稿", replacementRange: .init(location: 0, length: 0))
            try press(53, characters: "\u{1b}", window: window)
            try await SwiftUIReplay.wait { !fixture.scene.inputOpen && !fixture.scene.inputLeaving }
            fixture.scene.toggleInput()
            window.setContentSize(CGSize(width: 480, height: 620))
            try await SwiftUIReplay.wait { fixture.scene.capsuleFrame.width == 432 }
            fixture.scene.openSettings()
            try await SwiftUIReplay.wait { fixture.scene.settingsOpen && !fixture.scene.settingsTransitioning && !fixture.scene.dockHitRects.isEmpty }
            fixture.scene.closeSettings(); fixture.scene.settle()
            try await SwiftUIReplay.wait { !fixture.scene.dockCovered && fixture.scene.inputOpen && !fixture.scene.capsuleFrame.isEmpty }
            fixture.scene.setMokuOpen(true)
            try await SwiftUIReplay.wait { fixture.scene.dockCovered }
            #expect(!fixture.presentation.canOpenSettings)
            #expect(!fixture.presentation.interactionActions.contains("settings.open"))
            fixture.presentation.openSettings()
            #expect(!fixture.scene.settingsOpen && fixture.scene.mokuOpen)
            #expect(throws: NativeInteractionError.self) { try fixture.presentation.performInteraction(.openSettings) }
            fixture.scene.setMokuOpen(false)
            try await SwiftUIReplay.wait { !fixture.scene.inputOpen && !fixture.scene.dockCovered }
            window.contentView = NSHostingView(rootView: Text("Temporarily unmounted"))
            try await Task.sleep(for: .milliseconds(50))
            window.contentView = NSHostingView(rootView: Surface(fixture: fixture).modifier(NativeWorkspaceWindowSurface()))
            window.setContentSize(CGSize(width: 480, height: 620))
            try await SwiftUIReplay.wait { fixture.scene.windowVisible && !fixture.scene.inputOpen && fixture.scene.capsuleFrame.width < 432 }
            #expect(fixture.presentation.draft.text == "保留草稿" && fixture.moku.landing)
            fixture.scene.toggleInput()
            try await SwiftUIReplay.wait { fixture.scene.inputOpen && !fixture.scene.capsuleFrame.isEmpty }
            try click(CGPoint(x: 30, y: 100), window: window)
            #expect(fixture.scene.inputOpen)
        }
    }

    @Test func directoryOnlyDocumentsAndRehydrationKeepGlobalMembership() async throws {
        try await withFixture { fixture in
            let report = fixture.report()
            try await fixture.install(applications: [report]); fixture.mount()
            #expect(fixture.overview.items.isEmpty && fixture.overview.globalConversationCount == 1 && !fixture.moku.landing)
            let snapshot = try #require(fixture.workspace.state)
            await fixture.workspace.installPrepared(snapshot, event: .snapshot(snapshot, authority: UUID()))
            #expect(!fixture.moku.landing && fixture.overview.globalConversationCount == 1)
            try await fixture.install()
            try await SwiftUIReplay.wait { fixture.moku.landing && fixture.scene.inputOpen }
        }
    }
}
