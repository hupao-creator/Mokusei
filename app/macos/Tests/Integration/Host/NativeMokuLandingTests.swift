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
        func mount(fullWorkspace: Bool = false, width: CGFloat = 900, height: CGFloat = 620) {
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
            try await fixture.install([fixture.thread(status: .completed)])
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
            try await SwiftUIReplay.wait { fixture.presentation.followUpVisible && (readingPanel(in: root)?.bounds.width ?? expected.width) < expected.width - 300 }
            try click(toolbarPoint, window: try #require(fixture.window))
            try await SwiftUIReplay.wait { !fixture.presentation.followUpVisible && abs((readingPanel(in: root)?.bounds.width ?? 0) - expected.width) < 1 }
            try fixture.presentation.performInteraction(.toggleMokuInput)
            try await SwiftUIReplay.wait { fixture.scene.inputOpen && SwiftUIReplay.editor(in: root) != nil }
            let input = try #require(SwiftUIReplay.editor(in: root))
            input.insertText("Moku remains usable in the reading panel", replacementRange: NSRange(location: 0, length: 0))
            try await SwiftUIReplay.wait { fixture.presentation.draft.text == "Moku remains usable in the reading panel" }
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
        let point = panel.convert(CGPoint(x: panel.bounds.maxX - 30,
            y: panel.isFlipped ? 30 : panel.bounds.maxY - 30), to: root)
        try click(CGPoint(x: point.x, y: root.isFlipped ? point.y : root.bounds.height - point.y), window: window)
    }

    private func faces(in view: NSView) -> [NativeMokuCharacterCanvas] {
        if let canvas = view as? NativeMokuCharacterCanvas { return canvas.seat == .face ? [canvas] : [] }
        return view.subviews.flatMap { faces(in: $0) }
    }
    private func readingPanel(in view: NSView) -> NSView? {
        if view.identifier?.rawValue == "agent-reading-panel-frame" { return view }
        return view.subviews.lazy.compactMap { readingPanel(in: $0) }.first
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
            let report: JSONValue = .object([
                "id": .text("report"),
                "ref": ApplicationThreadRef(threadID: "report", typeID: "report.document").json,
                "revision": .integer(1), "createdAt": .integer(1), "updatedAt": .integer(1), "title": .text("Report"),
                "archived": .bool(false), "scope": .text(fixture.directory.path),
                "tags": .object(["tags": .array([.text("Fixture")]), "directoryTags": .array([.text("Fixture")]),
                    "semanticTags": .array([]), "tagEmojis": .object([:])]),
                "presentations": .array([.object(["id": .text("mokusei.overview"), "apiVersion": .integer(1),
                    "schemaVersion": .integer(1), "value": .object(["visible": .bool(true), "tagFilter": .text("directory"),
                        "coversExecutions": .array([])])])]),
                "view": .object(["previewText": .text("Report"), "contentRevision": .text("one"), "relatedExecutions": .array([])])])
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
