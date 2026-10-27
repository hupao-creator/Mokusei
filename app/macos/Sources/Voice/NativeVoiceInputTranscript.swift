import Foundation
import MokuseiCore
import MokuseiPluginAPI

/// A live input projection, never a history log or composer draft. The sideband
/// sends accumulated partials, so each update replaces one stable ASR item.
public struct NativeVoiceInputTranscript: Equatable, Sendable {
    public private(set) var message: VoiceTranscriptMessage?
    private var sessionID: JSONText?
    private var current: VoiceTranscriptMessage?
    private var consumed = false
    private var sequence = -1
    private var seen: Set<JSONText> = []
    private var order: [JSONText] = []
    private var assistantItems: Set<JSONText> = []
    private var assistantOrder: [JSONText] = []

    public init() {}

    mutating func begin(sessionID: JSONText) {
        self = Self()
        self.sessionID = sessionID
    }

    mutating func receive(_ event: NativeVoiceEvent) {
        guard let sessionID, event.sequence > sequence else { return }
        // Control events may omit sessionId; the media client's Attempt fence
        // authenticates those. Transcript and feedback identities never may.
        if let source = event.sessionID, source != sessionID { return }
        sequence = event.sequence
        switch event.type {
        case "closed", "error": self = Self()
        case "transcript":
            guard let next = event.transcript, next.sessionID == sessionID else { return }
            if next.role == .user {
                if current?.id != next.id {
                    guard !next.text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    guard !seen.contains(next.id) else { return }
                    remember(next.id)
                    current = nil; consumed = false
                } else if current?.complete == true && !next.complete {
                    return // A late partial must not regress the final text.
                }
                current = next
                if !consumed { message = next.text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : next }
            } else if event.replyToItemID != nil {
                receiveFeedback(event)
            } else if !next.text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      assistantItems.insert(next.id).inserted {
                // Flat Codex replies have no input identity. Their first real
                // output retires the visible input; subsequent deltas must not
                // dismiss a new input spoken while that reply is streaming.
                assistantOrder.append(next.id)
                if assistantOrder.count > 256 { assistantItems.remove(assistantOrder.removeFirst()) }
                consumeCurrent()
            }
        case "answer": receiveFeedback(event)
        default: break
        }
    }

    private mutating func receiveFeedback(_ event: NativeVoiceEvent) {
        guard let sessionID, event.sessionID == sessionID,
              let text = event.text, !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let item = event.replyToItemID, !item.codeUnits.isEmpty else { return }
        let id = JSONText(codeUnits: sessionID.codeUnits + [58] + item.codeUnits)
        // Feedback may precede this item's first ASR or arrive while another
        // input is visible. Remember retirement so a late final cannot revive it.
        remember(id)
        if current?.id == id { consumeCurrent() }
    }

    private mutating func remember(_ id: JSONText) {
        guard seen.insert(id).inserted else { return }
        order.append(id)
        if order.count > 256 { seen.remove(order.removeFirst()) }
    }

    private mutating func consumeCurrent() {
        guard current != nil else { return }
        consumed = true
        message = nil
    }
}
