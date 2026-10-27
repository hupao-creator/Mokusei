import MokuseiCore

/// One entry per mounted manifest/row; failed admission is cached as well.
/// Raw content, rather than catalog revision, owns content-subscription identity.
@MainActor
final class CodexStateCache {
    private var raw: JSONValue?
    private var createdAt: Double?
    private var result: Result<CodexState, Error>?
    private(set) var decodeCount = 0

    func decode(_ value: JSONValue, createdAt: Double = 0) -> Result<CodexState, Error> {
        if raw == value, self.createdAt == createdAt, let result { return result }
        let next = Result { try CodexState(value, createdAt: createdAt) }
        decodeCount += 1
        raw = value; self.createdAt = createdAt; result = next
        return next
    }
}
