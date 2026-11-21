import Foundation
import ChiefCore
import ChiefPluginAPI
import ChiefPluginUI

/// The captured input owns its receipt until its persisted draft is consumed.
/// Retrying an uncertain send observes that receipt, including its original
/// Report/directory context; it never constructs another write.
@MainActor
final class NativeMokuSubmission {
    private final class Operation {
        let source: JSONValue
        let input: JSONValue
        let request: JSONValue
        let receiptID: String
        var attempted = false
        var accepted = false

        init(source: JSONValue, input: JSONValue, request: JSONValue, commandID: String) {
            receiptID = commandID
            self.source = source; self.input = input; self.request = request
        }

        func matches(source: JSONValue, input: JSONValue) -> Bool {
            self.source == source && self.input == input
        }
    }

    private let workspace: NativeWorkspaceModel
    private var operation: Operation?
    private var sending = false

    init(workspace: NativeWorkspaceModel) { self.workspace = workspace }

    func send(input: JSONValue, source: JSONValue, commandID: String, request: @MainActor () async throws -> JSONValue) async throws {
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
            guard previous.receiptID == commandID, previous.matches(source: source, input: input) else {
                throw blocked(previous.receiptID)
            }
            try await advance(previous)
            return
        }
        // A reopened owner lacks the submitted draft/source association. Its
        // durable receipt is a barrier, not permission to infer another input.
        if let held = await workspace.client.commandOutcomes().first(where: {
            $0.channel == "moku:submit" && $0.status != .rejected
        }) {
            await workspace.client.reconcileCommandReceipts()
            throw blocked(held.commandID, detail: workspace.locale.text(
                "先前提交的草稿上下文无法可靠还原，请核对 Chief 和原回执；不会重新发送。",
                "The previous draft context cannot be restored reliably. Check Chief and the original receipt; no resend will be attempted."))
        }
        try await workspace.prepareCommand()
        let captured = try await request()
        let next = Operation(source: source, input: input, request: captured, commandID: commandID)
        operation = next
        try await advance(next)
    }

    private func advance(_ current: Operation) async throws {
        guard !current.accepted else { return }
        let recovering = current.attempted
        do {
            if recovering {
                _ = try await workspace.client.resolveCommandReceipt(current.receiptID)
            } else {
                current.attempted = true
                _ = try await workspace.client.invoke("moku:submit", args: [current.request],
                    receiptID: current.receiptID, retainingReceipt: true)
            }
            current.accepted = true
        } catch let error as RuntimeError where error.kind == .commandRejected {
            throw RuntimeError(error.code, error.message, kind: .commandRejected, receiptID: current.receiptID)
        } catch {
            let tracked = await workspace.client.commandOutcomes().contains { $0.commandID == current.receiptID }
            if recovering || tracked { throw blocked(current.receiptID, kind: .uncertain) }
            // A first attempt with no record was never admitted or was
            // definitely rejected. Preparation failures must not strand input.
            if operation === current { operation = nil }
            if let failure = error as? RuntimeError, failure.code == "MOKU_SUBMISSION_RECEIPT_REQUIRED" {
                throw blocked(failure.receiptID ?? current.receiptID)
            }
            throw error
        }
    }

    var receipts: NativeComposerReceiptActions {
        NativeComposerReceiptActions(check: { [self] id in
            guard !sending else { throw blocked(id) }
            return try await workspace.client.checkSavedComposerReceipt(id, channel: "moku:submit")
        }, consume: { [self] id in
            try await workspace.client.consumeComposerReceipt(id, channel: "moku:submit")
        })
    }

    private func blocked(_ id: String, kind: RuntimeError.Kind = .protocolFailure, detail: String? = nil) -> RuntimeError {
        RuntimeError("MOKU_SUBMISSION_UNRESOLVED", workspace.locale.text(
            "上一输入可能已经成功，已阻止重新发送，草稿已保留。回执：\(id)。",
            "The previous input may already have succeeded. Resending is blocked and your draft has been kept. Receipt: \(id).")
            + (detail.map { " " + $0 } ?? workspace.locale.text(
                "请在原草稿中查询上一条回执。",
                "Use Check previous receipt in the original draft.")), kind: kind, receiptID: id)
    }
}
