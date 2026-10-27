import MokuseiCore
import MokuseiPluginAPI

/// Public audit data only. A tool result acknowledges delivery; its arguments
/// retain the exact text. Identity includes the owner and execution, not text.
public struct NativeMokuTalkMessage: Equatable, Sendable, Identifiable {
    public static let maximumCodePoints = 160

    public let id: JSONText
    public let text: String
    public let dispatch: NativeMokuDispatch?

    public init(id: JSONText, text: String, dispatch: NativeMokuDispatch? = nil) {
        self.id = id; self.text = text; self.dispatch = dispatch
    }

    public static func latest(in thread: HarnessThread?) -> Self? {
        guard let thread, thread.moku == true, let execution = thread.observation.latestExecution else { return nil }
        for item in (thread.transcript?.arrayValue ?? []).reversed() where item["executionId"] == .string(execution.executionID) {
            if let message = project(item, thread: thread, execution: execution) { return message }
        }
        return nil
    }

    /// A selected sheet follows its exact operation across later messages. The
    /// owner/harness/execution tuple prevents a replacement thread borrowing it.
    public static func dispatch(id: JSONText, in thread: HarnessThread?) -> Self? {
        guard let thread, thread.moku == true, let execution = thread.observation.latestExecution else { return nil }
        for item in (thread.transcript?.arrayValue ?? []).reversed() {
            if let message = project(item, thread: thread, execution: execution), message.id == id, message.dispatch != nil {
                return message
            }
        }
        return nil
    }

    private static func project(_ item: JSONValue, thread: HarnessThread, execution: PublicExecution) -> Self? {
        guard item["type"]?.stringValue == "tool-operation",
              case .string(let operationID) = item["id"], !operationID.codeUnits.isEmpty,
              case .string(let executionID) = item["executionId"] else { return nil }
        let key = [thread.id, thread.harnessID, executionID, operationID].flatMap {
            Array("\($0.codeUnits.count):".utf16) + $0.codeUnits
        }
        let active = executionID == execution.executionID && (execution.status == .running || execution.status == .waitingForUser)
        if let dispatch = NativeMokuDispatch(operation: item, executionIsActive: active) {
            return Self(id: JSONText(codeUnits: key), text: dispatch.sentence(chinese: true), dispatch: dispatch)
        }
        guard item["name"]?.stringValue == "talk", item["completedAt"]?.numberValue != nil, item["isError"]?.boolValue != true,
              case .string(let text) = item["arguments"]?["text"], text.string.unicodeScalars.count <= maximumCodePoints,
              text.codeUnits.contains(where: { !whitespace($0) }) else { return nil }
        return Self(id: JSONText(codeUnits: key), text: text.string)
    }

    private static func whitespace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x0009...0x000D, 0x0020, 0x0085, 0x00A0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
        default: false
        }
    }
}

/// Window-owned latest-only delivery. Hiding a presented message consumes it;
/// a new message received while input/another surface owns the Dock waits.
/// Mounting, reconnecting and replaying an older audit item cannot resurrect it.
public struct NativeMokuTalkState: Equatable {
    public private(set) var message: NativeMokuTalkMessage?
    public private(set) var presented = false
    public private(set) var deadline: ContinuousClock.Instant?
    private var latest: NativeMokuTalkMessage?
    private var seen: Set<JSONText> = []
    private var order: [JSONText] = []

    public init() {}

    public mutating func receive(_ next: NativeMokuTalkMessage?) {
        guard latest != next else { return }
        // A result updates the same audit operation in place. Preserve its
        // presentation lease and never resurrect an explicitly dismissed call.
        if let next, latest?.id == next.id {
            latest = next
            if message?.id == next.id { message = next }
            return
        }
        latest = next
        presented = false
        deadline = nil
        guard let next, !seen.contains(next.id) else { message = nil; return }
        seen.insert(next.id); order.append(next.id)
        if order.count > 256 { seen.remove(order.removeFirst()) }
        message = next
    }

    public mutating func setPresented(_ value: Bool, now: ContinuousClock.Instant = .now) {
        if !value, presented { dismiss() }
        presented = value && message != nil
        // Start only on actual presentation. Same-operation result updates and
        // repeated view callbacks must retain the original lease.
        if presented, deadline == nil { deadline = now.advanced(by: .seconds(60)) }
    }

    public mutating func expire(id: JSONText, deadline: ContinuousClock.Instant, now: ContinuousClock.Instant = .now) {
        guard message?.id == id, self.deadline == deadline, now >= deadline else { return }
        dismiss()
    }

    public mutating func dismiss() { message = nil; presented = false; deadline = nil }
}
