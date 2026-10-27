import MokuseiCore
import MokuseiPluginAPI

/// Only the owning Harness supplies history. This value tracks presentation
/// around command receipts; it never derives another canonical timeline.
struct ConversationExecutionState {
    private struct AcceptedExecution {
        let id: JSONText
        let previousObservedID: JSONText?
    }
    private struct PendingSend {
        let requestID: Double
        let previousObservedID: JSONText?
        let openedRevision: Int
    }
    private var acceptedExecution: AcceptedExecution?
    private var pendingSend: PendingSend?
    private var previousActiveID: JSONText?
    private var initialOpenHandled = false
    private var handledReadingRequest: JSONText?

    var focusRequest = 0
    var initialDraft: JSONText?

    func activeExecutionID(thread: HarnessThread) -> JSONText? {
        if thread.observation.isExecutionActive { return thread.observation.latestExecution?.executionID }
        if let acceptedExecution,
           thread.observation.latestExecution?.executionID == acceptedExecution.previousObservedID {
            return acceptedExecution.id
        }
        return nil
    }

    func sidecardExecutionID(thread: HarnessThread, index: ThreadConversationIndex?) -> JSONText? {
        guard let active = activeExecutionID(thread: thread), Self.hasHistoryBefore(index, executionID: active) else { return nil }
        return active
    }

    static func hasHistoryBefore(_ index: ThreadConversationIndex?, executionID: JSONText?) -> Bool {
        guard let index else { return false }
        return index.hasInheritedHistory || index.executionIDs.contains { $0 != executionID }
    }

    mutating func requestFocus(initialDraft: JSONText? = nil) {
        focusRequest += 1
        self.initialDraft = initialDraft
    }

    mutating func sendStarted(requestID: Double, thread: HarnessThread, index: ThreadConversationIndex?,
                              selectionRevision: Int, open: () -> Int) {
        let observedActive = thread.observation.isExecutionActive ? thread.observation.latestExecution?.executionID : nil
        pendingSend = PendingSend(requestID: requestID,
                                  previousObservedID: thread.observation.latestExecution?.executionID,
                                  openedRevision: Self.hasHistoryBefore(index, executionID: observedActive) ? open() : selectionRevision)
        requestFocus()
    }

    mutating func sendFailed(requestID: Double) {
        if pendingSend?.requestID == requestID { pendingSend = nil }
    }

    mutating func sendAccepted(requestID: Double, executionID: JSONText, thread: HarnessThread,
                               selectionRevision: Int, close: () -> Void) {
        guard let pending = pendingSend, pending.requestID == requestID else { return }
        pendingSend = nil
        let outcome = thread.observation.latestExecution
        if outcome?.executionID == executionID && !thread.observation.isExecutionActive {
            // An asynchronous command must not undo a subsequent user selection.
            if selectionRevision == pending.openedRevision { close() }
        } else if outcome?.executionID == pending.previousObservedID && executionID != pending.previousObservedID {
            // The precise receipt is authoritative even when state delivery lags,
            // including a new execution which completes before the next snapshot.
            acceptedExecution = AcceptedExecution(id: executionID, previousObservedID: pending.previousObservedID)
            // Record this transition now. A very short execution may next be
            // observed only in its completed state, without an intervening update.
            previousActiveID = activeExecutionID(thread: thread)
        }
    }

    mutating func update(thread: HarnessThread, index: ThreadConversationIndex?, readingTarget: HarnessReadingTarget?,
                         expanded: Bool, selectionRevision: Int, open: () -> Int, close: () -> Void) {
        let active = activeExecutionID(thread: thread)
        let sidecardExecution = sidecardExecutionID(thread: thread, index: index)
        if !initialOpenHandled, index != nil {
            initialOpenHandled = true
            if sidecardExecution != nil && selectionRevision == 0 { _ = open() }
        }
        if let previousActiveID, active == nil,
           thread.observation.latestExecution?.executionID == previousActiveID,
           !thread.observation.isExecutionActive, expanded {
            close()
        }
        previousActiveID = active
        if let target = readingTarget, target.requestID != handledReadingRequest,
           target.executionID == sidecardExecution {
            handledReadingRequest = target.requestID
            _ = open()
        }
        if let acceptedExecution,
           thread.observation.latestExecution?.executionID != acceptedExecution.previousObservedID {
            self.acceptedExecution = nil
        }
    }
}
