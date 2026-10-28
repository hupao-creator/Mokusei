import Foundation
import MokuseiCore
import MokuseiPluginAPI

public struct NativeVoiceMediaState: Hashable, Sendable {
    public var phase: SidecardVoiceState.Phase = .closed
    public var available = false
    public var muted = false
    public var mediaSuspended = false
    public var caption: JSONText = ""
    public var error: JSONText = ""
    public var occupiedOwner: JSONText?
    public init() {}
}

struct NativeVoiceEvent: Sendable {
    let sequence: Int
    let type: String
    let text: JSONText?
    let transcript: VoiceTranscriptMessage?
    let sessionID: JSONText?
    let replyToItemID: JSONText?
    let generation: Int?
    let deliveryID: JSONText?

    init(_ value: JSONValue) throws {
        guard let sequence = value["sequence"]?.intValue, sequence >= 0,
              let type = value["type"]?.stringValue else {
            throw NativeVoiceError("语音服务返回了无效事件")
        }
        self.sequence = sequence; self.type = type
        text = value["text"]?.voiceText
        sessionID = value["sessionId"]?.voiceText
        replyToItemID = value["replyToItemId"]?.voiceText
        generation = value["generation"]?.intValue
        deliveryID = value["deliveryId"]?.voiceText
        if type == "transcript", let session = value["sessionId"]?.voiceText,
           let item = value["itemId"]?.voiceText, !session.codeUnits.isEmpty, !item.codeUnits.isEmpty,
           let role = value["role"]?.stringValue.flatMap(VoiceTranscriptMessage.Role.init(rawValue:)),
           let complete = value["complete"]?.boolValue, let createdAt = value["createdAt"]?.numberValue {
            transcript = try VoiceTranscriptMessage(
                id: JSONText(codeUnits: session.codeUnits + [58] + item.codeUnits), sessionID: session,
                role: role, text: text ?? "", complete: complete, createdAt: createdAt)
        } else { transcript = nil }
    }
}

struct NativeVoiceResult: Sendable {
    let sessionID: JSONText?
    let ownershipID: JSONText?
    let occupiedOwner: NativeVoiceOccupiedOwner?
    let sdp: String?
    let events: [NativeVoiceEvent]
    let reconnect: Bool
    let reconnectRetired: Bool
    let reconnectError: String?
    let supported: Bool
    let available: Bool
    let messages: [VoiceTranscriptMessage]

    init(_ value: JSONValue) throws {
        guard value.objectValue != nil else { throw NativeVoiceError("语音服务返回了无效响应") }
        sessionID = value["sessionId"]?.voiceText
        if let sessionID, UUID(uuidString: sessionID.string) == nil { throw NativeVoiceError("语音服务返回了无效会话") }
        ownershipID = value["ownershipId"]?.voiceText
        if let ownershipID, UUID(uuidString: ownershipID.string) == nil { throw NativeVoiceError("语音服务返回了无效所有权") }
        if let owner = value["occupiedOwner"] {
            guard let device = owner["deviceId"]?.voiceText,
                  let generation = owner["ownershipId"]?.voiceText,
                  !device.codeUnits.isEmpty, UUID(uuidString: generation.string) != nil else {
                throw NativeVoiceError("语音服务返回了无效占用状态")
            }
            occupiedOwner = NativeVoiceOccupiedOwner(deviceID: device, ownershipID: generation)
        } else { occupiedOwner = nil }
        sdp = value["sdp"]?.stringValue
        events = try (value["events"]?.arrayValue ?? []).map(NativeVoiceEvent.init)
        reconnect = value["reconnect"]?.boolValue ?? false
        reconnectRetired = value["reconnectRetired"]?.boolValue ?? false
        reconnectError = value["reconnectError"]?.stringValue
        supported = value["supported"]?.boolValue ?? false
        available = value["available"]?.boolValue ?? false
        messages = try (value["messages"]?.arrayValue ?? []).map { message in
            guard let id = message["id"]?.voiceText, let sessionID = message["sessionId"]?.voiceText,
                  let role = message["role"]?.stringValue.flatMap(VoiceTranscriptMessage.Role.init(rawValue:)),
                  let text = message["text"]?.voiceText, let complete = message["complete"]?.boolValue,
                  let createdAt = message["createdAt"]?.numberValue else {
                throw NativeVoiceError("语音服务返回了无效转写记录")
            }
            return try VoiceTranscriptMessage(id: id, sessionID: sessionID, role: role,
                                              text: text, complete: complete, createdAt: createdAt)
        }
    }
}

struct NativeVoiceOccupiedOwner: Sendable {
    let deviceID: JSONText
    let ownershipID: JSONText
}

struct NativeVoiceError: Error, LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension JSONValue {
    var voiceText: JSONText? { guard case .string(let text) = self else { return nil }; return text }
}

/// Tracks only media identities. Business events and canonical spoken transcripts
/// remain on the app-server sideband, just as in the desktop transport.
struct NativeVoicePlayback {
    var responseID: JSONText?
    var bufferedResponseID: JSONText?
    var playbackID: JSONText?
    var interrupted: [JSONText] = []

    mutating func receive(_ data: Data) {
        guard let event = try? JSONValue(data: data), let type = event["type"]?.stringValue else { return }
        if let id = event["response"]?["id"]?.voiceText, !interrupted.contains(id) {
            if type == "response.created" { responseID = id; bufferedResponseID = id }
            else if type == "response.done", responseID == id { responseID = nil }
        }
        guard let id = event["response_id"]?.voiceText, !interrupted.contains(id) else { return }
        if type == "output_audio_buffer.started" { playbackID = id }
        else if type == "output_audio_buffer.stopped" || type == "output_audio_buffer.cleared" {
            if playbackID == id { playbackID = nil }
            if bufferedResponseID == id { bufferedResponseID = nil }
        }
    }

    mutating func completeWithoutAudio(_ id: JSONText) {
        if responseID == id { responseID = nil }
        if bufferedResponseID == id { bufferedResponseID = nil }
        if playbackID == id { playbackID = nil }
    }

    mutating func interrupt() -> [JSONValue] {
        var commands: [JSONValue] = []
        if let responseID { commands.append(.object(["type": .text("response.cancel"), "response_id": .string(responseID)])) }
        if playbackID != nil || bufferedResponseID != nil { commands.append(.object(["type": .text("output_audio_buffer.clear")])) }
        for id in [responseID, bufferedResponseID, playbackID].compactMap({ $0 }) where !interrupted.contains(id) { interrupted.append(id) }
        if interrupted.count > 512 { interrupted.removeFirst(interrupted.count - 512) }
        responseID = nil; bufferedResponseID = nil; playbackID = nil
        return commands
    }
}
