import Foundation
import OSLog
import MokuseiCore
import MokuseiPluginAPI

/// Once a phase has a command identity, retries observe that phase; catalog
/// changes cannot choose a different write. The client journal survives windows.
@MainActor
final class NativeExecutionContinuation {
    private enum Phase {
        case fork(ApplicationExecutionRef)
        case followUp(threadID: JSONText, expected: JSONText?)
    }
    private final class Operation {
        let threadID: JSONText
        let executionID: JSONText?
        let input: JSONValue
        let phase: Phase
        let receiptID = "\(Int64(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.lowercased())"
        var attempted = false
        var result: JSONValue?
        var accepted: ApplicationExecutionRef?
        var draftConsumed = false
        init(threadID: JSONText, executionID: JSONText?, input: JSONValue, phase: Phase) {
            self.threadID = threadID; self.executionID = executionID; self.input = input; self.phase = phase
        }
        func matches(threadID: JSONText, executionID: JSONText?, input: JSONValue) -> Bool {
            self.threadID == threadID && self.executionID == executionID && self.input == input
        }
    }
    private let workspace: NativeWorkspaceModel
    private var forks: [ApplicationExecutionRef: JSONText] = [:]
    private var operation: Operation?
    private var sending = false
    init(workspace: NativeWorkspaceModel) { self.workspace = workspace }

    func send(threadID: JSONText, executionID: JSONText?, input: JSONValue) async throws -> ApplicationExecutionRef {
        guard !sending else { throw PluginContractError(workspace.preferences.locale.text(
            "上一发送仍在确认，请稍候；草稿已保留。", "The previous send is still being confirmed. Please wait; your draft has been kept.")) }
        sending = true
        defer { sending = false }
        if let previous = operation {
            if previous.draftConsumed {
                try await release(previous)
                operation = nil
            } else {
                guard previous.matches(threadID: threadID, executionID: executionID, input: input) else {
                    throw blocked(previous.receiptID, detail: workspace.preferences.locale.text(
                        "请返回原提交内容后再次点击发送，以查询原回执；修改后的草稿已保留。",
                        "Return to the original submitted content and press Send to query its receipt. Your edited draft has been kept."))
                }
                return try await advance(previous)
            }
        }
        // After relaunch, a receipt without its original source/input/phase is
        // a barrier, not permission to infer a new fork or input destination.
        let held = await workspace.client.commandOutcomes().first {
            ["thread:fork", "thread:follow-up"].contains($0.channel) && $0.status != .rejected
        }
        if let held {
            await workspace.client.reconcileCommandReceipts()
            throw blocked(held.commandID, detail: workspace.preferences.locale.text(
                "先前操作的提交上下文无法可靠还原，请核对原 Thread 和回执；不会自动创建分支或重新发送。",
                "The previous submission context cannot be restored reliably. Check the original thread and receipt; no fork or resend will be attempted."))
        }
        guard let source = workspace.catalog.thread(threadID), source.moku != true, !source.mokuHistory,
              workspace.canExecute(source) else {
            throw PluginContractError(workspace.preferences.locale.text(
                "此 Thread 当前无法接收输入，草稿已保留。", "This thread cannot accept input right now. Your draft has been kept."))
        }
        let reference = executionID.map { ApplicationExecutionRef(thread: .init(threadID: threadID, typeID: "agent"), executionID: $0) }
        let phase: Phase
        if let reference, let destination = forks[reference] { phase = .followUp(threadID: destination, expected: nil) }
        else if let reference, source.observation.latestExecution?.executionID != reference.executionID { phase = .fork(reference) }
        else { phase = .followUp(threadID: threadID, expected: executionID) }
        return try await advance(Operation(threadID: threadID, executionID: executionID, input: input, phase: phase))
    }

    private func advance(_ current: Operation) async throws -> ApplicationExecutionRef {
        operation = current
        if let accepted = current.accepted { return accepted }
        let result: JSONValue
        do { result = try await outcome(current) }
        catch let error as RuntimeError where error.kind == .commandRejected {
            // Only a definite rejection releases a phase. Unknown, pending and
            // indeterminate receipts never reach this branch.
            try await release(current)
            operation = nil
            if error.code == "EXECUTION_CHANGED", let executionID = current.executionID,
               case .followUp(_, let expected) = current.phase, expected != nil {
                let reference = ApplicationExecutionRef(thread: .init(threadID: current.threadID, typeID: "agent"), executionID: executionID)
                return try await advance(Operation(threadID: current.threadID, executionID: executionID,
                    input: current.input, phase: .fork(reference)))
            }
            throw error
        }
        switch current.phase {
        case .fork(let reference):
            guard case .string(let id) = result["threadId"], !id.codeUnits.isEmpty else { throw blocked(current.receiptID) }
            forks[reference] = id
            try await release(current)
            operation = nil
            return try await advance(Operation(threadID: current.threadID, executionID: current.executionID,
                input: current.input, phase: .followUp(threadID: id, expected: nil)))
        case .followUp(let threadID, _):
            guard case .string(let id) = result["executionId"], !id.codeUnits.isEmpty else { throw blocked(current.receiptID) }
            let accepted = ApplicationExecutionRef(thread: .init(threadID: threadID, typeID: "agent"), executionID: id)
            current.accepted = accepted
            if let executionID = current.executionID {
                forks[.init(thread: .init(threadID: current.threadID, typeID: "agent"), executionID: executionID)] = nil
            }
            // Keep the accepted receipt until the draft's captured revision is
            // consumed. Closing the reader cannot discard that durable barrier.
            return accepted
        }
    }

    private func outcome(_ current: Operation) async throws -> JSONValue {
        if let result = current.result { return result }
        let recovering = current.attempted
        do {
            let result: JSONValue
            if recovering {
                result = try await workspace.client.resolveCommandReceipt(current.receiptID)
            } else {
                try await workspace.prepareCommand()
                let channel: String, request: JSONValue
                switch current.phase {
                case .fork(let reference):
                    channel = "thread:fork"
                    request = .object(["threadId": .string(reference.thread.threadID),
                        "request": .object(["executionId": .string(reference.executionID)])])
                case .followUp(let threadID, let expected):
                    channel = "thread:follow-up"
                    var fields: [JSONText: JSONValue] = ["threadId": .string(threadID), "input": current.input]
                    if let expected { fields["expectedExecutionId"] = .string(expected) }
                    request = .object(fields)
                }
                current.attempted = true
                result = try await workspace.client.invoke(channel, args: [request], receiptID: current.receiptID, retainingReceipt: true)
            }
            current.result = result
            return result
        } catch let error as RuntimeError where error.kind == .commandRejected { throw error }
        catch {
            let tracked = await workspace.client.commandOutcomes().contains { $0.commandID == current.receiptID }
            if recovering || tracked { throw blocked(current.receiptID) }
            // The client persists admission before HTTP and retains every
            // ambiguous outcome. No entry on a first attempt means no admission
            // or a definite request rejection, not an uncertain command result.
            operation = nil
            if let failure = error as? RuntimeError, failure.code == "CONTINUATION_RECEIPT_REQUIRED" {
                throw blocked(failure.receiptID ?? current.receiptID)
            }
            throw error
        }
    }

    func didConsumeDraft(threadID: JSONText, executionID: JSONText?, input: JSONValue) async {
        guard let current = operation, current.accepted != nil,
              current.matches(threadID: threadID, executionID: executionID, input: input) else { return }
        current.draftConsumed = true
        do { try await release(current) }
        catch {
            // Sending already succeeded. Retain the operation and durable barrier
            // for send() to release before admitting new input, without turning
            // post-send housekeeping into a visible send failure.
            Logger(subsystem: "Mokusei", category: "ExecutionContinuation")
                .error("Accepted send receipt cleanup deferred: \(error.localizedDescription, privacy: .public)")
            return
        }
        // A newly mounted draft may already be finalizing this same receipt
        // and starting another operation while the acknowledgement is awaited.
        if operation === current { operation = nil }
    }

    private func release(_ current: Operation) async throws {
        do { try await workspace.client.acknowledgeCommandOutcome(current.receiptID, allowResubmission: true) }
        catch { throw blocked(current.receiptID, detail: error.localizedDescription, draftConsumed: current.draftConsumed) }
        if await workspace.client.commandOutcomes().contains(where: { $0.commandID == current.receiptID }) {
            throw blocked(current.receiptID, draftConsumed: current.draftConsumed)
        }
    }

    private func blocked(_ id: String, detail: String? = nil, draftConsumed: Bool = false) -> RuntimeError {
        let message = draftConsumed ? workspace.preferences.locale.text(
            "发送已确认且原草稿已消费，但回执保护尚未释放，新发送暂时暂停。回执：\(id)。",
            "The send is confirmed and its original draft has been consumed, but receipt protection has not been released. New sends are paused. Receipt: \(id).") : workspace.preferences.locale.text(
            "上一操作可能已经成功，已阻止新的分叉或重发，草稿已保留。回执：\(id)。",
            "The previous operation may already have succeeded. New forks and resends are blocked; your draft has been kept. Receipt: \(id).")
        return RuntimeError("EXECUTION_CONTINUATION_UNRESOLVED", message
            + (detail.map { " " + $0 } ?? workspace.preferences.locale.text(
                "再次点击发送会先查询原回执，未能确认结果时不会重发；请先核对原 Thread。",
                "Pressing Send again checks the original receipt first and never resends an unconfirmed operation. Check the original thread.")), receiptID: id)
    }
}
