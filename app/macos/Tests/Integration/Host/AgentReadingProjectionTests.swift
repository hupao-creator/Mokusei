import AppKit
import Foundation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
import MokuseiPluginAPI
@testable import MokuseiPluginUI
@testable import MokuseiHarnessClaude
@testable import MokuseiHarnessCodex
@testable import MokuseiHarnessOpenCode
@testable import MokuseiHarnessPi

/// Replays real Go Harness projections through the production Agent readers.
/// The fixture path is supplied by tools/verification/agent-reading; absence
/// keeps ordinary suites independent of an external Go process.
@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized)
struct AgentReadingProjectionTests {
    @MainActor private final class ScopeLog {
        var scopes: [HarnessContentScope] = []
        var state: JSONValue = .null
        var row: JSONValue = .null
        func resource(_ scope: HarnessContentScope) -> HarnessContentResource {
            scopes.append(scope)
            switch scope {
            case .execution:
                return HarnessContentResource(state: .loading, retry: {}, release: {})
            case .thread:
                return HarnessContentResource(state: .ready(state), retry: {}, release: {})
            case .row, .reading:
                return HarnessContentResource(state: .ready(row), retry: {}, release: {})
            }
        }
    }

    private struct Entry {
        let harness: String
        let state: JSONValue
        let row: JSONValue
        let target: HarnessReadingTarget
        let anchor: JSONText
        let thread: HarnessThread
        let behavior: HarnessThreadActions
        let log: ScopeLog
    }

    private func plugin(_ harness: String) -> AnyHarnessPlugin {
        switch harness {
        case "codex": return AnyHarnessPlugin(CodexHarnessPlugin())
        case "claude": return AnyHarnessPlugin(ClaudeHarnessPlugin())
        case "pi": return AnyHarnessPlugin(PiHarnessPlugin())
        default: return AnyHarnessPlugin(OpenCodeHarnessPlugin())
        }
    }

    private func entry(_ harness: String) throws -> Entry? {
        guard let path = ProcessInfo.processInfo.environment["MOKUSEI_AGENT_READING_FIXTURES"] else { return nil }
        let root = try JSONValue(data: Data(contentsOf: URL(fileURLWithPath: path)))
        guard let fixture = (root.arrayValue ?? []).first(where: { $0["harness"] == .text(harness) }) else { return nil }
        let state = try #require(fixture["state"])
        let row = try #require(fixture["row"])
        let targetValue = try #require(fixture["target"])
        let execution = try PublicExecution(json: try #require(fixture["execution"]))
        let thread = try HarnessThread(id: JSONText("ordinary-\(harness)"), harnessID: JSONText(harness), revision: 1,
            sessionState: state, observation: .init(latestExecution: execution), cwd: "/tmp",
            settings: .object([:]), createdAt: 1, updatedAt: 40,
            title: JSONText("Agent reading \(harness)"), tags: [])
        let target = HarnessReadingTarget(executionID: "target", requestID: "request",
            mode: .current, message: targetValue)
        let actions = HarnessThreadActions(interrupt: {}, respond: { _ in },
            invokeHarnessExtension: { _, _ in .null }, forkThread: { _ in "unused" },
            openExternal: { _ in }, openFollowUp: { _ in })
        let log = ScopeLog()
        log.state = state
        log.row = row
        return Entry(harness: harness, state: state, row: row, target: target,
            anchor: try JSONText(#require(fixture["anchor"]?.stringValue)), thread: thread, behavior: actions, log: log)
    }


    @Test func nativeDecodeCostForReadingWire() throws {
        guard let path = ProcessInfo.processInfo.environment["MOKUSEI_AGENT_READING_FIXTURES"] else { return }
        let root = try JSONValue(data: Data(contentsOf: URL(fileURLWithPath: path)))
        for fixture in root.arrayValue ?? [] {
            let harness = try #require(fixture["harness"]?.stringValue)
            let wire = try #require(fixture["row"])
            let state = try #require(wire["state"])
            let started = ContinuousClock.now
            switch harness {
            case "codex": _ = try CodexState(state, createdAt: 1)
            case "claude": _ = try ClaudeState(state)
            case "pi": _ = try PiState(state)
            default: _ = try OpenCodeState(state)
            }
            if harness == "opencode" {
                let bounded = try #require(fixture["boundedRow"])
                let bytes = try bounded.encodedData().count
                #expect(bytes <= 24 * 1024 * 1024)
                #expect(bounded["kind"] == .text("deferred-execution"))
                let projected = try #require(bounded["state"])
                #expect(projected["contentTruncated"] == .bool(true))
                _ = try OpenCodeState(projected)
                let reply = try #require(projected["messages"]?.arrayValue?.first { $0["id"] == .text("large-reply") })
                #expect(reply["parts"]?.arrayValue?.first?["text"]?.stringValue?.contains("Truncated for transport") == true)
                print("AGENT_READING_BOUNDED_DECODE inputBytes=34603008 wireBytes=\(bytes)")
            }
            let elapsed = started.duration(to: .now)
            let milliseconds = Double(elapsed.components.seconds) * 1_000
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
            print("AGENT_READING_DECODE harness=\(harness) wireBytes=\(fixture["wireBytes"]?.intValue ?? 0) decodeMilliseconds=\(String(format: "%.2f", milliseconds))")
        }
    }

    @Test(arguments: ["codex", "claude", "pi", "opencode"])
    func productionReaderUsesAgentReadingContract(_ harness: String) async throws {
        guard let entry = try entry(harness) else { return }
        let manifestContext = HarnessRenderContext(content: .manifest,
            presentation: .main(excludedExecutionIDs: []),
            contentResource: { entry.log.resource($0) }, onIndexChange: { _ in })
        let manifest = try plugin(harness).threadView(
            input: .init(thread: entry.thread, readingTarget: entry.target),
            actions: entry.behavior, context: manifestContext)
        let rowKey = JSONText(harness == "codex" ? "turn:target" : "target")
        let rowThread = try HarnessThread(id: entry.thread.id, harnessID: entry.thread.harnessID, revision: 1,
            sessionState: entry.row["state"] ?? .null, observation: entry.thread.observation, cwd: "/tmp",
            settings: .object([:]), createdAt: 1, updatedAt: 40,
            title: entry.thread.title, tags: [])
        let rowContext = HarnessRenderContext(content: .row(rowKey),
            presentation: .main(excludedExecutionIDs: []),
            contentResource: { _ in HarnessContentResource(state: .loading, retry: {}, release: {}) },
            onIndexChange: { _ in })
        let row = try plugin(harness).threadView(
            input: .init(thread: rowThread, readingTarget: entry.target),
            actions: entry.behavior, context: rowContext)
            .environment(\.threadDetailVisibility, ThreadDetailVisibility(messageAnchorID: entry.anchor))
        let window = SwiftUIReplay.window(VStack(spacing: 0) {
            manifest.frame(height: 640)
            row.frame(height: 640)
        }.frame(width: 900), width: 900, height: 1280)
        defer { window.close() }
        try await SwiftUIReplay.wait(timeout: .seconds(8)) {
            entry.log.scopes.contains { if case .reading = $0 { true } else { false } }
        }
        #expect(!entry.log.scopes.contains { if case .execution = $0 { true } else { false } },
            "\(harness) Agent reader acquired an execution detail lease")
        #expect(!entry.log.scopes.contains { if case .row = $0 { true } else { false } },
            "\(harness) Agent reader used the full row contract")
        guard let path = ProcessInfo.processInfo.environment["MOKUSEI_AGENT_READING_FIXTURES"] else { return }
        let root = try JSONValue(data: Data(contentsOf: URL(fileURLWithPath: path)))
        guard let fixture = (root.arrayValue ?? []).first(where: { $0["harness"] == .text(harness) }) else { return }
        let visible = fixture["visible"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        try await SwiftUIReplay.wait {
            let text = SwiftUIReplay.text(in: window.contentView!)
            return visible.allSatisfy { text.contains($0) }
        }
        let text = SwiftUIReplay.text(in: window.contentView!)
        let hidden = fixture["hidden"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        for marker in hidden {
            #expect(!text.contains(marker), "\(harness) Agent reader mounted hidden execution body \(marker)")
        }
    }
}
