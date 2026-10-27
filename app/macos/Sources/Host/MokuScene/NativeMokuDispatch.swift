import Foundation
import MokuseiCore
import MokuseiPluginAPI

/// Only public create_thread audit facts. Requested options describe the target;
/// a successful result acknowledges a started Thread, never completed work.
public struct NativeMokuDispatch: Equatable, Sendable {
    public enum Phase: Sendable { case dispatching, started, failed }
    public let harnessID: JSONText
    public let prompt: String?
    public let model: String?
    public let thinking: String?
    public let provider: String?
    public let phase: Phase
    public let threadID: String?
    public let error: String?

    init?(operation: JSONValue, executionIsActive: Bool) {
        guard operation["name"]?.stringValue == "create_thread",
              let harness = Self.text(operation["arguments"]?["harnessId"]) else { return nil }
        let arguments = operation["arguments"], options = arguments?["options"], result = operation["result"]
        harnessID = JSONText(harness)
        prompt = arguments?["prompt"]?.stringValue
        // Display the exact native model options supplied by the caller.
        model = Self.text(options?["model"])
        provider = Self.text(options?["provider"])
        if let mode = Self.text(options?["thinking"]?["mode"]) {
            thinking = mode == "effort" ? Self.text(options?["thinking"]?["effort"]) : mode
        } else { thinking = nil }
        let completed = operation["completedAt"]?.numberValue != nil
        let startedID = Self.text(result?["threadId"])
        if !completed && executionIsActive {
            phase = .dispatching
        } else if completed, operation["isError"]?.boolValue != true,
                  result?["ok"]?.boolValue == true, startedID != nil {
            phase = .started
        } else { phase = .failed }
        threadID = phase == .started ? startedID : nil
        error = phase == .failed ? Self.text(result?["error"]) : nil
    }

    public func sentence(chinese: Bool) -> String {
        switch phase {
        case .dispatching: chinese ? "正在派发任务" : "Dispatching task"
        case .started: chinese ? "Thread 已启动" : "Thread started"
        case .failed: chinese ? "派发失败" : "Dispatch failed"
        }
    }

    /// Keep the real identifier; visual truncation belongs to the single line.
    public var configuration: String { [model, thinking].compactMap { $0 }.joined(separator: " · ") }

    private static func text(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
