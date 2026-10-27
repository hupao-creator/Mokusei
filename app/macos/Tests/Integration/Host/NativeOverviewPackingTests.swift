import Foundation
import Testing
@testable import MokuseiUI

struct NativeOverviewPackingTests {
    private func placement(_ id: String, _ columns: Int, _ rows: Int, _ column: Int, _ row: Int) -> NativeOverviewPlacement {
        .init(member: .init(id: id, columns: columns, rows: rows), column: column, row: row)
    }

    private var staggeredWideCards: [NativeOverviewPlacement] {
        // ABC / DD. / .EE / FFG: the two vacancies open onto opposite edges.
        [placement("A", 1, 1, 0, 0), placement("B", 1, 1, 1, 0), placement("C", 1, 1, 2, 0),
         placement("D", 2, 1, 0, 1), placement("E", 2, 1, 1, 2), placement("F", 2, 1, 0, 3),
         placement("G", 1, 1, 2, 3)]
    }

    private var reportsBesideTallCards: [NativeOverviewPlacement] {
        // .AA / RAA / BBS / BB.: perimeter alone cannot distinguish this from
        // a compact outline; the opposite-corner vacancies must join together.
        [placement("A", 2, 2, 1, 0), placement("B", 2, 2, 0, 2),
         placement("R", 1, 1, 0, 1), placement("S", 1, 1, 2, 2)]
    }

    private var mixedTallWideAndReportCards: [NativeOverviewPlacement] {
        // AAB / AAC / DD. / .EF: a later screenshot mixes all three footprints.
        [placement("A", 2, 2, 0, 0), placement("B", 1, 1, 2, 0), placement("C", 1, 1, 2, 1),
         placement("D", 2, 1, 0, 2), placement("E", 1, 1, 1, 3), placement("F", 1, 1, 2, 3)]
    }

    private var screenshotCases: [[NativeOverviewPlacement]] {
        [staggeredWideCards, reportsBesideTallCards, mixedTallWideAndReportCards]
    }

    private func expectCompact(_ result: NativeOverviewLayoutResult,
                               members: [NativeOverviewMember]) throws {
        #expect(Set(result.placements.map(\.member)) == Set(members))
        #expect(result.bounds.columns == 3)
        #expect(result.bounds.rows == 4)
        var occupied = Set<Int>()
        for p in result.placements {
            for row in p.row..<(p.row + p.rows) {
                for column in p.column..<(p.column + p.columns) {
                    let cell = (row - result.bounds.row) * 3 + column - result.bounds.column
                    #expect(occupied.insert(cell).inserted, "Cards must not overlap")
                }
            }
        }
        #expect(occupied.count == 10)
        let empty = (0..<12).filter { !occupied.contains($0) }
        try #require(empty.count == 2)
        #expect(abs(empty[0] % 3 - empty[1] % 3) + abs(empty[0] / 3 - empty[1] / 3) == 1,
                "Unused cells must gather into one contiguous edge region")
        for row in 0..<4 {
            let columns = (0..<3).filter { occupied.contains(row * 3 + $0) }
            #expect(columns.count == (try #require(columns.last)) - (try #require(columns.first)) + 1)
        }
        for column in 0..<3 {
            let rows = (0..<4).filter { occupied.contains($0 * 3 + column) }
            #expect(rows.count == (try #require(rows.last)) - (try #require(rows.first)) + 1,
                    "No notch may split a column between occupied cells")
        }
    }

    /// Exercise the published sequential move order using actual card rectangles.
    private func expectClearMoves(_ result: NativeOverviewLayoutResult,
                                  previous: [NativeOverviewPlacement]) throws {
        func rect(_ p: NativeOverviewPlacement) -> CGRect {
            CGRect(x: Double(p.column) * 376, y: Double(p.row) * 216,
                   width: Double(p.columns) * 376 - 16, height: Double(p.rows) * 216 - 16)
        }
        var frames = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, rect($0)) })
        #expect(Set(result.moveOrder) == Set(result.shiftedIDs))
        #expect(result.moveOrder.count == result.shiftedIDs.count)
        for id in result.moveOrder {
            let start = try #require(frames[id])
            let end = rect(try #require(result.placements.first { $0.id == id }))
            for sample in 0...100 {
                let t = Double(sample) / 100
                let frame = CGRect(x: start.minX + (end.minX - start.minX) * t,
                                   y: start.minY + (end.minY - start.minY) * t,
                                   width: end.width, height: end.height)
                for (other, obstacle) in frames where other != id {
                    #expect(!frame.intersects(obstacle), "\(id) crosses \(other)")
                }
            }
            frames[id] = end
        }
    }

    @Test(arguments: [0, 1, 2], [0, 7])
    func repairsScreenshotGapsAndThenKeepsPositions(example: Int, offset: Int) throws {
        let previous = screenshotCases[example].map {
            NativeOverviewPlacement(member: $0.member, column: $0.column + offset, row: $0.row + offset)
        }
        let members = previous.map(\.member)
        let result = try NativeOverviewLayout.plan(previous: previous, next: members)
        try expectCompact(result, members: members)
        try expectClearMoves(result, previous: previous)
        #expect(result.totalShiftDistance > 0)
        #expect(!result.distanceOptimal)
        if example == 2 {
            #expect(result.shiftedIDs == ["D"], "Only the wide card needs to move in the third screenshot")
            let wide = try #require(result.placements.first { $0.id == "D" })
            #expect(wide.column == offset + 1 && wide.row == offset + 2)
        }
        let repeated = try NativeOverviewLayout.plan(previous: result.placements, next: members.reversed())
        #expect(repeated.placements == result.placements)
        #expect(repeated.totalShiftDistance == 0)
        #expect(repeated.distanceOptimal)
    }

    @Test(arguments: [0, 1, 2])
    func freshScenesKeepTheirCompactLayout(example: Int) throws {
        let members = screenshotCases[example].map(\.member)
        let result = try NativeOverviewLayout.plan(previous: [], next: members)
        try expectCompact(result, members: members)
        let retained = try NativeOverviewLayout.plan(previous: result.placements, next: members)
        #expect(retained.placements == result.placements)
        #expect(retained.totalShiftDistance == 0)
    }

    @Test func boundedSearchReturnsOnlyCompactFeasibleResults() throws {
        let previous = staggeredWideCards
        let members = previous.map(\.member)
        let full = try NativeOverviewLayout.plan(previous: previous, next: members)
        let budget = try #require(full.work.firstFeasibleStep)
        let limited = try NativeOverviewLayout.plan(previous: previous, next: members, maxSearchSteps: budget)
        try expectCompact(limited, members: members)
        try expectClearMoves(limited, previous: previous)
        #expect(!limited.searchComplete)
        #expect(limited.work.steps <= budget)
        #expect(throws: NativeOverviewLayoutError.searchLimit) {
            try NativeOverviewLayout.plan(previous: previous, next: members, maxSearchSteps: 1)
        }
    }

    @Test func sixCardGrowthKeepsLegalGeometryWhenStraightMoveSearchIsExhausted() throws {
        let previous = [placement("card-0", 1, 1, 0, 0), placement("card-1", 1, 1, 1, 0),
                        placement("card-2", 1, 1, 0, 2), placement("card-3", 2, 1, 0, 1),
                        placement("card-4", 2, 1, 0, 3), placement("card-5", 1, 1, 1, 2)]
        let members = previous.map {
            NativeOverviewMember(id: $0.id, columns: $0.columns, rows: $0.id == "card-4" ? 2 : $0.rows)
        }
        let result = try NativeOverviewLayout.plan(previous: previous, next: members)
        #expect(result.requiresRepack)
        #expect(!result.searchComplete)
        #expect(Set(result.placements.map(\.member)) == Set(members))
        for (index, a) in result.placements.enumerated() {
            for b in result.placements.dropFirst(index + 1) {
                #expect(a.column + a.columns <= b.column || b.column + b.columns <= a.column ||
                        a.row + a.rows <= b.row || b.row + b.rows <= a.row)
            }
        }
        let repeated = try NativeOverviewLayout.plan(previous: result.placements, next: members)
        #expect(repeated.placements == result.placements)
        #expect(!repeated.requiresRepack)
    }

    @Test func truncatedOptimizationKeepsItsVerifiedReadablePacking() throws {
        let members = [NativeOverviewMember(id: "large", columns: 2, rows: 2),
                       .init(id: "small-a", columns: 1, rows: 1), .init(id: "small-b", columns: 1, rows: 1),
                       .init(id: "wide-a", columns: 2, rows: 1), .init(id: "wide-b", columns: 2, rows: 1)]
        let full = try NativeOverviewLayout.plan(previous: [], next: members, fittingSize: .init(width: 1500, height: 700))
        // The fit witness precedes aspect and movement optimization. Cut off before
        // optimization completes and still require the result to fit both axes.
        let limited = try NativeOverviewLayout.plan(previous: [], next: members,
            fittingSize: .init(width: 1500, height: 700), maxSearchSteps: full.work.steps - 1)
        #expect(!limited.searchComplete)
        #expect(limited.bounds.width <= 1500 && limited.bounds.height <= 700)
        #expect(Set(limited.placements.map(\.member)) == Set(members))
    }
}
