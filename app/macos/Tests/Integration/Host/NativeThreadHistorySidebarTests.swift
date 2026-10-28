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
    let controls = NativeReadingInteractions()
    let visit = UUID()
    @ObservationIgnored var mounted: Set<JSONText> = []
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
            .init(id: JSONText(id.string + "-work"), kind: .work, node: AnyView(Text("Execution details"))),
            .init(id: JSONText(id.string + "-answer"), kind: .content,
                node: AnyView(Text("回答 \(id.string)\n\n" + String(repeating: "正文保持可访问，切换目录仅加载选中的轮次。\n\n", count: 30))), finalReply: true)
        ], createdAt: 1, updatedAt: 2, status: "completed", completedAt: 1_700_000_000_000, active: false)
        .onAppear { fixture.mounted.insert(id) }
        .onDisappear { fixture.mounted.remove(id) }
    }
}

private struct SidebarSurface: View {
    let fixture: SidebarFixture
    var body: some View {
        ThreadConversation(threadId: "sidebar-replay", title: "检查历史轮次与目录导航", icon: "📝", rows: fixture.rows,
            readingTarget: fixture.target,
            context: .init(content: .manifest, presentation: .main(excludedExecutionIDs: []),
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
    @Test func sidebarNavigatesRetainsScrollAndMovesTheActualAuthor() async throws {
        let fixture = SidebarFixture()
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
        try await fixture.perform("visibility.work")
        try await fixture.perform("visibility.userMessages")
        #expect(fixture.state("turn")?["visibleRowCount"] == .integer(3))
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
        try key(53, "\u{1b}", in: window)
        try await SwiftUIReplay.wait { fixture.state("conversation")?["destination"] == .text("current") }
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

    @Test func longConversationKeepsBodyDemandBoundedAndCanLocateAnOldTurn() async throws {
        let fixture = SidebarFixture(count: 2500)
        let window = SwiftUIReplay.window(SidebarSurface(fixture: fixture), width: 780, height: 640, offscreen: true)
        defer { window.close() }
        try await fixture.ready()
        #expect(fixture.state("history.sidebar")?["rowCount"] == .integer(2500))
        #expect(fixture.requested == ["turn-2499"])
        #expect(fixture.state("timeline")?["rowCount"] == .integer(1))
        #expect(fixture.snapshot.filter { $0["role"] == .text("history.open") }.count < 100)
        fixture.target = .init(requestId: "old", mode: .history, executionId: "turn-3", anchorId: "turn-3")
        do {
            try await SwiftUIReplay.wait { fixture.state("timeline")?["locatedRequestId"] == .text("old") }
        } catch {
            print("SIDEBAR LOCATION", fixture.state("conversation")?["destination"]?.stringValue ?? "missing",
                  fixture.state("conversation")?["transitioning"] as Any,
                  fixture.state("timeline")?["locatedRequestId"]?.stringValue ?? "missing",
                  fixture.requested.map(\.string).sorted())
            throw error
        }
        #expect(fixture.requested == ["turn-2499", "turn-3"])
        #expect(fixture.state("history.sidebar")?["selectedRow"] == .text("turn-3"))
        try await SwiftUIReplay.wait { fixture.control("history.open", value: .text("turn-3")) != nil }
        try await fixture.perform("history.close")
        try await SwiftUIReplay.wait { fixture.state("history.sidebar")?["focusedRow"] == .text("turn-2499") }
        try key(115, "\u{f729}", in: window)
        try await SwiftUIReplay.wait { fixture.control("history.open", value: .text("turn-0")) != nil }
        try await SwiftUIReplay.wait { fixture.state("history.sidebar")?["focusedRow"] == .text("turn-0") }
        try key(36, "\r", in: window)
        try await SwiftUIReplay.wait { fixture.state("conversation")?["historyRow"] == .text("turn-0") }
        try key(119, "\u{f72b}", in: window)
        try await SwiftUIReplay.wait { fixture.state("history.sidebar")?["focusedRow"] == .text("turn-2499") }
        try key(49, " ", in: window)
        try await SwiftUIReplay.wait { fixture.state("conversation")?["destination"] == .text("current") }
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
            #expect(fixture.control("visibility.work")?["enabled"] == .bool(true))
            #expect(fixture.control("visibility.userMessages")?["enabled"] == .bool(true))
            if fixture.longAuthor {
                #expect(SwiftUIReplay.text(in: root).contains { $0.contains(String(repeating: "long-runtime-model-", count: 12)) })
            }
            try await fixture.perform("visibility.userMessages")
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
        }
    }

    private func key(_ code: UInt16, _ characters: String, in window: NSWindow) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code))
            window.sendEvent(event)
        }
    }
}
