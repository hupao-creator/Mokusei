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
private let metrics = NativeOverviewGridMetrics(columnWidth: 320, rowHeight: 196, gap: 16)

private func frame(of placement: NativeOverviewPlacement) -> CGRect {
    CGRect(x: Double(placement.column) * metrics.columnPitch,
           y: Double(placement.row) * metrics.rowPitch,
           width: metrics.width(columns: placement.columns),
           height: metrics.height(rows: placement.rows))
}

private func generate(seed: UInt64) -> LayoutCase {
    var random = SplitMix64(seed: seed)
    var members = [NativeOverviewMember]()
    if seed.isMultiple(of: 4) {
        // A six-tile rectangle with a known optimum, in different units and orders.
        let w = random.integer(1...3), h = random.integer(1...2)
        let spans = [(2 * w, h), (w, 2 * h), (w, h), (w, h)].shuffled(using: &random)
        members = spans.enumerated().map { index, span in
            .init(id: "card-\(index)", columns: span.0, rows: span.1)
        }
    } else {
        for index in 0..<random.integer(0...18) {
            members.append(.init(id: "card-\(index)",
                                 columns: random.integer(1...3), rows: random.integer(1...2)))
        }
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
            policy: .init(metrics: .standard, scaleCap: input.scaleCap))
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
    if input.members.count == 4, let w = input.members.map(\.columns).min(), let h = input.members.map(\.rows).min(),
       input.members.filter({ $0.columns == w && $0.rows == h }).count == 2,
       input.members.contains(where: { $0.columns == 2 * w && $0.rows == h }),
       input.members.contains(where: { $0.columns == w && $0.rows == 2 * h }) {
        // Both six-cell rectangles admit a tiling. Any wider or taller strip
        // still needs at least two rows and two columns for the two long cards.
        let landscape = min(input.usable.width / metrics.width(columns: 3 * w),
                            input.usable.height / metrics.height(rows: 2 * h))
        let portrait = min(input.usable.width / metrics.width(columns: 2 * w),
                           input.usable.height / metrics.height(rows: 3 * h))
        let fullRectangle = (result.bounds.columns, result.bounds.rows) == (3 * w, 2 * h)
            || (result.bounds.columns, result.bounds.rows) == (2 * w, 3 * h)
        if !fullRectangle || fit + tolerance < max(landscape, portrait) {
            issues.append("mixed four-card tiling wastes space or misses the better orientation")
        }
    }
    return issues
}

private func shrink(_ input: LayoutCase, seconds: Int, while fails: (LayoutCase) -> Bool) -> LayoutCase {
    var best = input
    var changed = true
    let deadline = ContinuousClock.now + .seconds(seconds)
    while changed && ContinuousClock.now < deadline {
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
        for candidate in candidates {
            if ContinuousClock.now >= deadline { return best }
            guard fails(candidate) else { continue }
            best = candidate
            changed = true
            break
        }
    }
    return best
}

// PBT-OVERVIEW-GEOMETRY: Sources/Host/Overview/README.md
@Suite(.serialized)
struct NativeOverviewGeometryProperties {
    @Test func generatedLayoutsSatisfyTheContract() throws {
        let budget = try PropertyBudget(defaultCases: 480)
        let replay = try propertyReplay(LayoutCase.self)
        let inputs = replay.map { [$0] } ?? (0..<budget.cases).map { generate(seed: budget.seed &+ UInt64($0)) }
        for input in inputs {
            let issues = violations(input)
            if let first = issues.first {
                try propertyEvidence(input, name: "original.json")
                print("PBT FAIL PBT-OVERVIEW-GEOMETRY seed=\(input.seed) issues=\(issues)")
                let reduced = shrink(input, seconds: budget.shrinkSeconds) { violations($0).contains(first) }
                try propertyEvidence(reduced, name: "reduced.json")
                let json = String(decoding: try JSONEncoder().encode(reduced), as: UTF8.self)
                Issue.record(Comment(rawValue: "PBT-OVERVIEW-GEOMETRY seed=\(input.seed) issues=\(issues) reduced=\(json)"))
                return
            }
        }
        print("PBT PASS PBT-OVERVIEW-GEOMETRY seed=\(budget.seed) cases=\(inputs.count) replay=\(replay != nil)")
    }
}
