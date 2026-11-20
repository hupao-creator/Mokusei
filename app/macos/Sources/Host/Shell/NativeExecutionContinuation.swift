import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI

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
        let predecessorReceiptID: String?
        let receiptID: String
        var attempted = false
        var result: JSONValue?
        var accepted: ApplicationExecutionRef?
        init(threadID: JSONText, executionID: JSONText?, input: JSONValue, phase: Phase,
             receiptID: String, predecessorReceiptID: String? = nil) {
            self.receiptID = receiptID
            self.threadID = threadID; self.executionID = executionID; self.input = input; self.phase = phase
            self.predecessorReceiptID = predecessorReceiptID
        }
        func matches(threadID: JSONText, executionID: JSONText?, input: JSONValue) -> Bool {
            self.threadID == threadID && self.executionID == executionID && self.input == input
        }
    }
    private let workspace: NativeWorkspaceModel
    private var operation: Operation?
    private var sending = false
    init(workspace: NativeWorkspaceModel) { self.workspace = workspace }

    func send(threadID: JSONText, executionID: JSONText?, input: JSONValue, commandID: String) async throws -> ApplicationExecutionRef {
        guard !sending else { throw PluginContractError(workspace.locale.text(
            "上一发送仍在确认，请稍候；草稿已保留。", "The previous send is still being confirmed. Please wait; your draft has been kept.")) }
        sending = true
        defer { sending = false }
        // A reopened owner may have settled and consumed this receipt.
        if let previous = operation, previous.attempted,
           try await !workspace.client.retainsCommandReceipt(previous.receiptID) {
            operation = nil
        }
        if let previous = operation {
            guard previous.receiptID == commandID, previous.matches(threadID: threadID, executionID: executionID, input: input) else {
                throw blocked(previous.receiptID)
            }
            return try await advance(previous)
        }
        // After relaunch, a receipt without its original source/input/phase is
        // a barrier, not permission to infer a new fork or input destination.
        let held = await workspace.client.commandOutcomes().first { $0.requiresContinuationContext }
        if let held {
            await workspace.client.reconcileCommandReceipts()
            throw blocked(held.commandID, detail: workspace.locale.text(
                "先前操作的提交上下文无法可靠还原，请核对原 Thread 和回执；不会自动创建分支或重新发送。",
                "The previous submission context cannot be restored reliably. Check the original thread and receipt; no fork or resend will be attempted."))
        }
        guard let source = workspace.catalog.thread(threadID), source.moku != true, !source.mokuHistory,
              workspace.canExecute(source) else {
            throw PluginContractError(workspace.locale.text(
                "此 Thread 当前无法接收输入，草稿已保留。", "This thread cannot accept input right now. Your draft has been kept."))
        }
        let reference = executionID.map { ApplicationExecutionRef(thread: .init(threadID: threadID, typeID: "agent"), executionID: $0) }
        let phase: Phase
        if let reference, source.observation.latestExecution?.executionID != reference.executionID { phase = .fork(reference) }
        else { phase = .followUp(threadID: threadID, expected: executionID) }
        return try await advance(Operation(threadID: threadID, executionID: executionID, input: input, phase: phase, receiptID: commandID))
    }

    private func advance(_ current: Operation) async throws -> ApplicationExecutionRef {
        operation = current
        if let accepted = current.accepted { return accepted }
        let result: JSONValue
        do { result = try await outcome(current) }
        catch let error as RuntimeError where error.kind == .commandRejected
            || (error.kind == .requestRejected && current.predecessorReceiptID != nil) {
            if current.predecessorReceiptID != nil {
                // The input was rejected, but the fork already exists. Keep its
                // receipt attached until the user reviews the unsent input.
                throw blocked(current.receiptID, kind: .uncertain, detail: error.localizedDescription)
            }
            guard current.attempted else { operation = nil; throw error }
            let rejection = RuntimeError(error.code, error.message, kind: .commandRejected, receiptID: current.receiptID)
            if error.code == "EXECUTION_CHANGED", let executionID = current.executionID,
               case .followUp(_, let expected) = current.phase, expected != nil {
                // Only the original Send can transition this definitive rejection
                // to a fork. If cleanup fails, let the draft retain the rejected ID.
                do { try await workspace.client.consumeComposerReceipt(current.receiptID, channel: "thread:follow-up") }
                catch { throw rejection }
                let reference = ApplicationExecutionRef(thread: .init(threadID: current.threadID, typeID: "agent"), executionID: executionID)
                return try await advance(Operation(threadID: current.threadID, executionID: executionID,
                    input: current.input, phase: .fork(reference), receiptID: current.receiptID + "-fork"))
            }
            throw rejection
        }
        switch current.phase {
        case .fork:
            guard case .string(let id) = result["threadId"], !id.codeUnits.isEmpty else { throw blocked(current.receiptID, kind: .uncertain) }
            // invoke transfers the durable barrier atomically when it registers
            // the follow-up. Releasing here would orphan the fork after a crash.
            return try await advance(Operation(threadID: current.threadID, executionID: current.executionID,
                input: current.input, phase: .followUp(threadID: id, expected: nil),
                receiptID: current.receiptID + "-followup", predecessorReceiptID: current.receiptID))
        case .followUp(let threadID, _):
            guard case .string(let id) = result["executionId"], !id.codeUnits.isEmpty else { throw blocked(current.receiptID, kind: .uncertain) }
            let accepted = ApplicationExecutionRef(thread: .init(threadID: threadID, typeID: "agent"), executionID: id)
            current.accepted = accepted
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
                result = try await workspace.client.invoke(channel, args: [request], receiptID: current.receiptID,
                    retainingReceipt: true, replacingReceipt: current.predecessorReceiptID)
            }
            current.result = result
            return result
        } catch let error as RuntimeError where error.kind == .commandRejected { throw error }
        catch {
            let outcomes = await workspace.client.commandOutcomes()
            let tracked = outcomes.first { $0.commandID == current.receiptID }
            if let failure = error as? RuntimeError, failure.kind == .requestRejected,
               tracked?.forkReceiptID != nil, tracked?.status == .rejected {
                throw failure
            }
            if recovering || tracked != nil { throw blocked(current.receiptID, kind: .uncertain) }
            if let predecessor = current.predecessorReceiptID,
               outcomes.contains(where: { $0.commandID == predecessor }) {
                // Preparation or journal admission failed before dispatch. The
                // original fork still owns the barrier; retry this handoff only.
                operation = nil
                throw blocked(predecessor, kind: .uncertain)
            }
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

    var receipts: NativeComposerReceiptActions {
        NativeComposerReceiptActions(check: { [self] id in
            guard !sending else { throw blocked(id) }
            return try await workspace.client.checkSavedComposerReceipt(id, channel: "thread:follow-up")
        }, consume: { [self] id in
            try await workspace.client.consumeComposerReceipt(id, channel: "thread:follow-up")
        })
    }

    private func blocked(_ id: String, kind: RuntimeError.Kind = .protocolFailure, detail: String? = nil) -> RuntimeError {
        let message = workspace.locale.text(
            "上一操作可能已经成功，已阻止新的分叉或重发，草稿已保留。回执：\(id)。",
            "The previous operation may already have succeeded. New forks and resends are blocked; your draft has been kept. Receipt: \(id).")
        return RuntimeError("EXECUTION_CONTINUATION_UNRESOLVED", message
            + (detail.map { " " + $0 } ?? workspace.locale.text(
                "请在原草稿中查询上一条回执并核对原 Thread。",
                "Use Check previous receipt in the original draft and check the original thread.")), kind: kind, receiptID: id)
    }
}
