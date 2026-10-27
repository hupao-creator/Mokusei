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
@testable import MokuseiUI
import MokuseiSidecardConversation

private struct ScrollMarker: NSViewRepresentable {
    let id: String
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityIdentifier(id)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

private struct ReadingFixture: View {
    let id: String
    var nested = false
    var body: some View {
        HarnessMessageTimeline(timelineKey: JSONText(id), rows: [
            ThreadTimelineRow(id: JSONText(id), createdAt: 1, node: AnyView(
                VStack {
                    if nested { ReadingFixture(id: "nested").frame(height: 220) }
                    Text(id).frame(height: 1500)
                }.background(ScrollMarker(id: id))
            ))
        ], showOlderRows: false)
    }
}

@MainActor @Observable
private final class CardFixturePresentation {}

private struct NavigationSidecardFixture: SidecardPlugin {
    let descriptor = SidecardPluginDescriptor(id: "reading", displayName: "Reading")
    var icon: some View { Text("R") }
    func makePresentation(context: SidecardContext, lifetime: PluginLifetime) -> CardFixturePresentation {
        _ = context.open()
        return CardFixturePresentation()
    }
    func sidecard(context: SidecardContext, presentation: CardFixturePresentation) throws -> SidecardView<ReadingFixture> {
        try SidecardView(available: true, label: "Reading", preferredWidth: 0.4, focusContentOnOpen: false) {
            ReadingFixture(id: "sidecard", nested: true)
        }
    }
}

private struct ConversationDraftReplayPlugin: SidecardPlugin {
    let capture: (ConversationSidecardPresentation) -> Void
    private let plugin = NativeConversationSidecard()
    var descriptor: SidecardPluginDescriptor { plugin.descriptor }
    var icon: some View { plugin.icon }
    func makePresentation(context: SidecardContext, lifetime: PluginLifetime) -> ConversationSidecardPresentation {
        let presentation = plugin.makePresentation(context: context, lifetime: lifetime)
        capture(presentation); return presentation
    }
    func updatePresentation(_ presentation: ConversationSidecardPresentation, context: SidecardContext) {
        plugin.updatePresentation(presentation, context: context)
    }
    func sidecard(context: SidecardContext, presentation: ConversationSidecardPresentation) throws -> SidecardView<ConversationExecutionPane> {
        try plugin.sidecard(context: context, presentation: presentation)
    }
}

/// Exercise the real Sidecard plugin host and native timelines/chrome together.
/// The separate main timeline supplies a reading body without a runtime server;
/// the workspace's unused Harness is intentionally absent from its registry.
@MainActor
@Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeSidecardNavigationTests {
    private func marker(_ id: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        return view.subviews.lazy.compactMap { marker(id, in: $0) }.first
    }

    private func backButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.toolTip == "Back" { return button }
        return view.subviews.lazy.compactMap { backButton(in: $0) }.first
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<35 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test(arguments: [CGFloat(620), 1180])
    func sidecardAndNestedScrollCannotTakeOverWindowNavigation(width: CGFloat) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory))
        let thread = try HarnessThread(id: "fixture", harnessID: "unused", revision: 0,
            sessionState: .object([:]), observation: .init(), cwd: "/tmp", settings: .object([:]),
            createdAt: 1, updatedAt: 1, title: "Fixture", tags: [])
        let host = NativeHarnessHost(client: client, registry: try HarnessPluginRegistry([]), currentThread: { _ in thread },
            callbacks: .init(openExternal: { _ in }, openFollowUp: { _, _ in }, onError: { _ in }))
        let reading = NativeReadingNavigationState()
        let workspace = NativeAgentThreadWorkspace(harnessHost: host, thread: thread,
            registry: try SidecardPluginRegistry([AnySidecardPlugin(NavigationSidecardFixture())]),
            services: .init(send: { _, _ in throw CancellationError() }, stageAttachments: { _ in [] },
                discardAttachments: { _ in }, openExternal: { _ in }), onBack: {})
        let content = HStack {
            ReadingFixture(id: "main").frame(width: 180)
            workspace
        }
        .environment(\.nativeReadingNavigation, reading)
        .overlay {
            NativeWindowNavigationView(action: .init(label: "Back", onBack: {}), reading: reading)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width + 180, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        // Keep the test window offscreen: no focus or pointer changes in the user's app.
        // It still receives real AppKit layout, scroll geometry and chrome updates.
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        defer { window.close() }
        try await settle(window)
        try await Task.sleep(for: .milliseconds(450))
        window.makeFirstResponder(nil)
        let root = try #require(window.contentView)
        let main = try #require(marker("main", in: root)?.enclosingScrollView)
        let card = try #require(marker("sidecard", in: root)?.enclosingScrollView)
        let nested = try #require(marker("nested", in: root)?.enclosingScrollView)
        #expect(main !== card && card !== nested)
        func scroll(_ scroll: NSScrollView, to y: CGFloat) async throws {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle(window)
            #expect(abs(scroll.contentView.bounds.minY - y) < 1)
        }
        try await scroll(main, to: 0)
        let source = try #require(reading.viewport?.source)
        let buttons = try [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map {
            try #require(window.standardWindowButton($0))
        }
        func expectNavigation(_ position: NativeReadingNavigationState.Viewport.Position, hidden: Bool) {
            #expect(reading.viewport?.source == source)
            #expect(reading.viewport?.position == position)
            #expect(buttons.allSatisfy { !$0.isHidden }) // SwiftUI leaves system window controls visible.
        }
        expectNavigation(.withinShowThreshold, hidden: false)
        for scrollView in [card, nested] {
            try await scroll(scrollView, to: 180)
            expectNavigation(.withinShowThreshold, hidden: false)
        }
        try await scroll(main, to: 180)
        expectNavigation(.beyondHideThreshold, hidden: true)
        // A sidecard returning to its top must not reveal chrome hidden by main.
        for scrollView in [card, nested] {
            try await scroll(scrollView, to: 0)
            expectNavigation(.beyondHideThreshold, hidden: true)
        }
        try await scroll(main, to: 60)
        expectNavigation(.betweenThresholds, hidden: true)
        try await scroll(main, to: 20)
        expectNavigation(.withinShowThreshold, hidden: false)
        try await scroll(main, to: 60)
        expectNavigation(.betweenThresholds, hidden: false)
        await host.releaseAll()
    }

    @Test(arguments: ["none", "new", "same"])
    func conversationConsumesOnlyTheAcceptedDraftAfterReopening(edit: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-receipt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstDirectory = root.appendingPathComponent("host-a"), otherDirectory = root.appendingPathComponent("host-b")
        let scope: JSONText = "conversation:conversation-replay"
        let store = NativeComposerDraftPersistence(storageDirectory: firstDirectory, scope: scope)
        let otherStore = NativeComposerDraftPersistence(storageDirectory: otherDirectory, scope: scope)
        let raw = JSONText(codeUnits: Array("原始草稿 ".utf16) + [0xd800])
        _ = try store.saveText(raw)
        _ = try otherStore.saveText("另一台主机的草稿")
        var receipt: CheckedContinuation<SidecardSendReceipt, Never>?
        var sent: [JSONValue] = []
        let thread = try HarnessThread(id: "conversation-replay", harnessID: "fixture", revision: 0, sessionState: .null,
            observation: .init(), cwd: "/host/project", settings: .object([:]), createdAt: 0, updatedAt: 0, title: "Conversation", tags: [])
        let client = RuntimeClient(profile: try RuntimeProfile(dataDirectory: firstDirectory))
        let host = NativeHarnessHost(client: client, registry: try HarnessPluginRegistry([]), currentThread: { _ in thread },
            callbacks: .init(openExternal: { _ in }, openFollowUp: { _, _ in }, onError: { _ in }))
        let configuration = NativeSidecardWorkspaceConfiguration(input: .init(thread: thread), executionDisabled: false,
            suppressed: false, enabledIDs: nil, followUpRequest: nil, locale: Locale(identifier: "en-US"))
        let services = NativeSidecardWorkspaceServices(send: { _, input in
                sent.append(input)
                return await withCheckedContinuation { receipt = $0 }
            }, stageAttachments: { _ in [] }, discardAttachments: { _ in }, openExternal: { _ in })
        func open() throws -> (NativeSidecardWorkspaceModel, ConversationSidecardPresentation) {
            var captured: ConversationSidecardPresentation?
            let registry = try SidecardPluginRegistry([AnySidecardPlugin(ConversationDraftReplayPlugin { captured = $0 })])
            let model = NativeSidecardWorkspaceModel(harnessHost: host, registry: registry, configuration: configuration,
                services: services, onBack: {}, onVisibilityChange: { _ in })
            model.update(configuration: configuration, services: services, onBack: {}, onVisibilityChange: { _ in })
            model.activate("conversation")
            return (model, try #require(captured))
        }
        let (originalModel, original) = try open()
        let sending = Task { await original.send() }
        try await SwiftUIReplay.wait { receipt != nil }
        #expect(sent.first?["parts"]?.arrayValue?.first?["text"] == .string(raw))
        originalModel.release()

        let (reopenedModel, reopened) = try open()
        defer { reopenedModel.release() }
        if edit == "new" { reopened.changeDraft("新编辑的草稿") }
        if edit == "same" { reopened.changeDraft(raw.string) }
        let window = SwiftUIReplay.window(ConversationExecutionPane(presentation: reopened), width: 420, height: 400)
        defer { window.close() }
        receipt?.resume(returning: .init(executionID: "accepted")); receipt = nil
        await sending.value

        let expected: JSONText = edit == "none" ? "" : edit == "new" ? "新编辑的草稿" : JSONText(raw.string)
        #expect(reopened.draft == expected.string)
        #expect(try store.loadText()?.textValue == expected)
        #expect(try otherStore.loadText()?.textValue == "另一台主机的草稿")
        #expect(sent.count == 1)
        let content = try #require(window.contentView)
        try await SwiftUIReplay.wait { SwiftUIReplay.editor(in: content)?.string == expected.string }
        #expect(SwiftUIReplay.editor(in: content)?.isEditable == true)
    }
}
