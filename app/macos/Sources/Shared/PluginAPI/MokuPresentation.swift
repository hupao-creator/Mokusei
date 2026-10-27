import MokuseiCore

public enum HarnessActivityBody: Hashable, Sendable {
    case reasoning(text: JSONText, textOffset: Int?)
    case assistantText
    case toolCall(callID: JSONText, toolName: JSONText)
}
public struct HarnessActivity: Hashable, Sendable {
    public let executionID: JSONText
    public let sequence: Int
    public let body: HarnessActivityBody
    public init(executionID: JSONText, sequence: Int, body: HarnessActivityBody) {
        self.executionID = executionID; self.sequence = sequence; self.body = body
    }
}
public struct HarnessMokuReply: Hashable, Sendable {
    public let id: JSONText
    public let executionID: JSONText
    public let excerpt: JSONText
    public let target: JSONValue
    public init(id: JSONText, executionID: JSONText, excerpt: JSONText, target: JSONValue) {
        self.id = id; self.executionID = executionID; self.excerpt = excerpt; self.target = target
    }
}
public struct HarnessMokuPresentation: Hashable, Sendable {
    public let activity: HarnessActivity?
    public let reply: HarnessMokuReply?
    public init(activity: HarnessActivity?, reply: HarnessMokuReply?) { self.activity = activity; self.reply = reply }
    public static let maximumReasoningTailPoints = 56
    public static let maximumReplyExcerptPoints = 240
}
