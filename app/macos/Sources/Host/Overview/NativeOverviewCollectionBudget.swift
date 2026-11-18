import MokuseiPluginAPI

/// One budget per complete, ungrouped filter projection. Each type spends only
/// the excess left by earlier types, in the order their first candidate appears.
struct NativeOverviewCollectionBudget {
    static let targetCells = 4 * 3
    private var excess: Int

    init(expandedCells: Int) { excess = expandedCells - Self.targetCells }

    mutating func memberCount(eligible: some Sequence<HarnessOverviewFootprint>,
                              collection: HarnessOverviewFootprint) -> Int {
        guard excess > 0 else { return 0 }
        var saved = -(collection.columns * collection.rows)
        var count = 0
        for footprint in eligible {
            saved += footprint.columns * footprint.rows
            count += 1
            if count >= 2 && saved >= excess { break }
        }
        guard count >= 2, saved > 0 else { return 0 }
        excess -= saved
        return count
    }
}
