import Foundation
import Observation
import MokuseiCore
import MokuseiPluginAPI
import SwiftUI

/// A mounted reader owns publication; its worker retains only the last exact input.
@MainActor @Observable
public final class HarnessReadingState<State: Sendable> {
    private var published: (input: HarnessThreadInput, result: Result<State, Error>, environment: HarnessReadingEnvironment?)?

    /// The previous snapshot remains mounted while another payload is prepared.
    /// Never carry it across thread identities. Input and row metadata advance
    /// only when their matching result is published.
    public func snapshot(input: HarnessThreadInput) -> (HarnessThreadInput, Result<State, Error>, HarnessReadingEnvironment?)? {
        guard let published, published.input.thread.id == input.thread.id else { return nil }
        return (published.input, published.result, published.environment)
    }
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let worker: HarnessReadingWorker<State>

    public init(decode: @escaping @Sendable (JSONValue) throws -> State) {
        worker = HarnessReadingWorker(decode: decode)
    }

    public func load(input: HarnessThreadInput, raw: JSONValue, environment: HarnessReadingEnvironment? = nil) async {
        guard !Task.isCancelled else { return }
        let token = UUID()
        generation = token
        let decoded = await worker.decode(raw)
        guard !Task.isCancelled, generation == token else { return }
        published = (input, decoded, environment)
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

/// Includes both the data payload and the thread snapshot it will accompany.
public struct HarnessReadingRequest: Hashable {
    public let input: HarnessThreadInput
    public let raw: JSONValue
    public let presence: ThreadExecutionPresence?
    public let hasLoader: Bool
    public init(input: HarnessThreadInput, raw: JSONValue, presence: ThreadExecutionPresence? = nil, hasLoader: Bool = false) {
        self.input = input; self.raw = raw; self.presence = presence; self.hasLoader = hasLoader
    }
}

/// Deferred row metadata must advance with the state decoded from its envelope.
@MainActor public struct HarnessReadingEnvironment {
    public let presence: ThreadExecutionPresence
    public let loader: (@MainActor (JSONText) -> AnyView)?
    public init(presence: ThreadExecutionPresence, loader: (@MainActor (JSONText) -> AnyView)?) {
        self.presence = presence; self.loader = loader
    }
}
