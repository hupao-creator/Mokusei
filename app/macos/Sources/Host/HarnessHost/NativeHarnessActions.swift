import Foundation
import MokuseiCore
import MokuseiPluginAPI

extension NativeHarnessHost {
    func boundActions(threadID: JSONText, harnessID: JSONText,
                      observedCancellationID: JSONText?,
                      source: NativeHarnessConversationSource? = nil,
                      routes: @escaping () -> NativeHarnessThreadRoutes? = { nil },
                      checkLifetime: @escaping () throws -> Void) -> HarnessThreadActions {
        HarnessThreadActions(
            interrupt: { [weak self] in
                guard let self else { throw CancellationError() }
                guard let target = observedCancellationID else { throw PluginContractError("There is no observed execution to stop") }
                let current = try await prepareAction(threadID: threadID, harnessID: harnessID, source: source, checkLifetime: checkLifetime)
                if let interrupt = routes()?.interrupt {
                    guard current.cancellationID == target else { throw PluginContractError("The observed execution has ended or changed; refresh before stopping another execution") }
                    try await interrupt()
                }
                else {
                    let result = try await client.invoke("thread:interrupt", args: [.object([
                        "threadId": .string(threadID), "expectedCancellationId": .string(target)
                    ])])
                    if result["status"]?.stringValue == "stale" { throw PluginContractError("The observed execution has ended or changed; refresh before stopping another execution") }
                }
            },
            respond: { [weak self] response in
                guard let self else { throw CancellationError() }
                let thread = try await prepareAction(threadID: threadID, harnessID: harnessID, source: source, checkLifetime: checkLifetime)
                guard let interaction = thread.observation.latestExecution?.interactions.first(where: { $0.id == response.interactionID }),
                      interaction.actions.contains(where: { $0.id == response.actionID }) else {
                    throw PluginContractError("This interaction is no longer awaiting that response")
                }
                guard case .object(var payload) = response.json else { throw PluginContractError("Invalid interaction response") }
                payload["threadId"] = .string(threadID)
                payload["executionId"] = thread.observation.latestExecution.map { .string($0.executionID) }
                _ = try await client.invoke("thread:interaction-respond", args: [.object(payload)])
            },
            invokeHarnessExtension: { [weak self] method, payload in
                guard let self else { throw CancellationError() }
                try await prepareAction(threadID: threadID, harnessID: harnessID, source: source, checkLifetime: checkLifetime)
                return try await client.invoke("harness:extension", args: [.object([
                    "harnessId": .string(harnessID), "method": .string(method), "payload": payload
                ])])
            },
            forkThread: { [weak self] request in
                guard let self else { throw CancellationError() }
                try await prepareAction(threadID: threadID, harnessID: harnessID, source: source, checkLifetime: checkLifetime)
                let result = try await client.invoke("thread:fork", args: [.object(["threadId": .string(threadID), "request": request])])
                guard case .string(let id) = result["threadId"], !id.codeUnits.isEmpty else {
                    throw PluginContractError("Thread fork returned no thread identity")
                }
                return id
            },
            openExternal: { [weak self] url in
                guard let self else { throw CancellationError() }
                try checkLifetime()
                _ = try authoritativeThread(threadID: threadID, harnessID: harnessID, source: source)
                if let route = routes()?.openExternal { try await route(url) }
                else { try await callbacks.openExternal(url) }
            },
            openFollowUp: { [weak self] draft in
                guard let self else { return }
                do {
                    try checkLifetime()
                    _ = try authoritativeThread(threadID: threadID, harnessID: harnessID, execution: true, source: source)
                    guard !draft.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          draft.codeUnits.count <= 1_000_000 else {
                        throw PluginContractError("Follow-up draft must be nonempty and no longer than 1,000,000 UTF-16 units")
                    }
                    if let route = routes()?.openFollowUp { route(draft) }
                    else { callbacks.openFollowUp(threadID, draft) }
                } catch { callbacks.onError(error) }
            }
        )
    }

    @discardableResult
    private func prepareAction(threadID: JSONText, harnessID: JSONText,
                               source: NativeHarnessConversationSource? = nil,
                               checkLifetime: () throws -> Void) async throws -> HarnessThread {
        try checkLifetime()
        _ = try authoritativeThread(threadID: threadID, harnessID: harnessID, execution: true, source: source)
        try await callbacks.beforeCommand()
        try checkLifetime()
        return try authoritativeThread(threadID: threadID, harnessID: harnessID, execution: true, source: source)
    }

    func updateThreadSettings(threadID: JSONText, harnessID: JSONText, change: JSONValue,
                              expectedSettingsRevision: Int,
                              checkLifetime: () throws -> Void) async throws -> NativeThreadSettingsUpdateResult {
        guard case .object = change else { throw PluginContractError("Thread settings change must be an object") }
        guard expectedSettingsRevision >= 0 else { throw PluginContractError("Invalid expected thread settings revision") }
        try await prepareAction(threadID: threadID, harnessID: harnessID, checkLifetime: checkLifetime)
        let result = try await client.invoke("thread:update-settings", args: [.object([
            "threadId": .string(threadID), "harnessId": .string(harnessID), "change": change,
            "expectedSettingsRevision": .integer(expectedSettingsRevision)
        ])])
        try checkLifetime()
        return try NativeThreadSettingsUpdateResult(result)
    }
}

struct NativeThreadSettingsUpdateResult {
    let saved: Bool
    let settingsRevision: Int
    let settings: JSONValue

    init(_ value: JSONValue) throws {
        guard let status = value["status"]?.stringValue, ["saved", "conflict"].contains(status),
              let revision = value["settingsRevision"]?.intValue, revision >= 0,
              let settings = value["settings"], case .object = settings else {
            throw PluginContractError("Invalid thread settings update result")
        }
        saved = status == "saved"; settingsRevision = revision; self.settings = settings
    }
}
