import Foundation
import MokuseiCore
import MokuseiPluginAPI

/// Public Moku tool audit projection. No owning Harness state is interpreted.
public struct NativeOverviewMokuOperation: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case list, start, send, status, interrupt }
    public enum Phase: String, Sendable { case running, completed, failed }
    public let id: String
    public let kind: Kind
    public let phase: Phase
    public let threadID: String?
    public init(id: String, kind: Kind, phase: Phase, threadID: String? = nil) {
        self.id = id; self.kind = kind; self.phase = phase; self.threadID = threadID
    }
    public static func project(transcript: JSONValue?) -> [Self] {
        guard let transcript = transcript?.arrayValue,
              let execution = transcript.reversed().compactMap({ text($0["executionId"]) }).first else { return [] }
        return transcript.flatMap { item -> [Self] in
            guard item["type"]?.stringValue == "tool-operation", item["executionId"]?.stringValue == execution,
                  let id = item["id"]?.stringValue, let name = item["name"]?.stringValue else { return [] }
            let kind: Kind
            switch name {
            case "list_threads": kind = .list
            case "create_thread": kind = .start
            case "send_to_thread": kind = .send
            case "get_thread_status": kind = .status
            case "interrupt_thread": kind = .interrupt
            default: return []
            }
            let arguments = item["arguments"], result = item["result"]
            let phase: Phase = item["completedAt"] == nil ? .running : item["isError"]?.boolValue == true ? .failed : .completed
            if kind == .interrupt, let threadIDs = arguments?["threadIds"]?.arrayValue {
                let results = result?["results"]?.arrayValue ?? []
                return threadIDs.enumerated().compactMap { index, value in
                    guard let threadID = text(value) else { return nil }
                    let outcome = results.indices.contains(index) ? results[index] : nil
                    let targetPhase: Phase = phase == .completed && outcome?["ok"]?.boolValue == false ? .failed : phase
                    return Self(id: "\(id):\(index)", kind: kind, phase: targetPhase, threadID: threadID)
                }
            }
            return [Self(id: id, kind: kind, phase: phase,
                        threadID: text(arguments?["threadId"]) ?? text(result?["threadId"]))]
        }
    }
    private static func text(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue, !NativeOverviewSelection.trim(text).isEmpty else { return nil }
        return text
    }
}
