import Foundation
import OSLog
import MokuseiCore
import MokuseiPluginAPI

/// The captured input owns its receipt until its persisted draft is consumed.
/// Retrying an uncertain send observes that receipt, including its original
/// voice fence and Report/directory context; it never constructs another write.
@MainActor
final class NativeMokuSubmission {
    private final class Operation {
        let source: JSONValue
        let input: JSONValue
        let request: JSONValue
        let receiptID = "\(Int64(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.lowercased())"
        var attempted = false
        var accepted = false
        var draftConsumed = false

        init(source: JSONValue, input: JSONValue, request: JSONValue) {
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

    func send(input: JSONValue, source: JSONValue, request: @MainActor () async throws -> JSONValue) async throws {
        guard !sending else { throw PluginContractError(workspace.preferences.locale.text(
            "上一发送仍在确认，请稍候；草稿已保留。", "The previous send is still being confirmed. Please wait; your draft has been kept.")) }
        sending = true
        defer { sending = false }
        if let previous = operation {
            if previous.draftConsumed {
                try await release(previous)
                if operation === previous { operation = nil }
            } else {
                guard previous.matches(source: source, input: input) else {
                    throw blocked(previous.receiptID, detail: workspace.preferences.locale.text(
                        "请返回原草稿和提交内容后再次点击发送，以查询原回执；修改后的草稿已保留。",
                        "Return to the original draft and submitted content to query its receipt. Your edited draft has been kept."))
                }
                try await advance(previous)
                return
            }
        }
        // A reopened owner lacks the submitted draft/source association. Its
        // durable receipt is a barrier, not permission to infer another input.
        if let held = await workspace.client.commandOutcomes().first(where: {
            $0.channel == "moku:submit" && $0.status != .rejected
        }) {
            await workspace.client.reconcileCommandReceipts()
            throw blocked(held.commandID, detail: workspace.preferences.locale.text(
                "先前提交的草稿上下文无法可靠还原，请核对 Moku 和原回执；不会重新发送。",
                "The previous draft context cannot be restored reliably. Check Moku and the original receipt; no resend will be attempted."))
        }
        try await workspace.prepareCommand()
        let captured = try await request()
        let next = Operation(source: source, input: input, request: captured)
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
            try await release(current)
            if operation === current { operation = nil }
            throw error
        } catch {
            let tracked = await workspace.client.commandOutcomes().contains { $0.commandID == current.receiptID }
            if recovering || tracked { throw blocked(current.receiptID) }
            // A first attempt with no record was never admitted or was
            // definitely rejected. Preparation failures must not strand input.
            if operation === current { operation = nil }
            if let failure = error as? RuntimeError, failure.code == "MOKU_SUBMISSION_RECEIPT_REQUIRED" {
                throw blocked(failure.receiptID ?? current.receiptID)
            }
            throw error
        }
    }

    func didConsumeDraft(input: JSONValue, source: JSONValue) async {
        guard let current = operation, current.accepted,
              current.matches(source: source, input: input) else { return }
        current.draftConsumed = true
        do { try await release(current) }
        catch {
            // The accepted revision is already gone. Keep the operation and
            // receipt until cleanup succeeds, without turning success into a
            // send error or letting another draft replace the protected input.
            Logger(subsystem: "Mokusei", category: "MokuSubmission")
                .error("Accepted Moku receipt cleanup deferred: \(error.localizedDescription, privacy: .public)")
            return
        }
        if operation === current { operation = nil }
    }

    private func release(_ current: Operation) async throws {
        do { try await workspace.client.acknowledgeCommandOutcome(current.receiptID, allowResubmission: true) }
        catch { throw blocked(current.receiptID, detail: error.localizedDescription) }
        if await workspace.client.commandOutcomes().contains(where: { $0.commandID == current.receiptID }) {
            throw blocked(current.receiptID)
        }
    }

    private func blocked(_ id: String, detail: String? = nil) -> RuntimeError {
        RuntimeError("MOKU_SUBMISSION_UNRESOLVED", workspace.preferences.locale.text(
            "上一输入可能已经成功，已阻止重新发送，草稿已保留。回执：\(id)。",
            "The previous input may already have succeeded. Resending is blocked and your draft has been kept. Receipt: \(id).")
            + (detail.map { " " + $0 } ?? workspace.preferences.locale.text(
                "再次发送原草稿会先查询原回执；未确认结果时不会重发。",
                "Sending the original draft again checks its receipt first and never resends an unconfirmed input.")), receiptID: id)
    }
}
