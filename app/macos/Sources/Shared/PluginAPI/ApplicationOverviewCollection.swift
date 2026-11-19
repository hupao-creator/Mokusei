import Foundation

/// Opt-in presentation policy. The Host groups after filtering and never creates
/// a catalog record or changes a member's identity, tags or execution relations.
public struct ApplicationOverviewCollectionPolicy: Sendable {
    public let footprint: HarnessOverviewFootprint
    /// The renderer supplies its own complete backdrop instead of the Host's flat shell.
    public let providesCardSurface: Bool
    public init(footprint: HarnessOverviewFootprint, providesCardSurface: Bool = false) {
        precondition((1...3).contains(footprint.columns) && (1...100).contains(footprint.rows))
        self.footprint = footprint
        self.providesCardSurface = providesCardSurface
    }
}
