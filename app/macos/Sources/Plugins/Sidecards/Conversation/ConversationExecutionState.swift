import MokuseiCore
import MokuseiPluginAPI

/// Only observed active executions qualify. A send receipt acknowledges input,
/// not a still-running execution, and cannot make this display available.
struct ConversationExecutionState {
    func activeExecutionID(thread: HarnessThread) -> JSONText? {
        thread.observation.isExecutionActive ? thread.observation.latestExecution?.executionID : nil
    }

    func sidecardExecutionID(thread: HarnessThread, index: ThreadConversationIndex?, readingTarget: HarnessReadingTarget? = nil) -> JSONText? {
        guard thread.archived != true, let active = activeExecutionID(thread: thread),
              Self.hasHistoryBefore(index, executionID: active) else { return nil }
        if readingTarget?.position == .result, readingTarget?.executionID == active { return nil }
        return active
    }

    static func hasHistoryBefore(_ index: ThreadConversationIndex?, executionID: JSONText?) -> Bool {
        guard let index else { return false }
        return index.hasInheritedHistory || index.executionIDs.contains { $0 != executionID }
    }

    func update(thread: HarnessThread, index: ThreadConversationIndex?, readingTarget: HarnessReadingTarget?,
                expanded: Bool, close: () -> Void) {
        // Starting or navigating an execution only exposes the launcher. The
        // user's show/hide choice must not be overridden by background updates.
        if expanded, sidecardExecutionID(thread: thread, index: index, readingTarget: readingTarget) == nil {
            close()
        }
    }
}
