import Observation
import MokuseiCore
import MokuseiPluginAPI

/// One execution display per Thread/plugin session. It owns no input draft or
/// send capability; folding retains the Harness's mounted response forms.
@MainActor @Observable
public final class ConversationSidecardPresentation {
    public private(set) var context: SidecardContext
    private var executionState = ConversationExecutionState()
    private let lifetime: PluginLifetime

    public init(context: SidecardContext, lifetime: PluginLifetime) {
        self.context = context
        self.lifetime = lifetime
        update(context: context)
    }

    public var activeExecutionID: JSONText? { executionState.activeExecutionID(thread: context.thread) }
    public var sidecardExecutionID: JSONText? {
        executionState.sidecardExecutionID(thread: context.thread, index: context.conversationIndex, readingTarget: context.readingTarget)
    }
    public var waiting: Bool { context.thread.observation.latestExecution?.status == .waitingForUser }

    public func update(context: SidecardContext) {
        guard !lifetime.isCancelled else { return }
        self.context = context
        executionState.update(thread: context.thread, index: context.conversationIndex,
                              readingTarget: context.readingTarget, expanded: context.expanded,
                              close: context.close)
    }
}
