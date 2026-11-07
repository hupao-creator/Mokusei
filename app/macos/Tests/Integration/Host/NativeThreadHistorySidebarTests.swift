import AppKit
import Observation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI

@MainActor @Observable private final class SidebarFixture {
    var ids: [JSONText]
    var target: ThreadConversationReadingTarget?
    var longAuthor = false
    var inherited = false
    var summarizedWork = false
    var runningID: JSONText?
    let controls = NativeReadingInteractions()
    let visit = UUID()
    @ObservationIgnored var mounted: Set<JSONText> = []
    @ObservationIgnored var appearances: [JSONText: Int] = [:]
    @ObservationIgnored var requested: Set<JSONText> = []

    init(count: Int = 5) { ids = (0..<count).map { JSONText("turn-\($0)") } }
    var rows: [ThreadConversationRow] {
        (inherited ? [ThreadConversationRow(id: "inherited", createdAt: -1, history: true,
            node: AnyView(Text("Inherited transcript")))] : []) + ids.enumerated().map { index, id in
            ThreadConversationRow(id: id, createdAt: Double(index),
                execution: .init(id: id, prompt: "\(index + 1). 检查历史轮次与目录导航", answer: "已确定：保留轮次内容、选中状态与滚动位置。", completedAt: 1_700_000_000_000),
                node: AnyView(SidebarTurn(fixture: self, id: id)))
        }
    }
    func render(_ id: JSONText) -> AnyView {
        requested.insert(id)
        if id == "inherited" { return AnyView(Text("Inherited transcript")) }
        return AnyView(SidebarTurn(fixture: self, id: id))
    }
    var snapshot: [JSONValue] { controls.snapshot(visit: visit) }
    func control(_ role: String, value: JSONValue? = nil) -> JSONValue? {
        snapshot.first { $0["role"] == .text(role) && (value == nil || $0["value"] == value) }
    }
    func state(_ role: String) -> JSONValue? { control(role)?["value"] }
    func ready() async throws {
        try await SwiftUIReplay.wait {
            self.state("conversation")?["transitioning"] == .bool(false)
                && self.snapshot.allSatisfy { $0["pending"] == .bool(false) }
                && (self.state("timeline")?["viewport"]?.numberValue ?? 0) > 0
        }
    }
    func perform(_ role: String, value: JSONValue? = nil, operation: String = "activate", input: JSONValue = .null) async throws {
        try await ready()
        let descriptor = try #require(control(role, value: value))
        try controls.perform(id: #require(descriptor["id"]?.stringValue), handle: #require(descriptor["handle"]?.stringValue),
                             operation: operation, value: input, visit: visit)
        try await ready()
    }
}

private struct SidebarTurn: View {
    let fixture: SidebarFixture
    let id: JSONText
    var body: some View {
        ThreadDetailTurn(id: id, author: .object([
            "model": .text(fixture.longAuthor ? String(repeating: "long-runtime-model-", count: 12) : "Astra \(id.string)"),
            "effort": .text("xhigh")
        ]), rows: [
            .init(id: JSONText(id.string + "-user"), kind: .user, node: AnyView(Text("User prompt"))),
            .init(id: JSONText(id.string + "-work"), kind: .work, node: AnyView(Text("Execution details")),
                execution: fixture.summarizedWork ? .member : nil,
                executionSummary: fixture.summarizedWork ? .init(reasoningSegments: 4, toolCalls: 7) : nil),
            .init(id: JSONText(id.string + "-answer"), kind: .content,
                node: AnyView(Text("回答 \(id.string)\n\n" + String(repeating: "正文保持可访问，切换目录仅加载选中的轮次。\n\n", count: 30))), finalReply: true)
        ], createdAt: 1, updatedAt: 2, status: fixture.runningID == id ? "running" : "completed",
            completedAt: fixture.runningID == id ? nil : 1_700_000_000_000, active: fixture.runningID == id)
        .onAppear { fixture.mounted.insert(id); fixture.appearances[id, default: 0] += 1 }
        .onDisappear { fixture.mounted.remove(id) }
    }
}

private struct SidebarSurface: View {
    let fixture: SidebarFixture
    var executionCard = false
    var body: some View {
        ThreadConversation(threadId: "sidebar-replay", title: "检查历史轮次与目录导航", icon: "📝", rows: fixture.rows,
            readingTarget: fixture.target, running: fixture.runningID != nil, runningTurnId: fixture.runningID,
            context: .init(content: .manifest, presentation: executionCard ? .execution("turn-4") : .main(excludedExecutionIDs: []),
                contentResource: { _ in .init(state: .loading, retry: {}, release: {}) }, onIndexChange: { _ in }),
            renderRow: fixture.render)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        .environment(\.nativeReadingInteractions, fixture.controls)
        .environment(\.nativeReadingInteractionVisit, fixture.visit)
        .environment(\.nativeReadingInteractionRefresh, fixture.controls.refresh)
    }
}

@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeThreadHistorySidebarTests {
    @Test(arguments: [false, true])
    func runningExecutionKeepsWorkVisibleAcrossHistoryAndCompletion(summarized: Bool) async throws {
        let fixture = SidebarFixture()
        fixture.summarizedWork = summarized
        let window = SwiftUIReplay.window(SidebarSurface(fixture: fixture), width: 1000, height: 700, offscreen: true)
        defer { window.close() }
        try await fixture.ready()
        #expect(fixture.state("turn")?["visibleRowCount"] == .integer(1))
        fixture.runningID = "turn-4"
        try await SwiftUIReplay.wait { fixture.control("visibility.work") == nil && fixture.state("turn")?["visibleRowCount"] == .integer(2) }
        #expect(fixture.control("visibility.userMessages") == nil)
        #expect(fixture.control("execution.group") == nil)
        if summarized {
            let content = try #require(window.contentView)
            try await SwiftUIReplay.wait { SwiftUIReplay.text(in: content).contains("执行过程 · 4 段思考 · 7 次工具调用") }
            #expect(!SwiftUIReplay.text(in: content).contains("Execution details"))
        }
        try await fixture.perform("history.open", value: .text("turn-2"))
        #expect(fixture.control("visibility.work") != nil)
        #expect(fixture.state("turn")?["visibleRowCount"] == .integer(1))
        fixture.target = .init(requestId: "running-result", mode: .history, executionId: "turn-4", position: .result, follow: false)
        try await SwiftUIReplay.wait { fixture.state("history")?["rowId"] == .text("turn-4") && fixture.control("visibility.work") == nil }
        #expect(fixture.state("turn")?["visibleRowCount"] == .integer(2))
        fixture.runningID = nil
        try await SwiftUIReplay.wait { fixture.control("visibility.work") != nil && fixture.state("turn")?["visibleRowCount"] == .integer(1) }
        try await fixture.perform("visibility.work")
        #expect(fixture.state("turn")?["visibleRowCount"] == .integer(2))
        try await fixture.perform("visibility.work")
        fixture.runningID = "turn-4"
        try await SwiftUIReplay.wait { fixture.control("visibility.work") == nil && fixture.state("turn")?["visibleRowCount"] == .integer(2) }
    }

    @Test func sidebarNavigatesRetainsScrollAndMovesTheActualAuthor() async throws {
        let fixture = SidebarFixture()
        fixture.summarizedWork = true
        let window = SwiftUIReplay.window(SidebarSurface(fixture: fixture), width: 1000, height: 700, offscreen: true)
        defer { window.close() }
        try await fixture.ready()
        try await SwiftUIReplay.wait { fixture.state("turn.author")?["model"] == .text("Astra turn-4") }
        #expect(fixture.state("history.sidebar")?["selectedRow"] == .text("turn-4"))
        #expect(fixture.requested == ["turn-4"])
        try await fixture.perform("timeline", operation: "scrollTo", input: .number(220))
        try await SwiftUIReplay.wait { abs((fixture.state("timeline")?["top"]?.numberValue ?? 0) - 220) < 2 }
        try await fixture.perform("history.open", value: .text("turn-2"))
        try await SwiftUIReplay.wait { fixture.state("turn.author")?["model"] == .text("Astra turn-2") }
        #expect(fixture.state("history.sidebar")?["selectedRow"] == .text("turn-2"))
        #expect(fixture.mounted == ["turn-2", "turn-4"])
        #expect(fixture.state("timeline")?["top"] == .number(0))
        let appearances = fixture.appearances["turn-2"]
        try await fixture.perform("history.open", value: .text("turn-2"))
        #expect(fixture.appearances["turn-2"] == appearances)
        #expect(fixture.mounted == ["turn-2", "turn-4"])
        try await fixture.perform("visibility.work")
        #expect(fixture.state("turn")?["visibleRowCount"] == .integer(2))
        let summary = "执行过程 · 4 段思考 · 7 次工具调用"
        let content = try #require(window.contentView)
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: content).contains(summary) }
        #expect(!SwiftUIReplay.text(in: content).contains("Execution details"))
        #expect(fixture.control("execution.group") == nil)
        try await fixture.perform("visibility.work")
        try await SwiftUIReplay.wait { !SwiftUIReplay.text(in: content).contains(summary) }
        #expect(fixture.state("turn")?["visibleRowCount"] == .integer(1))
        try await fixture.perform("visibility.work")
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: content).contains(summary) }
        try await fixture.perform("history.close")
        try await SwiftUIReplay.wait { abs((fixture.state("timeline")?["top"]?.numberValue ?? 0) - 220) < 2 }
        #expect(fixture.state("history.sidebar")?["selectedRow"] == .text("turn-4"))
        #expect(fixture.state("turn")?["visibleRowCount"] == .integer(1))
        try await SwiftUIReplay.wait { fixture.state("history.sidebar")?["focusedRow"] == .text("turn-4") }
        try key(126, "\u{f700}", in: window)
        try await SwiftUIReplay.wait { fixture.state("history.sidebar")?["focusedRow"] == .text("turn-3") }
        try key(125, "\u{f701}", in: window)
        try await SwiftUIReplay.wait { fixture.state("history.sidebar")?["focusedRow"] == .text("turn-4") }
        try key(126, "\u{f700}", in: window)
        try await SwiftUIReplay.wait { fixture.state("history.sidebar")?["focusedRow"] == .text("turn-3") }
        try key(36, "\r", in: window)
        try await SwiftUIReplay.wait { fixture.state("conversation")?["historyRow"] == .text("turn-3") }
        // Selection publishes before the incoming page admits reading input.
        // Escape belongs to the settled history visit, not its disabled travel.
        try await fixture.ready()
        try key(53, "\u{1b}", in: window)
        do {
            try await SwiftUIReplay.wait { fixture.state("conversation")?["destination"] == .text("current") }
        } catch {
            print("Sidebar Escape diagnostics: conversation=\(String(describing: fixture.state("conversation"))) sidebar=\(String(describing: fixture.state("history.sidebar"))) responder=\(String(describing: window.firstResponder)) key=\(window.isKeyWindow) active=\(NSApp.isActive) sheet=\(window.attachedSheet != nil)")
            throw error
        }
    }

    @Test func updatesDeletionInheritedHistoryAndExternalTargetsKeepTheirIdentity() async throws {
        let fixture = SidebarFixture()
        fixture.inherited = true
        let window = SwiftUIReplay.window(SidebarSurface(fixture: fixture), width: 700, height: 640, offscreen: true)
        defer { window.close() }
        try await fixture.perform("history.open", value: .text("turn-1"))
        fixture.ids.append("successor")
        try await SwiftUIReplay.wait { fixture.state("history.sidebar")?["currentRow"] == .text("successor") }
        #expect(fixture.state("history.sidebar")?["selectedRow"] == .text("turn-1"))
        fixture.ids.removeAll { $0 == "turn-1" }
        try await SwiftUIReplay.wait { fixture.state("conversation")?["destination"] == .text("unavailable") }
        #expect(fixture.state("history.sidebar")?["selectedRow"] == .null)
        try await fixture.perform("history.open", value: .text("inherited"))
        #expect(fixture.state("conversation")?["historyRow"] == .text("inherited"))
        fixture.target = .init(requestId: "result", mode: .history, executionId: "turn-2", position: .result)
        try await SwiftUIReplay.wait { fixture.state("timeline")?["locatedRequestId"] == .text("result") }
        #expect(fixture.state("history.sidebar")?["selectedRow"] == .text("turn-2"))
        try await fixture.perform("history.current", value: .text("successor"))
        fixture.ids.append("next")
        try await SwiftUIReplay.wait { fixture.state("history.sidebar")?["selectedRow"] == .text("next") }
        #expect(fixture.state("conversation")?["destination"] == .text("current"))
    }

    @Test func authorAndFiltersRemainAccessibleInNarrowAndWideWindows() async throws {
        let cases: [(CGFloat, ColorScheme)] = [(360, .dark), (640, .dark), (1180, .dark), (1180, .light)]
        for (width, scheme) in cases {
            let fixture = SidebarFixture()
            fixture.longAuthor = width != 1180
            let window = SwiftUIReplay.window(SidebarSurface(fixture: fixture).preferredColorScheme(scheme), width: width, height: 700, offscreen: true)
            defer { window.close() }
            try await fixture.ready()
            let root = try #require(window.contentView)
            try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains { $0.hasPrefix("Author:") } }
            #expect(SwiftUIReplay.text(in: root).contains("检查历史轮次与目录导航"))
            #expect(fixture.control("visibility.work")?["enabled"] == .bool(true))
            #expect(fixture.control("visibility.userMessages") == nil)
            if fixture.longAuthor {
                #expect(SwiftUIReplay.text(in: root).contains { $0.contains(String(repeating: "long-runtime-model-", count: 12)) })
            }
            try await fixture.perform("visibility.work")
            #expect(fixture.state("turn")?["visibleRowCount"] == .integer(2))
            try await fixture.perform("history.open", value: .text("turn-2"))
            try await fixture.perform("history.close")
            try await SwiftUIReplay.wait { fixture.state("history.sidebar")?["focusedRow"] == .text("turn-4") }
            if let path = ProcessInfo.processInfo.environment["MOKUSEI_SIDEBAR_ARTIFACTS"] {
                // Capture after the mark's 120ms selection transition and the
                // asynchronous summary have settled, rather than an entrance frame.
                try await Task.sleep(for: .milliseconds(200))
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let image = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                root.cacheDisplay(in: root.bounds, to: image)
                try #require(image.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("sidebar-\(Int(width))-\(scheme == .dark ? "dark" : "light").png"))
            }
            window.close()

            let execution = SidebarFixture()
            execution.longAuthor = width != 1180
            let card = SwiftUIReplay.window(SidebarSurface(fixture: execution, executionCard: true)
                .preferredColorScheme(scheme), width: width, height: 700, offscreen: true)
            defer { card.close() }
            try await execution.ready()
            let cardRoot = try #require(card.contentView)
            try await SwiftUIReplay.wait { SwiftUIReplay.text(in: cardRoot).contains { $0.hasPrefix("Author:") } }
            let text = SwiftUIReplay.text(in: cardRoot)
            #expect(!text.contains("检查历史轮次与目录导航"))
            #expect(!text.contains("📝"))
            #expect(!text.contains("User prompt"))
            #expect(text.contains("Execution details"))
            #expect(execution.state("turn")?["visibleRowCount"] == .integer(2))
            #expect(execution.control("visibility.work") == nil)
            #expect(execution.control("visibility.userMessages") == nil)
            #expect(execution.state("turn.author")?["model"] == .text(execution.longAuthor
                ? String(repeating: "long-runtime-model-", count: 12) : "Astra turn-4"))
            if let path = ProcessInfo.processInfo.environment["MOKUSEI_SIDEBAR_ARTIFACTS"] {
                let image = try #require(cardRoot.bitmapImageRepForCachingDisplay(in: cardRoot.bounds))
                cardRoot.cacheDisplay(in: cardRoot.bounds, to: image)
                try #require(image.representation(using: .png, properties: [:])).write(to:
                    URL(fileURLWithPath: path).appendingPathComponent("execution-\(Int(width))-\(scheme == .dark ? "dark" : "light").png"))
            }
            card.close()
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOKUSEI_READING_PRESENTATION_NATIVE_REPLAY"] == "1",
        "Requires the isolated AppKit event loop for native pointer tracking: python3 tools/verification/reading-presentation/run.py --thread-sidebar"))
    func pointerPreviewHandsOffAndDismissesWithoutLosingKeyboardNavigation() async throws {
        let fixture = SidebarFixture()
        let window = SwiftUIReplay.window(SidebarSurface(fixture: fixture), width: 1000, height: 700)
        defer { window.close() }
        window.level = .floating
        window.center()
        try await SwiftUIReplay.wait { NSApp.isRunning && NSApp.isActive && window.isKeyWindow && window.occlusionState.contains(.visible) }
        let originalPointer = NSEvent.mouseLocation
        defer {
            CGWarpMouseCursorPosition(CGPoint(x: originalPointer.x,
                y: (NSScreen.screens.first?.frame.maxY ?? 0) - originalPointer.y))
        }
        window.acceptsMouseMovedEvents = true
        try await fixture.ready()
        // SwiftUI consults the system pointer as well as tracking events.
        // Keep both in sync; no callback writes production hover state.
        func move(_ x: CGFloat, _ y: CGFloat) throws {
            let event = try #require(NSEvent.mouseEvent(with: .mouseMoved,
                location: CGPoint(x: x, y: y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            let screen = window.convertPoint(toScreen: CGPoint(x: x, y: y))
            CGWarpMouseCursorPosition(CGPoint(x: screen.x,
                y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y))
            window.sendEvent(event)
            window.contentView?.mouseMoved(with: event)
        }
        try await fixture.perform("history.open", value: .text("turn-2"))
        try await fixture.perform("history.close")
        #expect(fixture.state("history.sidebar")?["previewRow"] == .null)
        try key(126, "\u{f700}", in: window)
        try await SwiftUIReplay.wait { fixture.state("history.sidebar")?["previewRow"] == .text("turn-3") }
        try move(26, 398)
        do {
            try await SwiftUIReplay.wait { fixture.state("history.sidebar")?["previewRow"] == .text("turn-0") }
        } catch {
            try capture(window, name: "hover-entry-failure")
            print("TOC HOVER", "running", NSApp.isRunning, "active", NSApp.isActive,
                "key", window.isKeyWindow, "visible", window.occlusionState.contains(.visible),
                "pointer", NSEvent.mouseLocation, "window", window.frame,
                "preview", fixture.state("history.sidebar")?["previewRow"]?.stringValue as Any)
            throw error
        }
        try move(50, 398)
        try move(120, 398)
        try await Task.sleep(for: .milliseconds(180))
        #expect(fixture.state("history.sidebar")?["previewRow"] == .text("turn-0"))
        try capture(window, name: "hover-panel")
        try move(700, 398)
        try await SwiftUIReplay.wait { fixture.state("history.sidebar")?["previewRow"] == .null }
        try capture(window, name: "hover-dismissed")
        for _ in 0..<4 {
            try move(26, 398)
            try await Task.sleep(for: .milliseconds(20))
            try move(26, 374)
            try await Task.sleep(for: .milliseconds(20))
            try move(120, 374)
        }
        try await Task.sleep(for: .milliseconds(180))
        #expect(fixture.state("history.sidebar")?["previewRow"] == .text("turn-1"))
        try move(700, 374)
        try await SwiftUIReplay.wait { fixture.state("history.sidebar")?["previewRow"] == .null }
        #expect(fixture.requested == ["turn-2", "turn-4"])
        // Synthetic arrow and Return events otherwise run in one AppKit
        // dispatch, before SwiftUI publishes the new focused row. Acknowledge
        // focus without waiting for the page animation to finish.
        for _ in 0..<4 {
            try key(126, "\u{f700}", in: window)
            try await SwiftUIReplay.wait { fixture.state("history.sidebar")?["focusedRow"] == .text("turn-2") }
            try key(36, "\r", in: window)
            try await Task.sleep(for: .milliseconds(30))
            try key(125, "\u{f701}", in: window)
            try await SwiftUIReplay.wait { fixture.state("history.sidebar")?["focusedRow"] == .text("turn-3") }
            try key(36, "\r", in: window)
            try await Task.sleep(for: .milliseconds(30))
        }
        try await fixture.ready()
        #expect(fixture.state("conversation")?["historyRow"] == .text("turn-3"))
        try key(119, "\u{f72b}", in: window)
        try key(36, "\r", in: window)
        try await fixture.ready()
        #expect(fixture.state("conversation")?["destination"] == .text("current"))
    }

    private func capture(_ window: NSWindow, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["MOKUSEI_SIDEBAR_ARTIFACTS"] else { return }
        let root = try #require(window.contentView)
        let image = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: image)
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(image.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }

    private func key(_ code: UInt16, _ characters: String, in window: NSWindow) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code))
            // Reading Escape arbitration uses the application's current event/window.
            NSApp.sendEvent(event)
        }
    }
}
