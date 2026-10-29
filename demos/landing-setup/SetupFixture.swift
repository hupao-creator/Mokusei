import AppKit
import Observation
import SwiftUI
import MokuseiHarnessClaude
import MokuseiHarnessCodex
import MokuseiHarnessOpenCode
import MokuseiHarnessPi
import MokuseiPluginAPI
import MokuseiCore
import MokuseiPluginUI
@testable import MokuseiUI

enum SetupAgent: String, CaseIterable, Identifiable {
    case codex, claude, opencode, pi
    var id: String { rawValue }
    var name: String {
        switch self { case .codex: "Codex"; case .claude: "Claude Code"; case .opencode: "OpenCode"; case .pi: "Pi" }
    }
    var detail: String {
        switch self { case .codex: "OpenAI"; case .claude: "Anthropic"; case .opencode: "多模型 Agent"; case .pi: "可扩展 Agent" }
    }
    var models: [String] {
        // A deterministic catalog for design review, never a claim about native accounts.
        switch self {
        case .codex: ["GPT-6", "GPT-5.4"]
        case .claude: ["Claude Sonnet 4.6", "Claude Opus 4.6"]
        case .opencode: ["OpenAI / GPT-6", "Anthropic / Claude Sonnet 4.6"]
        case .pi: ["Anthropic / Claude Sonnet 4.6", "OpenAI / GPT-6"]
        }
    }
    var guide: URL {
        switch self {
        case .codex: URL(string: "https://developers.openai.com/codex/cli/")!
        case .claude: URL(string: "https://code.claude.com/docs/en/setup")!
        case .opencode: URL(string: "https://opencode.ai/docs/")!
        case .pi: URL(string: "https://github.com/badlogic/pi-mono/tree/main/packages/coding-agent")!
        }
    }
    @MainActor @ViewBuilder func logo(_ size: CGFloat) -> some View {
        switch self {
        case .codex: CodexHarnessPlugin().logo(size: size)
        case .claude: ClaudeHarnessPlugin().logo(size: size)
        case .opencode: OpenCodeHarnessPlugin().logo(size: size)
        case .pi: PiHarnessPlugin().logo(size: size)
        }
    }
    @MainActor var plugin: AnyHarnessPlugin {
        switch self {
        case .codex: AnyHarnessPlugin(CodexHarnessPlugin())
        case .claude: AnyHarnessPlugin(ClaudeHarnessPlugin())
        case .opencode: AnyHarnessPlugin(OpenCodeHarnessPlugin())
        case .pi: AnyHarnessPlugin(PiHarnessPlugin())
        }
    }
}

enum SetupStep: Int, CaseIterable {
    case discovery, moku, tag, report, landing
    var label: String {
        switch self { case .discovery: "发现"; case .moku: "Moku"; case .tag: "标签"; case .report: "报告"; case .landing: "开始" }
    }
}

struct SetupProfile: Equatable {
    var model: String
    var effort = "适中"
}

struct SetupRole {
    var followsHost = true
    var agent = SetupAgent.codex
    var profiles = Dictionary(uniqueKeysWithValues: SetupAgent.allCases.map { ($0, SetupProfile(model: $0.models[0])) })
}

@MainActor @Observable final class SetupFixture {
    var step = SetupStep.discovery
    var installed: Set<SetupAgent> = [.codex, .claude, .opencode]
    var discovered: [SetupAgent] = []
    var scanning = true
    var scanRevision = 0
    var coordination = makeCoordination(installed: [.codex, .claude, .opencode])
    let mapInteractions = NativeSettingsInteractions()
    let mapContext = NativeSettingsInteractionContext(visit: UUID(), section: "moku")
    var contrastBackdrop = false
    var handoffComplete = false
    @ObservationIgnored var panelFrame = CGRect.zero
    @ObservationIgnored var panelSamples: [CGRect] = []
    var host: SetupAgent { SetupAgent(rawValue: coordination.draft.value["moku"]!["hostHarnessPreference"]!.stringValue!)! }
    var targets: Set<SetupAgent> {
        Set(coordination.draft.value["moku"]!["targetHarnessIds"]!.arrayValue!.map { SetupAgent(rawValue: $0.stringValue!)! })
    }
    var hostProfiles = Dictionary(uniqueKeysWithValues: SetupAgent.allCases.map { ($0, SetupProfile(model: $0.models[0])) })
    var tag = SetupRole()
    var report = SetupRole()
    let landing = LandingFixture()
    var openControls: () -> Void = {}
    @ObservationIgnored var controlFrames: [String: CGRect] = [:]
    var available: [SetupAgent] { SetupAgent.allCases.filter { installed.contains($0) } }
    var canContinue: Bool { !scanning && !installed.isEmpty && !targets.isEmpty }

    func reset(empty: Bool = false, onlyCodex: Bool = false) {
        handoffComplete = false; panelSamples = []
        installed = empty ? [] : (onlyCodex ? [.codex] : [.codex, .claude, .opencode])
        coordination.discardForReload()
        coordination = Self.makeCoordination(installed: installed)
        hostProfiles = SetupRole().profiles; tag = SetupRole(); report = SetupRole()
        landing.reset(); step = .discovery; rescan()
    }
    func rescan() { discovered = []; scanning = true; scanRevision += 1 }
    func scan() async {
        let revision = scanRevision
        do {
            try await Task.sleep(for: .milliseconds(600))
            for agent in available {
                try await Task.sleep(for: .milliseconds(360))
                guard revision == scanRevision else { return }
                discovered.append(agent)
            }
        } catch { return }
        guard revision == scanRevision else { return }
        await coordination.refreshInstallations()
        guard revision == scanRevision, !Task.isCancelled else { return }
        scanning = false
    }
    func advance() {
        guard canContinue, let next = SetupStep(rawValue: step.rawValue + 1) else { return }
        if next == .landing, let target = available.first(where: { targets.contains($0) }) {
            // Dispatch chooses a target's own fixture profile, not the Host profile.
            landing.dispatchHarness = target.plugin
            landing.dispatchModel = target.models[0]
        }
        step = next
    }
    func back() {
        guard let previous = SetupStep(rawValue: step.rawValue - 1) else { return }
        step = previous
    }
    private static func makeCoordination(installed: Set<SetupAgent>) -> NativeSettingsModel {
        let targets: [SetupAgent] = installed.contains(.claude) ? [.codex, .claude] : [.codex]
        let model = NativeSettingsModel(settings: .object(["moku": .object([
            "hostHarnessPreference": .text("codex"),
            "targetHarnessIds": .array(targets.map { .text($0.rawValue) }),
            "routingGuidance": .null
        ])]), revision: 0,
            save: { value, revision in .saved(settings: value, revision: revision + 1) },
            clearHistory: {}, loadInstallations: {
                .object(Dictionary(uniqueKeysWithValues: SetupAgent.allCases.map { agent in
                    (JSONText(agent.rawValue), JSONValue.object(["status": .text(installed.contains(agent) ? "installed" : "missing")]))
                }))
            }, installHarness: { _ in })
        model.receive(snapshot: nil, runtimeAvailable: true)
        return model
    }
}
