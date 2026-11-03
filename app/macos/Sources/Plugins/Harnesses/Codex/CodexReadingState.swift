import Foundation
import Observation
import MokuseiCore

/// The reading boundary admits opaque native state off the main actor. Its
/// immutable result is the only value the view can use; cancellation never
/// publishes an obsolete revision over a replacement resource.
@MainActor @Observable
final class CodexReadingState {
    private(set) var result: Result<CodexState, Error>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let decoder = CodexReadingDecoder()

    func load(_ raw: JSONValue, createdAt: Double = 0) async {
        guard !Task.isCancelled else { return }
        let token = UUID()
        generation = token
        let decoded = await decoder.decode(raw, createdAt: createdAt)
        guard !Task.isCancelled, generation == token else { return }
        result = decoded
    }
}

/// Serialize admission within one mounted reader. Rapid stream revisions cancel
/// queued requests before decoding rather than running overlapping detached jobs.
private actor CodexReadingDecoder {
    func decode(_ raw: JSONValue, createdAt: Double) -> Result<CodexState, Error> {
        Result {
            try Task.checkCancellation()
            let state = try CodexState(raw, createdAt: createdAt)
            try Task.checkCancellation()
            return state
        }
    }
}
