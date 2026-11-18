import Foundation
import Testing
import MokuseiPluginAPI
@testable import MokuseiUI

private struct CollectionCase: Codable {
    let seed: UInt64
    var fixedCells: Int
    var groups: [[Int]]

    init(seed: UInt64) {
        var random = SplitMix64(seed: seed)
        self.seed = seed
        fixedCells = random.integer(0...16)
        groups = (0..<random.integer(1...2)).map { _ in
            (0..<random.integer(0...10)).map { _ in random.integer(1...2) }
        }
    }

    func violation() -> String? {
        var displayed = fixedCells + groups.joined().reduce(0, +)
        var budget = NativeOverviewCollectionBudget(expandedCells: displayed)
        for areas in groups {
            let count = budget.memberCount(eligible: areas.map { .init(columns: 1, rows: $0) },
                                           collection: .init(columns: 1, rows: 2))
            // Independently score every legal presentation, including all singles.
            // Prefer least overflow, then the fewest reports behind the collection.
            let options = (0...areas.count).filter { $0 != 1 }.map { size in
                let cells = displayed - areas.prefix(size).reduce(0, +) + (size == 0 ? 0 : 2)
                return (overflow: max(0, cells - 12), size: size, cells: cells)
            }
            let best = options.min { ($0.overflow, $0.size) < ($1.overflow, $1.size) }!
            guard count == best.size else { return "selected \(count) members, expected \(best.size) at \(displayed) cells" }
            displayed = best.cells
        }
        return nil
    }

    func reduced(within seconds: Int) -> Self {
        var best = self
        let deadline = ContinuousClock.now + .seconds(seconds)
        for index in groups.indices {
            for offset in groups[index].indices.reversed() {
                if ContinuousClock.now >= deadline { return best }
                var next = best
                next.groups[index].remove(at: offset)
                if next.violation() != nil { best = next }
            }
        }
        for cells in 0..<best.fixedCells {
            if ContinuousClock.now >= deadline { return best }
            var next = best
            next.fixedCells = cells
            if next.violation() != nil { return next }
        }
        return best
    }
}

@Suite(.serialized)
struct NativeOverviewCollectionProperties {
    @Test func oldestPrefixMinimizesOverflow() throws {
        let budget = try PropertyBudget(defaultCases: 480)
        let replay = try propertyReplay(CollectionCase.self)
        let inputs = replay.map { [$0] } ?? (0..<budget.cases).map { CollectionCase(seed: budget.seed &+ UInt64($0)) }
        for input in inputs {
            if let error = input.violation() {
                try propertyEvidence(input, name: "original.json")
                let reduced = input.reduced(within: budget.shrinkSeconds)
                try propertyEvidence(reduced, name: "reduced.json")
                Issue.record(Comment(rawValue: "PBT-OVERVIEW-COLLECTION seed=\(input.seed) \(error) reduced=\(reduced)"))
                return
            }
        }
        print("PBT PASS PBT-OVERVIEW-COLLECTION seed=\(budget.seed) cases=\(inputs.count) replay=\(replay != nil)")
    }
}
