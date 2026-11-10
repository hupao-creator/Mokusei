import Foundation

/// Opt-in presentation policy. The Host groups after filtering and never creates
/// a catalog record or changes a member's identity, tags or execution relations.
public struct ApplicationOverviewCollectionPolicy: Sendable {
    public let openedBefore: TimeInterval
    public let footprint: HarnessOverviewFootprint
    public init(openedBefore: TimeInterval, footprint: HarnessOverviewFootprint) {
        precondition(openedBefore.isFinite && openedBefore > 0)
        precondition((1...3).contains(footprint.columns) && (1...100).contains(footprint.rows))
        self.openedBefore = openedBefore; self.footprint = footprint
    }
    public func includes(lastOpened: Date?, now: Date) -> Bool {
        guard let lastOpened else { return false }
        return now.timeIntervalSince(lastOpened) > openedBefore
    }
}
