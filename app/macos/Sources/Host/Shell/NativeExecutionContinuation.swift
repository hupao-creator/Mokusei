import MokuseiCore
import MokuseiPluginAPI

/// One window's execution send boundary, shared by Agent and application readers.
/// A fork survives a rejected follow-up so another surface can retry its draft
/// without creating a second branch. Runtime receipts retain uncertain writes.
@MainActor
final class NativeExecutionContinuation {
    private let workspace: NativeWorkspaceModel
    private var forks: [ApplicationExecutionRef: JSONText] = [:]

    init(workspace: NativeWorkspaceModel) { self.workspace = workspace }

    func send(threadID: JSONText, executionID: JSONText?, input: JSONValue) async throws -> ApplicationExecutionRef {
        guard let source = workspace.catalog.thread(threadID), source.moku != true, !source.mokuHistory,
              workspace.canExecute(source) else {
            throw PluginContractError(workspace.preferences.locale.text(
                "此 Thread 当前无法接收输入，草稿已保留。", "This thread cannot accept input right now. Your draft has been kept."))
        }
        let reference = executionID.map { ApplicationExecutionRef(thread: .init(threadID: threadID, typeID: "agent"), executionID: $0) }
        var destination = threadID
        if let reference, forks[reference] != nil || source.observation.latestExecution?.executionID != reference.executionID {
            destination = try await fork(reference)
        }
        let accepted: JSONText
        do {
            accepted = try await followUp(threadID: destination,
                expected: destination == threadID ? executionID : nil, input: input)
        } catch let error as RuntimeError where error.kind == .commandRejected && error.code == "EXECUTION_CHANGED" {
            // Runtime proves that no dispatch/reservation occurred. A catalog
            // race can therefore take the same historical path safely once.
            guard let reference else { throw error }
            destination = try await fork(reference)
            accepted = try await followUp(threadID: destination, expected: nil, input: input)
        }
        if let reference { forks[reference] = nil }
        return ApplicationExecutionRef(thread: .init(threadID: destination, typeID: "agent"), executionID: accepted)
    }

    private func fork(_ reference: ApplicationExecutionRef) async throws -> JSONText {
        if let existing = forks[reference] { return existing }
        let result = try await workspace.invoke("thread:fork", args: [.object([
            "threadId": .string(reference.thread.threadID), "request": .object(["executionId": .string(reference.executionID)])
        ])])
        guard case .string(let id) = result["threadId"], !id.codeUnits.isEmpty else {
            throw PluginContractError("Thread fork returned no thread identity")
        }
        forks[reference] = id
        return id
    }

    private func followUp(threadID: JSONText, expected: JSONText?, input: JSONValue) async throws -> JSONText {
        var request: [JSONText: JSONValue] = ["threadId": .string(threadID), "input": input]
        if let expected { request["expectedExecutionId"] = .string(expected) }
        let result = try await workspace.invoke("thread:follow-up", args: [.object(request)])
        guard case .string(let id) = result["executionId"], !id.codeUnits.isEmpty else {
            throw PluginContractError("The runtime returned no accepted execution identity")
        }
        return id
    }
}
