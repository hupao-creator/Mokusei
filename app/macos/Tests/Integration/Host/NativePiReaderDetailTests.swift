import AppKit
import MokuseiCore
import MokuseiPluginAPI
@testable import MokuseiHarnessPi
@testable import MokuseiPluginUI
import SwiftUI
import Testing

@MainActor
@Suite(.serializedNative, .serialized)
struct NativePiReaderDetailTests {
    @Test func fullReaderLeasesGoThinkingIdentityAndBody() async throws {
        let execution = "pi-execution"
        let messageID = "foo"
        let thinkingID = "\u{0}pi:thinking:foo"
        let state = JSONValue.object([
            "version": .integer(1),
            "messages": .array([
                .object(["id": .text("foo"), "executionId": .text(execution),
                    "role": .text("assistant"), "text": .text("answer"), "status": .text("complete")])
            ]),
            "executions": .array([
                .object(["executionId": .text(execution), "status": .text("running"), "startedAt": .number(1)])
            ]),
            "latestExecutionId": .text(execution)
        ])
        // The live turn keeps the reader work filter visible. The envelope shape
        // matches the settled-turn projection that produces these presence-only
        // thinking rows in production.
        let deferred = JSONValue.object([
            "kind": .text("deferred-execution"),
            "state": state,
            "nonempty": .array([.object(["id": .text(messageID), "field": .text("thinking")])])
        ])
        var detailSelections: [HarnessDetailSelection] = []
        var bodyReferences: [HarnessDetailBodyReference] = []
        let context = HarnessRenderContext(
            content: .manifest,
            presentation: .main(excludedExecutionIDs: []),
            contentResource: { scope in
                switch scope {
                case .row, .reading:
                    return HarnessContentResource(state: .ready(deferred), retry: {}, release: {})
                case .detail(let selection):
                    detailSelections.append(selection)
                    let items = selection.items.map { item in
                        JSONValue.object(["id": .string(item), "kind": .text("reasoning"),
                            "status": .text("complete"), "bodies": .array([.object([
                                "slot": .text("thinking"), "format": .text("markdown"), "length": .integer(9)])])])
                    }
                    return HarnessContentResource(state: .ready(.object([
                        "kind": .text("detail"), "executionId": .string(selection.execution),
                        "contentId": .text("pi-content"), "items": .array(items)])), retry: {}, release: {})
                case .body(let reference):
                    bodyReferences.append(reference)
                    return HarnessContentResource(state: .ready(.object([
                        "kind": .text("body"), "executionId": .string(reference.execution),
                        "itemId": .string(reference.item), "slot": .string(reference.slot),
                        "version": .text("v1"), "offset": .integer(0), "length": .integer(9),
                        "text": .text("reasoning")])), retry: {}, release: {})
                default:
                    return HarnessContentResource(state: .ready(.null), retry: {}, release: {})
                }
            },
            onIndexChange: { _ in })
        let thread = try HarnessThread(id: "thread", harnessID: "pi", revision: 1, sessionState: state,
            observation: .init(latestExecution: try .init(executionID: JSONText(execution), status: .running, startedAt: 1)),
            cwd: "/fixture", settings: .object([:]), createdAt: 1, updatedAt: 2, title: "Pi detail", tags: [], archived: true, mokuHistory: true)
        let actions = HarnessThreadActions(interrupt: {}, respond: { _ in }, invokeHarnessExtension: { _, _ in .null },
            forkThread: { _ in "unused" }, openExternal: { _ in }, openFollowUp: { _ in })
        let controls = NativeReadingInteractions()
        let visit = UUID()
        let root = AnyView(PiHarnessPlugin().threadView(input: .init(thread: thread), actions: actions, context: context))
            .environment(\.threadAgentDetail, false)
            .environment(\.nativeReadingInteractions, controls)
            .environment(\.nativeReadingInteractionVisit, visit)
        let host = NSHostingView(rootView: root.frame(width: 640, height: 480))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        func activate(role: String) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < deadline {
                if let control = controls.snapshot(visit: visit).first(where: { $0["role"] == .text(role) }),
                   let id = control["id"]?.stringValue, let handle = control["handle"]?.stringValue {
                    do {
                        try controls.perform(id: id, handle: handle, operation: "activate", value: .null, visit: visit)
                        return
                    } catch { }
                }
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("Missing reading control \(role)")
        }
        try await SwiftUIReplay.wait {
            host.layoutSubtreeIfNeeded()
            return !detailSelections.isEmpty
        }
        #expect(detailSelections.first?.execution.string == execution)
        #expect(detailSelections.first?.items.map(\.string) == [thinkingID])
        try await activate(role: "disclosure")
        try await SwiftUIReplay.wait {
            host.layoutSubtreeIfNeeded()
            return !bodyReferences.isEmpty && SwiftUIReplay.text(in: host).contains("reasoning")
        }
        #expect(bodyReferences.first?.execution.string == execution)
        #expect(bodyReferences.first?.item.string == thinkingID)
        #expect(bodyReferences.first?.slot.string == "thinking")
    }

    @Test func detailIdentityMatchesGoNamespaces() {
        #expect(PiDetailIdentity.thinking("foo").string == "\u{0}pi:thinking:foo")
        #expect(PiDetailIdentity.message("foo").string == "foo")
        #expect(PiDetailIdentity.executionError.string == "\u{0}pi:execution-error")
        let boundary = String(repeating: "a", count: RuntimeProtocol.maximumContentIdentityUnits - "\u{0}pi:thinking:".utf16.count)
        #expect(PiDetailIdentity.thinking(JSONText(boundary)).string == "\u{0}pi:thinking:" + boundary)
        let overlong = boundary + "a"
        let identity = PiDetailIdentity.thinking(JSONText(overlong)).string
        #expect(identity.hasPrefix("\u{0}pi:thinking:"))
        #expect(identity.utf16.count <= RuntimeProtocol.maximumContentIdentityUnits)
        #expect(identity != "\u{0}pi:thinking:" + overlong)
        let message = PiDetailIdentity.message(JSONText(String(repeating: "m", count: RuntimeProtocol.maximumContentIdentityUnits + 1))).string
        #expect(message.hasPrefix("\u{0}pi:message:"))
        #expect(message.utf16.count <= RuntimeProtocol.maximumContentIdentityUnits)
        #expect(PiReader.validUnicode("foo"))
        #expect(PiReader.validUnicode(JSONText(codeUnits: [0xD83D, 0xDE00])))
        #expect(!PiReader.validUnicode(JSONText(codeUnits: [0xD800])))
        #expect(!PiReader.validUnicode(JSONText(codeUnits: [0xDC00])))
        let invalidMessage = JSONValue.object(["id": .string(JSONText(codeUnits: [0xD800])),
            "executionId": .text("execution"), "role": .text("assistant"), "text": .text("answer")])
        #expect(throws: PluginContractError.self) { try PiMessage(invalidMessage) }
    }
}
