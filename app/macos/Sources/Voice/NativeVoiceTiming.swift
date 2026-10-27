import Foundation
import MokuseiCore

/// Use the existing opt-in recorder; only fixed metrics and monotonic durations
/// are recorded, with no voice text, SDP, paths or account identifiers.
@MainActor
func measure<T>(_ metric: NativePerformance.Metric, operation: () async throws -> T) async rethrows -> T {
    let span = NativePerformance.begin(metric)
    do {
        let result = try await operation()
        span?.end()
        return result
    } catch {
        span?.end(error is CancellationError ? .cancelled : .failed)
        throw error
    }
}
