import Foundation

/// Opt-in presentation policy. The Host groups after filtering and never creates
/// a catalog record or changes a member's identity, tags or execution relations.
public struct ApplicationOverviewCollectionPolicy: Sendable {
    public let closedBefore: TimeInterval
    public let footprint: HarnessOverviewFootprint
    public init(closedBefore: TimeInterval, footprint: HarnessOverviewFootprint) {
        precondition(closedBefore.isFinite && closedBefore > 0)
        precondition((1...3).contains(footprint.columns) && (1...100).contains(footprint.rows))
        self.closedBefore = closedBefore; self.footprint = footprint
    }
    public func includes(lastClosed: Date?, now: Date) -> Bool {
        guard let lastClosed else { return false }
        // Compare in the persisted Unix-second domain. Converting a saved epoch
        // through Date's reference epoch before subtraction can turn an exact
        // boundary into a tiny positive duration after a JSON round trip.
        return now.timeIntervalSince1970 > lastClosed.timeIntervalSince1970 + closedBefore
    }
}
