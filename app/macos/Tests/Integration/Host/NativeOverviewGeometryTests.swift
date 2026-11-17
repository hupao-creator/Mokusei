import Foundation
import Testing
import MokuseiPluginAPI
@testable import MokuseiUI

/// Independent layout contract. Every oracle below is computed from the input
/// and the published output; no expectation calls the production solver or its
/// fit helper.
private struct LayoutCase: Codable, Equatable {
    var seed: UInt64
    var members: [NativeOverviewMember]
    var usable: NativeOverviewContentRect
    var scaleCap: Double?
}

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func integer(_ range: ClosedRange<Int>) -> Int {
        Int.random(in: range, using: &self)
    }

    mutating func double(_ range: ClosedRange<Double>) -> Double {
        Double.random(in: range, using: &self)
    }
}

private let tolerance = 1e-9
private let metrics = NativeOverviewGridMetrics.standard

private func frame(of placement: NativeOverviewPlacement) -> CGRect {
    CGRect(x: Double(placement.column) * metrics.columnPitch,
           y: Double(placement.row) * metrics.rowPitch,
           width: metrics.width(columns: placement.columns),
           height: metrics.height(rows: placement.rows))
}

private func generate(seed: UInt64, count: Int? = nil) -> LayoutCase {
    var random = SplitMix64(seed: seed)
    let cardCount = count ?? random.integer(0...18)
    var members = [NativeOverviewMember]()
    for index in 0..<cardCount {
        members.append(.init(id: "card-\(index)",
                             columns: random.integer(1...3),
                             rows: random.integer(1...2)))
    }
    let width = random.double(240...2600)
    let height = random.double(240...1600)
    let usable = NativeOverviewContentRect(left: random.double(-400...400),
                                           top: random.double(-200...200),
                                           width: width, height: height)
    let cap: Double? = random.integer(0...2) == 0 ? nil : random.double(1...2.6)
    return LayoutCase(seed: seed, members: members, usable: usable, scaleCap: cap)
}

private func violations(_ input: LayoutCase) -> [String] {
    let result: NativeOverviewGeometry
    do {
        result = try NativeOverviewLayout.solve(
            members: input.members,
            usableViewport: input.usable,
            policy: .init(metrics: metrics, scaleCap: input.scaleCap))
    } catch {
        return ["solve threw: \(error)"]
    }
    var issues = [String]()
    let expectedIDs = input.members.map(\.id)
    let actualIDs = result.placements.map(\.id)
    if actualIDs != expectedIDs { issues.append("placements are not in product order") }
    if Set(actualIDs) != Set(expectedIDs) { issues.append("membership mismatch") }
    if actualIDs.sorted() != expectedIDs.sorted() { issues.append("duplicate or missing identity") }
    for placement in result.placements {
        guard let member = input.members.first(where: { $0.id == placement.id }) else {
            issues.append("unknown member \(placement.id)"); continue
        }
        if placement.member != member { issues.append("stale size for \(placement.id)") }
        let cardFrame = frame(of: placement)
        if ![cardFrame.minX, cardFrame.minY, cardFrame.width, cardFrame.height].allSatisfy(\.isFinite) {
            issues.append("non-finite frame for \(placement.id)")
        }
        if cardFrame.width <= 0 || cardFrame.height <= 0 { issues.append("non-positive frame for \(placement.id)") }
    }
    // Any two cards must have the declared world gap on at least one axis.
    for (index, a) in result.placements.enumerated() {
        for b in result.placements.dropFirst(index + 1) {
            let horizontal = frame(of: a).maxX <= frame(of: b).minX + tolerance
                || frame(of: b).maxX <= frame(of: a).minX + tolerance
            let vertical = frame(of: a).maxY <= frame(of: b).minY + tolerance
                || frame(of: b).maxY <= frame(of: a).minY + tolerance
            if !horizontal && !vertical { issues.append("overlap \(a.id)/\(b.id)") }
            if horizontal {
                let gap = max(frame(of: b).minX - frame(of: a).maxX, frame(of: a).minX - frame(of: b).maxX)
                if gap + tolerance < metrics.gap { issues.append("short horizontal gap \(a.id)/\(b.id)") }
            }
            if vertical {
                let gap = max(frame(of: b).minY - frame(of: a).maxY, frame(of: a).minY - frame(of: b).maxY)
                if gap + tolerance < metrics.gap { issues.append("short vertical gap \(a.id)/\(b.id)") }
            }
        }
    }
    // Declared bounds are exactly the card-frame union.
    if !result.placements.isEmpty {
        let frames = result.placements.map { frame(of: $0) }
        let left = frames.map(\.minX).min()!, top = frames.map(\.minY).min()!
        let right = frames.map(\.maxX).max()!, bottom = frames.map(\.maxY).max()!
        if abs(result.bounds.left - left) > tolerance || abs(result.bounds.top - top) > tolerance
            || abs(result.bounds.width - (right - left)) > tolerance
            || abs(result.bounds.height - (bottom - top)) > tolerance {
            issues.append("bounds do not equal frame union")
        }
        if result.bounds.width <= 0 || result.bounds.height <= 0 { issues.append("non-positive bounds") }
    }
    if input.members.isEmpty {
        if result.automaticCamera != nil { issues.append("empty collection produced a camera") }
        return issues
    }
    guard input.usable.width > 0, input.usable.height > 0 else {
        if result.automaticCamera != nil { issues.append("zero viewport produced a camera") }
        return issues
    }
    guard let camera = result.automaticCamera else {
        issues.append("valid nonempty input has no automatic camera")
        return issues
    }
    if ![camera.scale, camera.x, camera.y].allSatisfy(\.isFinite) { issues.append("non-finite camera") }
    if camera.scale <= 0 { issues.append("non-positive scale") }
    let fit = min(input.usable.width / result.bounds.width, input.usable.height / result.bounds.height)
    let expectedScale = max(1, min(input.scaleCap ?? fit, fit))
    if abs(camera.scale - expectedScale) > 1e-7 { issues.append("scale is not bounded framing") }
    var screenUnion = CGRect.null
    for placement in result.placements {
        let cardFrame = frame(of: placement)
        let screen = CGRect(x: camera.x + cardFrame.minX * camera.scale,
                            y: camera.y + cardFrame.minY * camera.scale,
                            width: cardFrame.width * camera.scale,
                            height: cardFrame.height * camera.scale)
        screenUnion = screenUnion.union(screen)
        let allowed = CGRect(x: input.usable.left, y: input.usable.top,
                             width: input.usable.width, height: input.usable.height)
        if fit >= 1 && !allowed.insetBy(dx: -1e-6, dy: -1e-6).contains(screen) {
            issues.append("card \(placement.id) is outside the usable viewport")
        }
    }
    let centerX = input.usable.left + input.usable.width / 2
    let centerY = input.usable.top + input.usable.height / 2
    if abs(screenUnion.midX - centerX) > 1e-6 || abs(screenUnion.midY - centerY) > 1e-6 {
        issues.append("collection is not centered")
    }
    // Independent regular-grid lower bound: max card size in every cell.
    let maxColumns = input.members.map(\.columns).max()!
    let maxRows = input.members.map(\.rows).max()!
    let cellWidth = metrics.width(columns: maxColumns)
    let cellHeight = metrics.height(rows: maxRows)
    var baseline = 0.0
    for columns in 1...input.members.count {
        let rows = (input.members.count + columns - 1) / columns
        let width = Double(columns) * cellWidth + Double(columns - 1) * metrics.gap
        let height = Double(rows) * cellHeight + Double(rows - 1) * metrics.gap
        baseline = max(baseline, min(input.usable.width / width, input.usable.height / height))
    }
    let productionFit = min(input.usable.width / result.bounds.width,
                            input.usable.height / result.bounds.height)
    if productionFit + 1e-9 < baseline { issues.append("worse than the regular-grid baseline") }
    return issues
}

private func shrink(_ input: LayoutCase, while fails: (LayoutCase) -> Bool) -> LayoutCase {
    var best = input
    var changed = true
    while changed {
        changed = false
        var candidates = [LayoutCase]()
        for index in best.members.indices {
            var removed = best
            removed.members.remove(at: index)
            candidates.append(removed)
            if best.members[index].columns > 1 {
                var narrow = best
                narrow.members[index] = .init(id: narrow.members[index].id,
                                              columns: narrow.members[index].columns - 1,
                                              rows: narrow.members[index].rows)
                candidates.append(narrow)
            }
            if best.members[index].rows > 1 {
                var short = best
                short.members[index] = .init(id: short.members[index].id,
                                             columns: short.members[index].columns,
                                             rows: short.members[index].rows - 1)
                candidates.append(short)
            }
        }
        if best.usable.width > 1 {
            var narrow = best; narrow.usable.width = max(1, best.usable.width / 2); candidates.append(narrow)
        }
        if best.usable.height > 1 {
            var short = best; short.usable.height = max(1, best.usable.height / 2); candidates.append(short)
        }
        for candidate in candidates where fails(candidate) {
            best = candidate
            changed = true
            break
        }
    }
    return best
}

@MainActor
@Suite(.serializedNative, .serialized)
struct NativeOverviewGeometryTests {
    @Test func emptyAndDegenerateInputsHaveExplicitResults() throws {
        let empty = try NativeOverviewLayout.solve(
            members: [], usableViewport: .init(left: 0, top: 0, width: 1200, height: 800))
        #expect(empty.placements.isEmpty)
        #expect(empty.automaticCamera == nil)
        #expect(empty.bounds == .empty)

        let member = NativeOverviewMember(id: "only", columns: 1, rows: 1)
        let zero = try NativeOverviewLayout.solve(
            members: [member], usableViewport: .init(left: 0, top: 0, width: 0, height: 800))
        #expect(zero.placements == [.init(member: member, column: 0, row: 0)])
        #expect(zero.automaticCamera == nil)

        #expect(throws: NativeOverviewLayoutError.self) {
            try NativeOverviewLayout.solve(members: [.init(id: "", columns: 1, rows: 1)],
                                           usableViewport: .init(left: 0, top: 0, width: 100, height: 100))
        }
        #expect(throws: NativeOverviewLayoutError.self) {
            try NativeOverviewLayout.solve(members: [.init(id: "x", columns: 0, rows: 1)],
                                           usableViewport: .init(left: 0, top: 0, width: 100, height: 100))
        }
        #expect(throws: NativeOverviewLayoutError.self) {
            try NativeOverviewLayout.solve(members: [member, member],
                                           usableViewport: .init(left: 0, top: 0, width: 100, height: 100))
        }
        #expect(throws: NativeOverviewLayoutError.self) {
            try NativeOverviewLayout.solve(members: [member],
                                           usableViewport: .init(left: 0, top: 0, width: 100, height: 100),
                                           policy: .init(scaleCap: 0))
        }
    }


    @Test func largeMixedInputStaysLegalOn4KAndUltrawideViewports() throws {
        let members = (0..<1500).map { index in
            NativeOverviewMember(id: "large-\(index)", columns: 1 + index % 3, rows: 1 + index % 2)
        }
        for viewport in [NativeOverviewContentRect(left: 0, top: 0, width: 3840, height: 2160),
                         NativeOverviewContentRect(left: 80, top: 120, width: 5120, height: 1440)] {
            let result = try NativeOverviewLayout.solve(members: members, usableViewport: viewport)
            #expect(result.placements.count == members.count)
            #expect(Set(result.placements.map(\.id)) == Set(members.map(\.id)))
            #expect(result.bounds.width.isFinite && result.bounds.height.isFinite)
            let camera = try #require(result.automaticCamera)
            let raw = min(viewport.width / result.bounds.width, viewport.height / result.bounds.height)
            #expect(abs(camera.scale - max(1, min(NativeOverviewGeometryPolicy.standard.scaleCap ?? raw, raw))) < 1e-7)
            let maxColumns = members.map(\.columns).max()!
            let maxRows = members.map(\.rows).max()!
            let cellWidth = metrics.width(columns: maxColumns)
            let cellHeight = metrics.height(rows: maxRows)
            var baseline = 0.0
            for columns in 1...members.count {
                let rows = (members.count + columns - 1) / columns
                let width = Double(columns) * cellWidth + Double(columns - 1) * metrics.gap
                let height = Double(rows) * cellHeight + Double(rows - 1) * metrics.gap
                baseline = max(baseline, min(viewport.width / width, viewport.height / height))
            }
            let productionFit = min(viewport.width / result.bounds.width,
                                    viewport.height / result.bounds.height)
            #expect(productionFit + 1e-9 >= baseline)
        }
    }


    @Test func maximumCardFootprintCentersAtLogicalSizeWithBothToolbarClearances() throws {
        let members = [NativeOverviewMember(id: "wide-agent",
                                            columns: HarnessOverviewCapacity.maximumColumns,
                                            rows: 2)]
        for toolbar in [NativeOverviewViewportDefaults.toolbarBottom,
                        OverviewTagMetrics.narrowToolbarClearance] {
            let viewport = NativeOverviewViewport(width: 860, height: 600, toolbarBottom: toolbar)
            let usable = NativeOverviewCameraGeometry.framingRegion(viewport)
            let result = try NativeOverviewLayout.solve(members: members, usableViewport: usable)
            let camera = try #require(result.automaticCamera)
            #expect(camera.scale <= NativeOverviewGeometryPolicy.standard.scaleCap! + 1e-9)
            var screen = CGRect.null
            for placement in result.placements {
                let card = frame(of: placement)
                screen = screen.union(CGRect(x: camera.x + card.minX * camera.scale,
                                             y: camera.y + card.minY * camera.scale,
                                             width: card.width * camera.scale,
                                             height: card.height * camera.scale))
            }
            let allowed = CGRect(x: usable.left, y: usable.top, width: usable.width, height: usable.height)
            #expect(camera.scale == 1)
            #expect(abs(screen.midX - allowed.midX) < 1e-6)
            #expect(abs(screen.midY - allowed.midY) < 1e-6)
        }
    }

    @Test func invalidViewportValuesThrowATypedError() {
        let member = NativeOverviewMember(id: "only", columns: 1, rows: 1)
        let values = [Double.nan, .infinity, -.infinity]
        for value in values {
            let viewport = NativeOverviewContentRect(left: value, top: 0, width: 100, height: 100)
            #expect(throws: NativeOverviewLayoutError.self) {
                try NativeOverviewLayout.solve(members: [member], usableViewport: viewport)
            }
        }
        for viewport in [NativeOverviewContentRect(left: 0, top: 0, width: -1, height: 100),
                         NativeOverviewContentRect(left: 0, top: 0, width: 100, height: -1)] {
            #expect(throws: NativeOverviewLayoutError.self) {
                try NativeOverviewLayout.solve(members: [member], usableViewport: viewport)
            }
        }
    }

    @Test func tinyViewportChoosesTheHigherFitLayout() throws {
        let members = [NativeOverviewMember(id: "a", columns: 1, rows: 1),
                       .init(id: "b", columns: 1, rows: 1)]
        let viewport = NativeOverviewContentRect(left: 0, top: 0, width: 1, height: 1)
        let result = try NativeOverviewLayout.solve(members: members, usableViewport: viewport)
        #expect(result.bounds.columns == 1 && result.bounds.rows == 2)
        let camera = try #require(result.automaticCamera)
        let expected = 1.0
        #expect(abs(camera.scale - expected) < 1e-12)
    }

    @Test func absurdSpansThrowInsteadOfTrapping() {
        let huge = 9_007_199_254_740_000
        var members = [NativeOverviewMember(id: "huge", columns: huge, rows: huge)]
        members += (1..<100).map { NativeOverviewMember(id: "small-\($0)", columns: 1, rows: 1) }
        #expect(throws: NativeOverviewLayoutError.self) {
            try NativeOverviewLayout.solve(
                members: members,
                usableViewport: .init(left: 0, top: 0, width: 100, height: 100))
        }
    }

    @Test func shelfCandidateRangesUseThePackingAxis() throws {
        let cases: [(members: [NativeOverviewMember], usable: NativeOverviewContentRect,
                     witnessColumns: Int, witnessRows: Int)] = [
            // A 3x2 card beside two stacked 2x1 cards is a legal 5x2 witness.
            ([.init(id: "a", columns: 3, rows: 2), .init(id: "b", columns: 2, rows: 1),
              .init(id: "c", columns: 2, rows: 1)],
             .init(left: 0, top: 0, width: 1680, height: 500), 5, 2),
            // Two 3x2 cards above a 3x1, 3x1, 2x1 row form a legal 8x3 witness.
            ([.init(id: "a", columns: 3, rows: 2), .init(id: "b", columns: 3, rows: 1),
              .init(id: "c", columns: 3, rows: 2), .init(id: "d", columns: 3, rows: 1),
              .init(id: "e", columns: 2, rows: 1)],
             .init(left: 0, top: 0, width: 2496, height: 624), 8, 3),
        ]
        for input in cases {
            let result = try NativeOverviewLayout.solve(members: input.members, usableViewport: input.usable)
            let fit = min(input.usable.width / result.bounds.width, input.usable.height / result.bounds.height)
            let witnessFit = min(input.usable.width / metrics.width(columns: input.witnessColumns),
                                 input.usable.height / metrics.height(rows: input.witnessRows))
            #expect(fit + tolerance >= witnessFit)
            #expect(violations(.init(seed: 0, members: input.members, usable: input.usable, scaleCap: 1.7)).isEmpty)
        }
    }

    @Test func viewportTranslationMovesOnlyTheScreenResult() throws {
        let members = [NativeOverviewMember(id: "a", columns: 1, rows: 1),
                       .init(id: "b", columns: 2, rows: 1),
                       .init(id: "c", columns: 1, rows: 2)]
        let base = NativeOverviewContentRect(left: 64, top: 96, width: 1100, height: 640)
        let shifted = NativeOverviewContentRect(left: base.left + 137, top: base.top - 53,
                                                width: base.width, height: base.height)
        let first = try NativeOverviewLayout.solve(members: members, usableViewport: base)
        let second = try NativeOverviewLayout.solve(members: members, usableViewport: shifted)
        #expect(first.placements == second.placements)
        #expect(first.bounds == second.bounds)
        let firstCamera = try #require(first.automaticCamera)
        let secondCamera = try #require(second.automaticCamera)
        #expect(abs(firstCamera.scale - secondCamera.scale) < tolerance)
        #expect(abs((secondCamera.x - firstCamera.x) - 137) < 1e-7)
        #expect(abs((secondCamera.y - firstCamera.y) + 53) < 1e-7)
    }

    @Test func productOrderAndDeterminismAreExplicit() throws {
        let members = [NativeOverviewMember(id: "a", columns: 2, rows: 1),
                       .init(id: "b", columns: 1, rows: 1),
                       .init(id: "c", columns: 1, rows: 2)]
        let viewport = NativeOverviewContentRect(left: 0, top: 0, width: 900, height: 700)
        let first = try NativeOverviewLayout.solve(members: members, usableViewport: viewport)
        let second = try NativeOverviewLayout.solve(members: members, usableViewport: viewport)
        #expect(first == second)
        #expect(first.placements.map(\.id) == members.map(\.id))
        let reversed = try NativeOverviewLayout.solve(members: Array(members.reversed()), usableViewport: viewport)
        #expect(Set(reversed.placements.map(\.id)) == Set(members.map(\.id)))
        #expect(violations(.init(seed: 0, members: Array(members.reversed()), usable: viewport, scaleCap: 1.7)).isEmpty)
    }

    @Test(arguments: 0..<40)
    func generatedLayoutsSatisfyTheContract(seed: Int) throws {
        var failures = [String]()
        for offset in 0..<12 {
            let input = generate(seed: UInt64(seed * 12 + offset))
            let issues = violations(input)
            if !issues.isEmpty {
                let reduced = shrink(input) { !violations($0).isEmpty }
                let json = String(data: try JSONEncoder().encode(reduced), encoding: .utf8) ?? "<unencodable>"
                failures.append("seed \(reduced.seed): \(issues.joined(separator: "; "))\ninput=\(json)")
                break
            }
        }
        if !failures.isEmpty {
            Issue.record(Comment(rawValue: failures.joined(separator: "\n")))
        }
    }

    /// Exhaustively compare the selected arrangement with the best of all
    /// regular-grid candidates for tiny inputs. This quantifies the gap but does
    /// not claim global optimal packing for mixed rectangles.
    @Test(arguments: 0..<30)
    func smallInputsStayWithinTheGridQualityBound(seed: Int) throws {
        for offset in 0..<8 {
            let input = generate(seed: UInt64(seed * 8 + offset), count: (seed + offset) % 7)
            if !violations(input).isEmpty {
                Issue.record(Comment(rawValue: "seed \(input.seed) violated the contract"))
                return
            }
        }
    }
}
