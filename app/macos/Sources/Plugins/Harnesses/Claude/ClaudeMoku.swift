import Foundation
import MokuseiCore
import MokuseiPluginAPI

func claudeMoku(_ state: ClaudeState) -> HarnessMokuPresentation {
    var activity: HarnessActivity?
    if let turn = state.turns.last, turn.status == "running", let foreground = turn.raw["foreground"], let sequence = foreground["sequence"]?.intValue {
        let body: HarnessActivityBody?
        switch foreground.claudeKind {
        case "reasoning": body = .reasoning(text: foreground.claudeID("text"), textOffset: foreground["textOffset"]?.intValue)
        case "assistant-text": body = .assistantText
        case "tool-call": body = .toolCall(callID: foreground.claudeID("callId"), toolName: foreground.claudeID("toolName"))
        default: body = nil
        }
        activity = body.map { HarnessActivity(executionID: turn.id, sequence: sequence, body: $0) }
    }
    var reply: HarnessMokuReply?
    for turn in state.turns.reversed() where turn.status == "completed" {
        guard let message = turn.timeline.last(where: { $0.claudeKind == "assistant" && !claudeTrim($0["content"]).isEmpty }) else { continue }
        let identity = message["messageId"] ?? message["id"]!
        let content: JSONText
        if message["messageId"] != nil {
            content = JSONText(codeUnits: turn.timeline.filter { $0.claudeKind == "assistant" && $0["messageId"] == identity }.flatMap { $0.claudeID("content").codeUnits })
        } else { content = message.claudeID("content") }
        reply = HarnessMokuReply(id: JSONText(claudeJSONString(.array([.string(turn.id),identity]))), executionID: turn.id,
            excerpt: claudeHeadPoints(claudeTrimText(content), limit: HarnessMokuPresentation.maximumReplyExcerptPoints),
            target: claudeObject(["executionId": .string(turn.id),"messageId": identity]))
        break
    }
    return HarnessMokuPresentation(activity: activity, reply: reply)
}
func claudeReplyAnchor(_ state: ClaudeState, message: JSONValue?) -> JSONText? {
    guard let message, message.objectValue != nil,
          case .string(let execution)? = message["executionId"], case .string(let identity)? = message["messageId"],
          let turn = state.turns.first(where: { $0.id == execution }) else { return nil }
    return turn.timeline.last { $0.claudeKind == "assistant" && ($0["messageId"] ?? $0["id"]) == .string(identity) }?.claudeID("id")
}
func claudeTrimText(_ text: JSONText) -> JSONText {
    func whitespace(_ value: UInt16) -> Bool {
        switch value { case 0x0009...0x000D, 0x0020, 0x00A0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true; default: false }
    }
    var start = 0, end = text.codeUnits.count
    while start < end && whitespace(text.codeUnits[start]) { start += 1 }
    while end > start && whitespace(text.codeUnits[end-1]) { end -= 1 }
    return JSONText(codeUnits: Array(text.codeUnits[start..<end]))
}
func claudeHeadPoints(_ text: JSONText, limit: Int) -> JSONText {
    var end = 0, points = 0
    while end < text.codeUnits.count && points < max(0,limit) {
        let unit = text.codeUnits[end]
        let pair = (0xD800...0xDBFF).contains(unit) && end+1 < text.codeUnits.count && (0xDC00...0xDFFF).contains(text.codeUnits[end+1])
        end += pair ? 2 : 1; points += 1
    }
    return JSONText(codeUnits: Array(text.codeUnits.prefix(end)))
}
