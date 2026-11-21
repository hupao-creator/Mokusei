import Foundation
import Testing
import ChiefPluginAPI
@testable import ChiefUI

private struct CollectionCase: Codable {
    let seed: UInt64
    var fixedCells: Int
    var groups: [[Int]]

    init(seed: UInt64) {
        var random = SplitMix64(seed: seed)
        self.seed = seed
        groups = (0..<random.integer(1...2)).map { _ in
            (0..<random.integer(0...10)).map { _ in random.integer(1...2) }
        }
        // Sample both sides of the cutoff as well as views far beyond it.
        let boundaryCells = 15 + Int(seed % 3)
        let eligibleCells = groups.joined().reduce(0, +)
        if seed.isMultiple(of: 2) && eligibleCells <= boundaryCells {
            fixedCells = boundaryCells - eligibleCells
        } else {
            fixedCells = random.integer(0...20)
        }
    }

    func violation() -> String? {
        var displayed = fixedCells + groups.joined().reduce(0, +)
        var budget = NativeOverviewCollectionBudget(expandedCells: displayed)
        var random = SplitMix64(seed: seed)
        for areas in groups {
            let idle = random.integer(0...areas.count)
            let retained = random.integer(0...areas.count)
            let count = budget.memberCount(eligible: areas.map { .init(columns: 1, rows: $0) },
                                           collection: .init(columns: 1, rows: 2), idle: idle, retained: retained)
            // Independently score every legal presentation, including all singles.
            // Prefer least overflow, then the fewest reports behind the collection.
            let options = (0...areas.count).filter { $0 != 1 && (idle < 2 || $0 >= idle) }.compactMap { size -> (overflow: Int, missingBuffer: Int, size: Int, cells: Int)? in
                let cells = displayed - areas.prefix(size).reduce(0, +) + (size == 0 ? 0 : 2)
                if size > 0 && idle < 2 && cells >= displayed { return nil }
                return (max(0, cells - 16), retained >= 2 && areas.prefix(retained).reduce(0, +) > 2 && size < retained ? max(0, cells - 14) : 0, size, cells)
            }
            let best = options.min { ($0.overflow, $0.missingBuffer, $0.size) < ($1.overflow, $1.missingBuffer, $1.size) }!
            guard count == best.size else { return "selected \(count) members, expected \(best.size) at \(displayed) cells" }
            displayed = best.cells
        }
        // Split foreground reading across routes to the same owner, with paused
        // intervals between routes. The oracle only sums generated visible spans.
        let estimate = Double(random.integer(0...300))
        let threshold = max(5, min(45, estimate * 0.25))
        let now = 200_000.0
        let age = 86_400.0 + Double(Int(seed % 3) - 1)
        var evidence = ApplicationCollectionReading()
        var visit = NativeOverviewCollectionVisit(reference: .init(threadID: "report", typeID: "report.document"),
            openedAt: now, estimate: estimate, createdAt: now - age, evidence: &evidence)
        guard evidence.staysCollected == (age >= 86_400) else { return "incorrect unread age boundary" }
        let reading = max(0, threshold + Double(Int((seed / 3) % 3) - 1))
        visit.advance(visible: true, uptime: 0)
        visit.advance(visible: false, uptime: reading / 2)
        visit.advance(visible: true, uptime: 100)
        visit.advance(visible: false, uptime: 100 + reading / 2)
        guard visit.qualified == (reading >= threshold) else { return "foreground threshold or pause mismatch" }
        if visit.qualified { visit.promote(&evidence) }
        visit.close(at: now + 200, evidence: &evidence)
        let persistedIdle = evidence.isIdle(createdAt: 0, now: now + 201)
        guard persistedIdle == (age >= 86_400 && reading < threshold),
              (evidence.lastQualifiedAt != nil) == visit.qualified else { return "incorrect default on return" }
        let next = now + 200 + age
        var revisit = NativeOverviewCollectionVisit(reference: visit.reference, openedAt: next, estimate: estimate,
            createdAt: 0, evidence: &evidence)
        revisit.advance(visible: true, uptime: 500)
        guard !revisit.qualified else { return "unseen revisit qualified" }
        revisit.advance(visible: false, uptime: 501)
        guard revisit.qualified == (age < 86_400) else { return "incorrect short revisit window" }
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
