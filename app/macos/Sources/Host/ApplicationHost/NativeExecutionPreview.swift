import MokuseiCore
import MokuseiPluginAPI

/// One exact Report reference resolved by the runtime. Current Thread status is
/// deliberately absent: it comes from report.relations, not from this preview.
struct NativeExecutionPreview {
    let thread: JSONText
    let executionID: JSONText
    let title: JSONText?
    let preview: HarnessExecutionPreview

    init(json: JSONValue) throws {
        guard case let .object(fields) = json,
              fields.keys.allSatisfy({ ["threadId", "executionId", "title", "status", "startedAt", "finishedAt", "excerpt"].contains($0) }),
              let threadValue = fields["threadId"], case let .string(thread) = threadValue,
              let executionValue = fields["executionId"], case let .string(execution) = executionValue,
              Self.identifier(thread), Self.identifier(execution) else {
            throw PluginContractError("Execution preview identity is invalid")
        }
        self.thread = thread
        self.executionID = execution
        if let value = fields["title"], value != .null {
            guard case let .string(text) = value, !text.codeUnits.isEmpty, !text.codeUnits.contains(0) else {
                throw PluginContractError("Execution preview title is invalid")
            }
            title = text
        } else { title = nil }
        guard let statusValue = fields["status"], case let .string(status) = statusValue,
              let startedAt = fields["startedAt"]?.numberValue, startedAt.isFinite, startedAt >= 0,
              let excerptValue = fields["excerpt"], case let .string(excerpt) = excerptValue,
              !excerpt.codeUnits.contains(0) else {
            throw PluginContractError("Execution preview facts are invalid")
        }
        let finishedAt = fields["finishedAt"]?.numberValue
        let running: Bool
        switch status {
        case "running": running = true; guard finishedAt == nil else { throw PluginContractError("Running preview has a finish time") }
        case "waiting-for-user": running = true; guard finishedAt == nil else { throw PluginContractError("Waiting preview has a finish time") }
        case "completed", "failed", "interrupted": running = false
        default: throw PluginContractError("Execution preview status is invalid")
        }
        preview = try HarnessExecutionPreview(startedAt: startedAt, finishedAt: finishedAt,
            running: running, excerpt: excerpt)
    }

    private static func identifier(_ value: JSONText) -> Bool {
        guard let first = value.codeUnits.first, value.codeUnits.count <= 128 else { return false }
        func alphanumeric(_ unit: UInt16) -> Bool {
            (48...57).contains(unit) || (65...90).contains(unit) || (97...122).contains(unit)
        }
        return alphanumeric(first) && value.codeUnits.allSatisfy {
            alphanumeric($0) || [46, 95, 58, 45].contains($0)
        }
    }
}
