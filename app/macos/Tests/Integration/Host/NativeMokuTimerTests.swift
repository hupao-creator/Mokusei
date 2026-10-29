import AppKit
import SwiftUI
import Testing
import MokuseiTestSupport
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
@testable import MokuseiUI

@MainActor @Suite(.serializedNative)
struct NativeMokuTimerTests {
    @MainActor private final class Player: NativeMokuTimerPlaying {
        var starts = 0
        var stops = 0
        var fails = false
        var playing = false
        func startLoop() throws {
            starts += 1
            if fails { throw RuntimeError("FIXTURE_AUDIO", "Fake bell failed") }
            playing = true
        }
        func stop() { stops += 1; playing = false }
    }

    private func operation(_ id: JSONText, text: String = "Timer text", name: String = "timer",
                           execution: JSONText = "run", complete: Bool = true, ok: Bool = true) -> JSONValue {
        var item: [JSONText: JSONValue] = ["type": .text("tool-operation"), "id": .string(id),
            "executionId": .string(execution), "name": .text(name),
            "arguments": .object(["text": .text(text)]), "result": .object(["ok": .bool(ok)])]
        if complete { item["completedAt"] = .integer(2) }
        return .object(item)
    }
    private func thread(_ items: [JSONValue], id: JSONText = "moku", harness: JSONText = "fixture") throws -> HarnessThread {
        try HarnessThread(id: id, harnessID: harness, revision: 1, sessionState: .null,
            observation: .init(latestExecution: try .init(executionID: "run", status: .running, startedAt: 1)),
            cwd: "/tmp", settings: .object([:]), createdAt: 1, updatedAt: 2, title: "Moku", tags: [],
            moku: true, transcript: .array(items))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOKU_TIMER_NATIVE_FIXTURE"] != nil,
                   "Requires production Go snapshots; see MokuScene/README.md Immediate Timer"))
    func productionGoCatalogFeedsQueueWithoutRealAudio() throws {
        let path = try #require(ProcessInfo.processInfo.environment["MOKU_TIMER_NATIVE_FIXTURE"])
        let records = try #require(JSONValue.parse(data: Data(contentsOf: URL(fileURLWithPath: path))).arrayValue)
            .map { try HarnessThread(json: $0) }
        try #require(records.count == 6)
        let player = Player()
        let controller = NativeMokuTimerController(player: player)
        controller.receive(records[0])
        for record in records.dropFirst() { controller.receive(record) }
        #expect(controller.pending.map(\.text) == ["  已完成\nready 🙂  ", "  已完成\nready 🙂  "])
        #expect(player.starts == 1 && player.stops == 0)
        controller.acknowledge(id: try #require(controller.current?.id))
        controller.receive(records.last)
        #expect(controller.pending.count == 1)
        controller.acknowledge(id: try #require(controller.current?.id))
        controller.receive(records.last)
        #expect(controller.current == nil && player.stops == 1)
        controller.stop()
    }

    @Test func successfulCompletedMessagesQueueAndRepeatedSnapshotsCannotReplay() throws {
        let player = Player()
        let controller = NativeMokuTimerController(player: player)
        controller.receive(try thread([]))
        let first = operation("one"), second = operation("two") // same text, distinct operation
        controller.receive(try thread([first, second]))
        let firstID = try #require(controller.current?.id)
        #expect(controller.pending.count == 2 && player.starts == 1 && player.playing)
        controller.receive(try thread([first, second, operation("talk", name: "talk")]))
        controller.receive(nil) // disconnection/history reset cannot dismiss an accepted message
        #expect(controller.pending.count == 2 && player.starts == 1)
        controller.acknowledge(id: "wrong")
        #expect(controller.pending.count == 2)
        controller.acknowledge(id: firstID)
        #expect(controller.pending.count == 1 && player.stops == 0)
        controller.acknowledge(id: firstID) // delayed double click must not acknowledge the successor
        #expect(controller.pending.count == 1)
        controller.acknowledge(id: try #require(controller.current?.id))
        #expect(controller.current == nil && !player.playing && player.stops == 1)
        controller.receive(try thread([first, second]))
        #expect(controller.current == nil && player.starts == 1)
        controller.receive(try thread([operation("three")]))
        #expect(controller.pending.count == 1 && player.starts == 2)
        controller.stop()
    }

    @Test func startupHistoryIsSilentButPendingCallCanFinishAndReconnectCatchesVisibleOperations() throws {
        let player = Player()
        let timer = NativeMokuTimerController(player: player)
        let old = operation("old"), pending = operation("pending", complete: false)
        timer.receive(try thread([old, pending]))
        #expect(timer.current == nil && player.starts == 0)
        timer.receive(try thread([old, operation("pending")]))
        #expect(timer.pending.count == 1 && player.starts == 1)
        timer.receive(try thread([old, operation("pending"), operation("during-gap")]))
        #expect(timer.pending.count == 2 && player.starts == 1)
        // A fresh workspace treats that same completed transcript as history.
        let restartedPlayer = Player(), restarted = NativeMokuTimerController(player: restartedPlayer)
        restarted.receive(try thread([old, operation("pending"), operation("during-gap")]))
        #expect(restarted.current == nil && restartedPlayer.starts == 0)
        timer.stop(); restarted.stop()
    }

    @Test func projectionRejectsFailuresAndInvalidTextAndPreservesUnicode() throws {
        let exact = " \n" + String(repeating: "😀", count: 156) + "\t "
        let valid = operation("valid", text: exact)
        let records = try thread([valid, operation("over", text: String(repeating: "😀", count: 161)),
            operation("blank", text: " \u{FEFF}\u{0085}\n"), operation("nul", text: "a\0b"),
            operation("pending", complete: false), operation("failed", ok: false), operation("talk", name: "talk")])
        #expect(NativeMokuTimerMessage.completed(in: records).map(\.text) == [exact])
        #expect(NativeMokuTalkMessage.latest(in: records)?.text == "Timer text")
        let original = try #require(NativeMokuTimerMessage.completed(in: try thread([valid])).first)
        let replacement = try #require(NativeMokuTimerMessage.completed(in: try thread([valid], id: "new-owner")).first)
        #expect(original.id != replacement.id)
        let nextExecution = try #require(NativeMokuTimerMessage.completed(in: try thread([operation("valid", execution: "new-run")])).first)
        #expect(original.id != nextExecution.id)
    }

    @Test func releasingWorkspaceControllerStopsItsPlayer() throws {
        let player = Player()
        var timer: NativeMokuTimerController? = NativeMokuTimerController(player: player)
        timer?.receive(nil); timer?.receive(try thread([operation("one")]))
        #expect(player.playing)
        timer = nil
        #expect(!player.playing && player.stops == 1)
    }

    @Test func audioFailureKeepsAcknowledgmentAvailableAndRetriesOnlyExplicitly() throws {
        let player = Player(); player.fails = true
        let timer = NativeMokuTimerController(player: player)
        timer.receive(nil)
        let record = try thread([operation("one")])
        timer.receive(record)
        #expect(timer.current != nil && timer.audioError != nil && player.starts == 1)
        timer.receive(record)
        #expect(player.starts == 1)
        player.fails = false; timer.retryAudio()
        #expect(timer.audioError == nil && player.playing && player.starts == 2)
        timer.acknowledge(id: try #require(timer.current?.id))
        #expect(!player.playing && timer.audioError == nil)
        timer.stop(); let stops = player.stops
        timer.stop(); timer.receive(try thread([operation("late")]))
        #expect(timer.current == nil && player.stops == stops)
    }

    @Test func workspaceInstallationNavigationAndDisconnectRetainQueueWithoutChangingDraftOrVoice() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let player = Player(), timer = NativeMokuTimerController(player: player)
        let workspace = NativeWorkspaceModel(client: RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory)),
            preferences: DesktopPreferences(directory: directory),
            plugins: try .init(harnesses: [], sidecards: [], applications: []), timer: timer)
        let presentation = NativeWorkspacePresentation(workspace: workspace)
        presentation.draft.text = "unsent draft 🙂"
        presentation.scene.setInputOpen(true)
        presentation.scene.retainedSelection = NSRange(location: 3, length: 4)
        let voice = workspace.voice.moku.state.phase
        let authority = UUID()
        func install(_ items: [JSONValue], revision: Int, reconnect: Bool = false) async throws {
            let snapshot: JSONValue = .object(["revision": .integer(revision), "settingsRevision": .integer(0),
                "defaultCwd": .text(directory.path), "settings": .object([:]),
                "threads": .array([try thread(items).json]), "executions": .array([]), "applicationThreads": .array([])])
            await workspace.installPrepared(snapshot, event: .snapshot(snapshot, authority: reconnect ? UUID() : authority))
            #expect(workspace.state == snapshot)
        }
        try await install([], revision: 1)
        try await install([operation("one")], revision: 2)
        #expect(workspace.timer === timer && timer.pending.count == 1 && player.playing)
        #expect(presentation.draft.text == "unsent draft 🙂" && presentation.scene.inputOpen)
        #expect(presentation.scene.retainedSelection == NSRange(location: 3, length: 4))
        presentation.scene.overviewVisible = false
        let remounted = NativeWorkspacePresentation(workspace: workspace)
        #expect(remounted.workspace.timer === timer && timer.pending.count == 1)
        // The workspace is deliberately disconnected; acknowledgment is local.
        #expect(workspace.connection != .connected)
        try await install([operation("one"), operation("two")], revision: 3, reconnect: true)
        #expect(timer.pending.count == 2 && player.starts == 1)
        #expect(workspace.voice.moku.state.phase == voice)
        timer.acknowledge(id: try #require(timer.current?.id))
        #expect(timer.pending.count == 1)
        timer.stop()
        #expect(!player.playing && timer.pending.count == 1) // shutdown is not acknowledgment
        await workspace.client.close()
        await presentation.draft.dispose(discardRemoteAttachments: false)
        await remounted.draft.dispose(discardRemoteAttachments: false)
    }

    @Test func productionBarIsAccessibleWithoutAWindowAndDoesNotAcknowledgeOnUnmount() throws {
        let player = Player()
        let controller = NativeMokuTimerController(player: player)
        controller.receive(nil); controller.receive(try thread([operation("one", text: "明确提醒\nfull text")]))
        for (scheme, width) in [(ColorScheme.light, CGFloat(188)), (.dark, 320), (.light, 900)] {
            let host = NSHostingView(rootView: NativeMokuTimerBar(timer: controller, exclusions: .init())
                .environment(\.locale, Locale(identifier: "zh-CN"))
                .environment(\.colorScheme, scheme).frame(width: width))
            host.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            host.frame.size = CGSize(width: width, height: 200)
            host.layoutSubtreeIfNeeded()
            #expect(host.window == nil)
            let text = SwiftUIReplay.text(in: host)
            #expect(text.contains("已收到") && text.contains("明确提醒\nfull text"), "width=\(width), text=\(text), frame=\(host.frame), fitting=\(host.fittingSize)")
            #expect(controller.pending.count == 1 && player.starts == 1)
            func button(in root: NSView) -> NSButton? {
                if let button = root as? NSButton, button.identifier?.rawValue == "moku-timer-acknowledge" { return button }
                return root.subviews.lazy.compactMap { button(in: $0) }.first
            }
            let receipt = try #require(button(in: host))
            #expect(receipt.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
            #expect(host.appearance?.name == (scheme == .light ? .aqua : .darkAqua))
            if width == 900 {
                #expect(receipt.accessibilityLabel() == "已收到")
                let doubleClick = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
                    location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                    context: nil, eventNumber: 1, clickCount: 2, pressure: 1))
                receipt.mouseDown(with: doubleClick)
                #expect(controller.pending.count == 1) // a queued successor cannot be double-clicked away
                #expect(receipt.accessibilityPerformPress())
                #expect(controller.current == nil && player.stops == 1)
            }
        }
        controller.stop()
    }
}
