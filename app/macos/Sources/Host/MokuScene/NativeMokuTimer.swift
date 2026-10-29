import AppKit
import Observation
import MokuseiCore
import MokuseiPluginAPI

/// A completed communication operation, never a scheduled reminder.
public struct NativeMokuTimerMessage: Equatable, Identifiable, Sendable {
    public let id: JSONText
    public let text: String

    static func completed(in thread: HarnessThread?) -> [Self] {
        guard let thread, thread.moku == true else { return [] }
        return (thread.transcript?.arrayValue ?? []).compactMap { item in
            guard item["type"]?.stringValue == "tool-operation", item["name"]?.stringValue == "timer",
                  case .string(let operation) = item["id"], !operation.codeUnits.isEmpty,
                  case .string(let execution) = item["executionId"], !execution.codeUnits.isEmpty,
                  item["completedAt"]?.numberValue != nil, item["isError"]?.boolValue != true,
                  item["result"]?["ok"]?.boolValue == true,
                  let text = item["arguments"]?["text"]?.stringValue,
                  text.unicodeScalars.count <= NativeMokuTalkMessage.maximumCodePoints,
                  !text.contains("\0"),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\u{FEFF}\u{0085}"))).isEmpty
            else { return nil }
            // Length prefixes prevent collisions even when native IDs contain separators.
            let key = [thread.id, thread.harnessID, execution, operation].flatMap {
                Array("\($0.codeUnits.count):".utf16) + $0.codeUnits
            }
            return Self(id: JSONText(codeUnits: key), text: text)
        }
    }
}

@MainActor public protocol NativeMokuTimerPlaying: AnyObject {
    func startLoop() throws
    func stop()
}

/// Separate from voice media ownership; never changes the device/system volume.
@MainActor public final class NativeMokuTimerSound: NativeMokuTimerPlaying {
    private var sound: NSSound?
    public init() {}
    public func startLoop() throws {
        guard sound == nil else { return }
        guard let next = NSSound(contentsOfFile: "/System/Library/Sounds/Glass.aiff", byReference: false) else {
            throw RuntimeError("TIMER_AUDIO_UNAVAILABLE", "Timer bell could not be loaded")
        }
        next.loops = true
        guard next.play() else { throw RuntimeError("TIMER_AUDIO_UNAVAILABLE", "Timer bell could not be played") }
        sound = next
    }
    public func stop() { sound?.stop(); sound = nil }
}

/// Workspace lifetime, independent of view mounting, navigation and connection.
/// Only UI acknowledgment advances the FIFO. Shutdown stops audio without
/// pretending the user acknowledged anything. No acknowledgment is persisted.
@MainActor @Observable public final class NativeMokuTimerController {
    public private(set) var pending: [NativeMokuTimerMessage] = []
    public private(set) var audioError: String?
    public var current: NativeMokuTimerMessage? { pending.first }
    @ObservationIgnored private let player: any NativeMokuTimerPlaying
    @ObservationIgnored private var seen = Set<JSONText>()
    @ObservationIgnored private var initialized = false
    @ObservationIgnored private var stopped = false

    public init(player: any NativeMokuTimerPlaying = NativeMokuTimerSound()) { self.player = player }

    isolated deinit { player.stop() }

    public func receive(_ thread: HarnessThread?) {
        guard !stopped else { return }
        let messages = NativeMokuTimerMessage.completed(in: thread)
        // Initial hydration is reading history, not a new communication. Mark
        // completed items only: an in-flight call may still finish after startup.
        guard initialized else {
            seen.formUnion(messages.map(\.id))
            initialized = true
            return
        }
        let wasEmpty = pending.isEmpty
        for message in messages where seen.insert(message.id).inserted { pending.append(message) }
        if wasEmpty, !pending.isEmpty { startAudio() }
    }

    public func acknowledge(id: JSONText) {
        guard !stopped, current?.id == id else { return }
        pending.removeFirst()
        if pending.isEmpty { player.stop(); audioError = nil }
    }

    public func retryAudio() {
        guard !stopped, current != nil, audioError != nil else { return }
        startAudio()
    }

    private func startAudio() {
        do { try player.startLoop(); audioError = nil }
        catch { audioError = error.localizedDescription }
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        player.stop()
    }
}
