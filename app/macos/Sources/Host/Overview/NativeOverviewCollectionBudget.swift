import ChiefPluginAPI

/// One budget per complete, ungrouped filter projection. Each type spends only
/// the excess left by earlier types, in the order their first candidate appears.
struct NativeOverviewCollectionBudget {
    static let targetCells = 4 * 4
    private var excess: Int

    init(expandedCells: Int) { excess = expandedCells - Self.targetCells }

    mutating func memberCount(eligible: some Collection<HarnessOverviewFootprint>,
                              collection: HarnessOverviewFootprint, idle: Int = 0, retained: Int = 0) -> Int {
        let collectionCells = collection.columns * collection.rows
        let retainGroup = retained >= 2 && eligible.prefix(retained).reduce(0) { $0 + $1.columns * $1.rows } > collectionCells
        let minimum = idle >= 2 ? idle : 0
        // Releasing an existing pressure group needs two spare cells. Once
        // its previously collected prefix is exhausted, the ordinary cap applies.
        func fits(_ count: Int, saving: Int) -> Bool {
            count >= minimum && excess - saving <= (retainGroup && count < retained ? -2 : 0)
        }
        if fits(0, saving: 0) { return 0 }
        var saving = -collectionCells
        var count = 0
        for footprint in eligible {
            saving += footprint.columns * footprint.rows
            count += 1
            if count >= 2 && (saving > 0 || minimum >= 2) && fits(count, saving: saving) { break }
        }
        guard count >= 2, saving > 0 || minimum >= 2 else { return 0 }
        excess -= saving
        return count
    }
}
