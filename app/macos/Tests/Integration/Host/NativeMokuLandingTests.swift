import AppKit
import Foundation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import MokuseiHarnessCodex
import MokuseiApplications
@testable import MokuseiUI

// Catalog fixtures still need the real connection event: loading must retire
// on disconnect, even when a retained snapshot says its execution is running.
extension RuntimeClient {
    fileprivate func connectLandingFixture() { setStatus(.connected) }
}

@MainActor private final class SearchPositionProbe {
    var bounds: [String: CGRect] = [:]
    var origin: CGPoint = .zero
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
                    harnesses: [AnyHarnessPlugin(CodexHarnessPlugin())], sidecards: [], applications: NativeApplicationModules.make()))
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
                "executions": .array([]), "applicationThreads": .array(applications)])
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
        let height = try #require(window.contentView).bounds.height
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type,
                location: CGPoint(x: point.x, y: height - point.y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        }
        // Native text selection may synchronously track until mouse-up.
        NSApp.postEvent(try event(.leftMouseUp), atStart: true)
        NSApp.sendEvent(try event(.leftMouseDown))
    }

    @Test func fullWorkspaceSearchMorphKeepsTextAndCaretCentered() async throws {
        let fixture = try Fixture()
        do {
            try await fixture.install([fixture.thread("search-fixture", status: nil)])
            let probe = SearchPositionProbe()
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1180, height: 780),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
            func content(scale: CGFloat) -> some View {
                // Match WorkspaceWindow so native view/layer geometry is also
                // checked after a real viewport resize and application zoom.
                GeometryReader { geometry in
                    NativeWorkspaceView(model: fixture.workspace, presentation: fixture.presentation)
                        .frame(width: geometry.size.width / scale, height: geometry.size.height / scale)
                        .environment(\.nativeWindowContentScale, scale)
                        .scaleEffect(scale, anchor: .topLeading)
                }
                .modifier(NativeWorkspaceWindowSurface())
                .overlayPreferenceValue(OverviewSearchTagBounds.self) { anchors in
                    GeometryReader { reader in
                        Color.clear.onChange(of: anchors.mapValues { reader[$0] }, initial: true) { _, bounds in
                            probe.bounds = bounds
                            probe.origin = reader.frame(in: .global).origin
                        }
                    }.allowsHitTesting(false)
                }
            }
            let host = NSHostingView(rootView: content(scale: 1))
            window.contentView = host
            fixture.window = window
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await SwiftUIReplay.wait { !fixture.overview.canvasState.isLayingOut && !fixture.overview.visibleFilters.isEmpty }
            let root = try #require(window.contentView)
            func mountedEditor(in view: NSView) -> NSTextView? {
                if let editor = view as? NSTextView, editor.isEditable { return editor }
                return view.subviews.lazy.compactMap { mountedEditor(in: $0) }.first
            }
            func settledSearchEditor() async throws -> NSTextView {
                // The ordinary Swift test process can leave this animation and
                // native viewport unlaid out. The native AppKit owner must drive
                // the morph and focus request; this lookup never forces focus.
                do {
                    try await SwiftUIReplay.wait {
                        guard let carrier = probe.bounds["__search_carrier__"],
                              let candidate = mountedEditor(in: root),
                              let viewport = candidate.enclosingScrollView?.contentSize else { return false }
                        return candidate.window === window && window.isKeyWindow && window.firstResponder === candidate
                            && viewport.width > 1 && viewport.height > 1
                            && abs(carrier.height - OverviewTagMetrics.buttonHeight) < 0.05
                    }
                } catch {
                    let candidate = mountedEditor(in: root)
                    print("SEARCH SETTLE running=\(NSApp.isRunning) key=\(window.isKeyWindow) focused=\(window.firstResponder === candidate) carrier=\(String(describing: probe.bounds["__search_carrier__"])) viewport=\(String(describing: candidate?.enclosingScrollView?.contentSize))")
                    throw error
                }
                return try #require(mountedEditor(in: root))
            }
            fixture.overview.beginSearch()
            let editor = try await settledSearchEditor()
            let scroll = try #require(editor.enclosingScrollView)
            let carrier = try #require(probe.bounds["__search_carrier__"]).offsetBy(dx: probe.origin.x, dy: probe.origin.y)
            func caretRect(_ candidate: NSTextView) -> NSRect {
                root.convert(window.convertFromScreen(candidate.firstRect(forCharacterRange: candidate.selectedRange(), actualRange: nil)), from: nil)
            }
            func checkCaretLayer(_ candidate: NSTextView, carrier: CGRect, scale: CGFloat = 1, stage: String) async throws {
                try await SwiftUIReplay.wait { window.isKeyWindow && window.firstResponder === candidate }
                #expect(candidate.selectedRange().length == 0, "stage=\(stage)")
                candidate.updateInsertionPointStateAndRestartTimer(true)
                candidate.needsDisplay = true
                candidate.displayIfNeeded()
                try await SwiftUIReplay.wait {
                    candidate.layer?.sublayers?.contains { $0.name == "composer-insertion-point" } == true
                }
                let layer = try #require(candidate.layer?.sublayers?.first { $0.name == "composer-insertion-point" })
                let layerRect = candidate.convert(candidate.convertFromLayer(layer.frame), to: root)
                let nativeRect = caretRect(candidate)
                try #require(nativeRect.height > 0, "stage=\(stage) native insertion rectangle is unavailable: \(nativeRect)")
                #expect(abs(layerRect.midY - carrier.midY) <= 2 * scale, "stage=\(stage)")
                // Comparing both to the capsule center alone can accept a
                // mirrored offset. The native insertion rectangle is the oracle
                // for the custom mark, including its horizontal scroll position.
                #expect(abs(layerRect.midX - nativeRect.midX) <= 0.5 * scale,
                        "stage=\(stage) layer=\(layerRect) native=\(nativeRect)")
                #expect(abs(layerRect.midY - nativeRect.midY) <= 0.5 * scale,
                        "stage=\(stage) layer=\(layerRect) native=\(nativeRect)")
            }
            func checkPosition(_ candidate: NSTextView, scale: CGFloat = 1, stage: String) async throws {
                root.layoutSubtreeIfNeeded()
                let currentCarrier = try #require(probe.bounds["__search_carrier__"])
                    .offsetBy(dx: probe.origin.x, dy: probe.origin.y)
                let currentScroll = try #require(candidate.enclosingScrollView)
                let viewport = currentScroll.contentView.convert(currentScroll.contentView.bounds, to: root)
                let nativeRect = caretRect(candidate)
                #expect(currentScroll.contentView.bounds.origin.y == 0, "stage=\(stage)")
                #expect(abs(nativeRect.midY - currentCarrier.midY) <= 2 * scale, "stage=\(stage)")
                #expect(nativeRect.midX >= viewport.minX && nativeRect.midX <= viewport.maxX,
                        "stage=\(stage) native=\(nativeRect) viewport=\(viewport)")
                try await checkCaretLayer(candidate, carrier: currentCarrier, scale: scale, stage: stage)
            }
            #expect(abs(caretRect(editor).midY - carrier.midY) <= 2)
            try await checkCaretLayer(editor, carrier: carrier, stage: "opened")
            editor.insertText("Search text", replacementRange: NSRange(location: 0, length: 0))
            try await SwiftUIReplay.wait { fixture.overview.searchQuery == "Search text" }
            #expect(abs(caretRect(editor).midY - carrier.midY) <= 2)
            let manager = try #require(editor.layoutManager)
            let container = try #require(editor.textContainer)
            manager.ensureLayout(for: container)
            let glyphs = manager.glyphRange(for: container)
            let textRect = manager.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
            let textMidY = editor.convert(textRect, to: root).midY
            print("SEARCH POSITION carrier=\(carrier) caret=\(caretRect(editor)) textMidY=\(textMidY) clip=\(scroll.contentView.bounds)")
            #expect(abs(textMidY - carrier.midY) <= 3)
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: -15))
            #expect(scroll.contentView.bounds.origin.y == 0)
            #expect(abs(caretRect(editor).midY - carrier.midY) <= 2)
            try await checkPosition(editor, stage: "typed")

            let longQuery = String(repeating: "Search 搜索 🙂 ", count: 24)
            editor.insertText(longQuery, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            try await SwiftUIReplay.wait {
                fixture.overview.searchQuery == longQuery && editor.frame.width > scroll.contentSize.width
            }
            editor.scrollRangeToVisible(editor.selectedRange())
            #expect(scroll.contentView.bounds.origin.x > 0)
            #expect(editor.selectedRange() == NSRange(location: longQuery.utf16.count, length: 0))
            try await checkPosition(editor, stage: "long query end")
            editor.moveToBeginningOfDocument(nil)
            editor.scrollRangeToVisible(editor.selectedRange())
            #expect(editor.selectedRange() == NSRange(location: 0, length: 0))
            #expect(scroll.contentView.bounds.origin.x == 0)
            try await checkPosition(editor, stage: "long query start")

            window.setContentSize(CGSize(width: 720, height: 620))
            try await SwiftUIReplay.wait {
                guard let frame = probe.bounds["__search_carrier__"] else { return false }
                return abs(host.bounds.width - 720) < 0.5 && abs(frame.midX + probe.origin.x - host.bounds.midX) < 0.5
            }
            #expect(mountedEditor(in: root) === editor)
            #expect(editor.string == longQuery && editor.selectedRange() == NSRange(location: 0, length: 0))
            try await checkPosition(editor, stage: "resized")
            for scale in [CGFloat(1.25), CGFloat(1)] {
                host.rootView = content(scale: scale)
                try await SwiftUIReplay.wait {
                    abs((probe.bounds["__search_carrier__"]?.height ?? 0) - OverviewTagMetrics.buttonHeight * scale) < 0.5
                }
                #expect(mountedEditor(in: root) === editor)
                #expect(editor.string == longQuery && editor.selectedRange() == NSRange(location: 0, length: 0))
                try await checkPosition(editor, scale: scale, stage: "zoom \(scale)")
            }

            editor.selectAll(nil)
            editor.insertText("", replacementRange: editor.selectedRange())
            try await SwiftUIReplay.wait {
                fixture.overview.searchQuery.isEmpty && editor.string.isEmpty && editor.frame.width <= scroll.contentSize.width + 0.5
            }
            #expect(editor.selectedRange() == NSRange(location: 0, length: 0))
            #expect(scroll.contentView.bounds.origin.x == 0)
            try await checkPosition(editor, stage: "cleared")
            fixture.overview.endSearch()
            try await SwiftUIReplay.wait { probe.bounds["__search_carrier__"] == nil && mountedEditor(in: root) == nil }
            fixture.overview.beginSearch()
            let reopened = try await settledSearchEditor()
            #expect(reopened.string.isEmpty && reopened.selectedRange() == NSRange(location: 0, length: 0))
            try await checkPosition(reopened, stage: "reopened")
            print("SEARCH_CARET_GEOMETRY_CONFIRMED")
        } catch { await fixture.close(); throw error }
        await fixture.close()
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

    private func faces(in view: NSView) -> [NativeMokuCharacterCanvas] {
        if let canvas = view as? NativeMokuCharacterCanvas { return canvas.seat == .face ? [canvas] : [] }
        return view.subviews.flatMap { faces(in: $0) }
    }
    private func element(id: String, in object: NSObject) -> NSObject? {
        let identifier = NSSelectorFromString("accessibilityIdentifier")
        if object.responds(to: identifier), object.perform(identifier)?.takeUnretainedValue() as? String == id { return object }
        let children = NSSelectorFromString("accessibilityChildren")
        if object.responds(to: children), let values = object.perform(children)?.takeUnretainedValue() as? [NSObject] {
            for child in values { if let found = element(id: id, in: child) { return found } }
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
