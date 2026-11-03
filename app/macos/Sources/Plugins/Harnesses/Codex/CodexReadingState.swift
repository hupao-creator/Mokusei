import Foundation
import Observation
import MokuseiCore

/// Only immutable admission results are cached, never actions, resources or
/// navigation state. Cancellation fences delivery to this mounted reader.
@MainActor @Observable
final class CodexReadingState {
    private(set) var result: Result<CodexState, Error>?
    @ObservationIgnored private var generation = UUID()

    func load(_ raw: JSONValue, createdAt: Double = 0) async {
        guard !Task.isCancelled else { return }
        let token = UUID()
        generation = token
        let decoded = await CodexReadingDecoder.shared.decode(raw, createdAt: createdAt)
        guard !Task.isCancelled, generation == token else { return }
        result = decoded
    }
}

/// Serialize admission across readers. The complete opaque value (including
/// exact UTF-16 identity), not a catalog revision or execution ID, owns reuse.
/// Superseded queued requests check cancellation before doing any work.
private actor CodexReadingDecoder {
    static let shared = CodexReadingDecoder()
    private struct Key: Hashable { let raw: JSONValue; let createdAt: Double }
    private struct Entry { let state: CodexState; let cost: Int; var access: UInt64 }
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private var cost = 0

    func decode(_ raw: JSONValue, createdAt: Double) -> Result<CodexState, Error> {
        Result {
            try Task.checkCancellation()
            let key = Key(raw: raw, createdAt: createdAt)
            clock &+= 1
            if var entry = entries[key] {
                entry.access = clock; entries[key] = entry
                return entry.state
            }
            let state = try CodexState(raw, createdAt: createdAt)
            try Task.checkCancellation()
            // Account for both opaque JSON and typed arrays. Oversize values
            // remain readable but do not displace the entire working set.
            let size = raw.readingRetentionCost * 3
            if size <= 8 * 1024 * 1024 {
                while entries.count >= 16 || cost + size > 8 * 1024 * 1024 {
                    guard let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key,
                          let removed = entries.removeValue(forKey: oldest) else { break }
                    cost -= removed.cost
                }
                entries[key] = Entry(state: state, cost: size, access: clock); cost += size
            }
            return state
        }
    }
}
