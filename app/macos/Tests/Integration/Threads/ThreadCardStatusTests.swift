import Foundation
import Testing
import MokuseiPluginAPI
@testable import MokuseiPluginUI

@Suite struct ThreadCardStatusTests {
    @Test(arguments: ["zh-Hans", "en"])
    func newlyPublishedThreadStaysIdleWithoutVisibleStatus(localeID: String) throws {
        let locale = Locale(identifier: localeID)
        // Creation publishes an empty observation before Harness admission.
        let observation = try ThreadPublicObservation(json: .object([
            "latestExecution": .null, "backgroundWork": .null
        ]))
        let initial = threadCardStatus(observation)
        #expect(initial.kind == .idle)
        #expect(initial.terminal == nil)
        #expect(!initial.showsState)
        #expect(initial.providerLabel("Codex", locale: locale) == "Codex")
        #expect(initial.providerLabel(nil, locale: locale).isEmpty)
        #expect(!observation.isExecutionActive)

        // A subsequent public execution must immediately replace the hidden
        // initial presentation; no remembered suppression may swallow it.
        let running = threadCardStatus(.init(latestExecution: try .init(
            executionID: "first", status: .running, startedAt: 1
        )))
        #expect(running.kind == .running)
        #expect(running.providerLabel("Codex", locale: locale) ==
            (localeID == "en" ? "Codex · Running" : "Codex · 运行中"))

        let waiting = threadCardStatus(.init(latestExecution: try .init(
            executionID: "first", status: .waitingForUser, startedAt: 1,
            interactions: [.init(id: "approval", kind: .permission, title: "Allow command?",
                actions: [.init(id: "allow", intent: .allow, label: "Allow")], questions: [])]
        )))
        #expect(waiting.kind == .attention)
        #expect(waiting.providerLabel("Codex", locale: locale) ==
            (localeID == "en" ? "Codex · Awaiting approval" : "Codex · 等你授权"))

        for (status, terminal) in [(PublicExecution.Status.failed, ThreadCardTerminalStatus.failed),
                                   (.interrupted, .interrupted), (.completed, .completed)] {
            let finished = threadCardStatus(.init(latestExecution: try .init(
                executionID: "first", status: status, startedAt: 1, finishedAt: 2
            )))
            #expect(finished.terminal == terminal)
            #expect(finished.providerLabel("Codex", locale: locale) != "Codex")
        }
    }

    @Test func backgroundWorkStillShowsItsRealStatus() throws {
        let background = PublicBackgroundWork()
        let running = threadCardStatus(.init(backgroundWork: background))
        #expect(running.kind == .running)
        #expect(running.providerLabel("Codex", locale: Locale(identifier: "zh-Hans"))
            .contains("后台运行中"))

        let failed = threadCardStatus(.init(latestExecution: try .init(
            executionID: "first", status: .failed, startedAt: 1, finishedAt: 2
        ), backgroundWork: background))
        #expect(failed.kind == .failed)
        #expect(failed.showsState)
        #expect(failed.secondary == "后台仍在运行")
    }
}
