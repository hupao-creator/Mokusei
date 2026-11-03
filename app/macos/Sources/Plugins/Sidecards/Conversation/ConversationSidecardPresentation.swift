import Foundation
import Observation
import MokuseiCore
import MokuseiPluginAPI

/// One execution display per Thread/plugin session. It owns no input draft or
/// send capability; folding retains the Harness's mounted response forms.
@MainActor @Observable
public final class ConversationSidecardPresentation {
    public private(set) var context: SidecardContext
    private let executionState = ConversationExecutionState()
    private let lifetime: PluginLifetime
    @ObservationIgnored private var revealID: UUID?
    @ObservationIgnored private var pendingReveal = false
    @ObservationIgnored private var revealSelection = 0
    @ObservationIgnored private var revealTarget: HarnessReadingTarget?
    @ObservationIgnored private var entered = false
    @ObservationIgnored private var entryTarget: HarnessReadingTarget?
    @ObservationIgnored private var entryExecution: JSONText?
    @ObservationIgnored private var entrySelection = 0

    public init(context: SidecardContext, lifetime: PluginLifetime) {
        self.context = context
        self.lifetime = lifetime
        update(context: context)
    }

    public var activeExecutionID: JSONText? { executionState.activeExecutionID(thread: context.thread) }
    public var sidecardExecutionID: JSONText? {
        context.executionHandoff ?? executionState.sidecardExecutionID(thread: context.thread, index: context.conversationIndex)
    }
    public var waiting: Bool { context.thread.observation.latestExecution?.status == .waitingForUser }

    public func update(context: SidecardContext) {
        guard !lifetime.isCancelled else { return }
        self.context = context
        let previousSelection = context.selectionRevision()
        if context.executionHandoff == nil {
            executionState.update(thread: context.thread, index: context.conversationIndex,
                                  expanded: context.expanded,
                                  close: context.close)
        }
        // Retiring our predecessor is not a user choosing another card while
        // the next send waits for admission.
        if pendingReveal, revealSelection == previousSelection {
            revealSelection = context.selectionRevision()
        }
        if !entered || entryTarget != context.readingTarget {
            entered = true; entryTarget = context.readingTarget
            entryExecution = context.readingTarget?.executionID ?? activeExecutionID
            entrySelection = context.selectionRevision()
        }
        if let request = context.executionReveal, request.id != revealID {
            entryExecution = nil
            revealID = request.id; pendingReveal = true
            revealSelection = context.selectionRevision(); revealTarget = context.readingTarget
        }
        if let execution = entryExecution {
            if context.selectionRevision() != entrySelection || context.thread.archived == true || context.executionDisabled {
                entryExecution = nil
            } else if sidecardExecutionID == execution {
                entryExecution = nil
                _ = context.open()
            } else if context.thread.observation.latestExecution?.executionID == execution, activeExecutionID == nil {
                entryExecution = nil
            }
        }
        guard pendingReveal else { return }
        guard let request = context.executionReveal,
              context.selectionRevision() == revealSelection, context.readingTarget == revealTarget,
              context.thread.archived != true, !context.executionDisabled else {
            pendingReveal = false; return
        }
        guard let receipt = request.receipt,
              let execution = context.thread.observation.latestExecution,
              execution.executionID == receipt.executionID else { return }
        guard context.thread.observation.isExecutionActive else {
            pendingReveal = false; return
        }
        // Receipt and catalog/index delivery can arrive in either order. Only
        // the exact active execution may move into the sidecard.
        if sidecardExecutionID == receipt.executionID {
            pendingReveal = false
            _ = context.open()
        }
    }
}
