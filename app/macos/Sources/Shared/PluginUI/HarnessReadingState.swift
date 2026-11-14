import Foundation
import Observation
import MokuseiCore

/// A mounted reader owns publication; its worker retains only the last exact input.
@MainActor @Observable
public final class HarnessReadingState<State: Sendable> {
    private var result: Result<State, Error>?
    private var source: JSONValue?

    public func result(for raw: JSONValue) -> Result<State, Error>? {
        source == raw ? result : nil
    }
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let worker: HarnessReadingWorker<State>

    public init(decode: @escaping @Sendable (JSONValue) throws -> State) {
        worker = HarnessReadingWorker(decode: decode)
    }

    public func load(_ raw: JSONValue) async {
        guard !Task.isCancelled else { return }
        let token = UUID()
        generation = token
        let decoded = await worker.decode(raw)
        guard !Task.isCancelled, generation == token else { return }
        source = raw
        result = decoded
    }
}

private actor HarnessReadingWorker<State: Sendable> {
    private let build: @Sendable (JSONValue) throws -> State
    private var raw: JSONValue?
    private var cached: Result<State, Error>?

    init(decode: @escaping @Sendable (JSONValue) throws -> State) { build = decode }

    func decode(_ input: JSONValue) -> Result<State, Error> {
        Result {
            try Task.checkCancellation()
            if raw == input, let cached { return try cached.get() }
            let result = Result { try build(input) }
            try Task.checkCancellation()
            raw = input; cached = result
            return try result.get()
        }
    }
}
