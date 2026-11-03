import MokuseiCore
import MokuseiPluginAPI

/// Only observed active executions qualify. A send receipt acknowledges input,
/// not a still-running execution, and cannot make this display available.
struct ConversationExecutionState {
    func activeExecutionID(thread: HarnessThread) -> JSONText? {
        thread.observation.isExecutionActive ? thread.observation.latestExecution?.executionID : nil
    }

    func sidecardExecutionID(thread: HarnessThread, index: ThreadConversationIndex?) -> JSONText? {
        guard thread.archived != true, let active = activeExecutionID(thread: thread),
              Self.hasHistoryBefore(index, executionID: active) else { return nil }
        return active
    }

    static func hasHistoryBefore(_ index: ThreadConversationIndex?, executionID: JSONText?) -> Bool {
        guard let index else { return false }
        return index.hasInheritedHistory || index.executionIDs.contains { $0 != executionID }
    }

    func update(thread: HarnessThread, index: ThreadConversationIndex?,
                expanded: Bool, close: () -> Void) {
        // Availability alone does not request presentation. Entry and local
        // detail-send owners apply their separate, one-shot reveal policies.
        if expanded, sidecardExecutionID(thread: thread, index: index) == nil {
            close()
        }
    }
}
