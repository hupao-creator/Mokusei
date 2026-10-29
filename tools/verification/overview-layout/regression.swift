import Foundation
import CoreGraphics

typealias ReplayMember = NativeOverviewMember
typealias ReplayPlacement = NativeOverviewPlacement
typealias ReplayResult = NativeOverviewLayoutResult

func member(_ id: String, _ columns: Int = 1, _ rows: Int = 1) -> ReplayMember {
    .init(id: id, columns: columns, rows: rows)
}
func placement(_ id: String, _ columns: Int, _ rows: Int, _ column: Int, _ row: Int) -> ReplayPlacement {
    .init(member: member(id, columns, rows), column: column, row: row)
}
func rect(_ p: ReplayPlacement) -> CGRect {
    .init(x: Double(p.column) * 376, y: Double(p.row) * 216,
          width: Double(p.columns) * 376 - 16, height: Double(p.rows) * 216 - 16)
}
func validate(_ result: ReplayResult, previous: [ReplayPlacement], next: [ReplayMember]) {
    precondition(Set(result.placements.map(\.member)) == Set(next))
    let old = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
    let shifted = result.placements.filter {
        guard let before = old[$0.id] else { return false }
        return before.column != $0.column || before.row != $0.row
    }.map(\.id)
    precondition(Set(shifted) == Set(result.shiftedIDs))
    for (index, p) in result.placements.enumerated() {
        for q in result.placements.dropFirst(index + 1) { precondition(!rect(p).intersects(rect(q))) }
    }
    guard !result.requiresRepack else { return }
    precondition(Set(result.moveOrder) == Set(result.shiftedIDs))
    precondition(result.moveOrder.count == result.shiftedIDs.count)
    let targets = Dictionary(uniqueKeysWithValues: result.placements.map { ($0.id, $0) })
    // Production shrinks before moving, removes exits, and grows/adopts entrants
    // afterwards. Sample that published move order against independent rectangles.
    var frames = Dictionary(uniqueKeysWithValues: previous.compactMap { p -> (String, CGRect)? in
        guard let target = targets[p.id] else { return nil }
        let shrunk = ReplayPlacement(member: member(p.id, min(p.columns, target.columns), min(p.rows, target.rows)),
                               column: p.column, row: p.row)
        return (p.id, rect(shrunk))
    })
    for id in result.moveOrder {
        let start = frames[id]!, target = targets[id]!
        let end = CGRect(origin: rect(target).origin, size: start.size)
        for sample in 0...100 {
            let t = Double(sample) / 100
            let frame = CGRect(x: start.minX + (end.minX - start.minX) * t,
                               y: start.minY + (end.minY - start.minY) * t,
                               width: end.width, height: end.height)
            for (other, obstacle) in frames where other != id {
                precondition(!frame.intersects(obstacle), "\(id) crosses \(other)")
            }
        }
        frames[id] = end
    }
}

let viewport = NativeOverviewViewport(width: 1420, height: 1100, toolbarBottom: 60)
let region = NativeOverviewCameraGeometry.framingRegion(viewport)
let scale = NativeOverviewCameraGeometry.minimumScale(in: viewport)
// The same extents and planner options as the ordinary production Canvas path.
let fitting = CGSize(width: region.width / scale, height: region.height / scale)
let preferred = CGSize(width: region.width / max(1, scale), height: region.height / max(1, scale))
var records = [[String: Any]]()
@discardableResult func run(_ name: String, previous: [ReplayPlacement], next: [ReplayMember],
                           fittingSize: CGSize? = fitting, preferredSize: CGSize = preferred, preservePositions: Bool = true,
                           budget: Int = 2_000_000) throws -> ReplayResult {
    let start = ProcessInfo.processInfo.systemUptime
    let result = try NativeOverviewLayout.plan(previous: previous, next: next, fittingSize: fittingSize,
        preferredSize: preservePositions ? preferredSize : nil, preservePositions: preservePositions, maxSearchSteps: budget)
    validate(result, previous: previous, next: next)
    let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result))
    records.append(["scenario": name, "result": plain, "elapsedMs": (ProcessInfo.processInfo.systemUptime - start) * 1000])
    return result
}

// Begin with a solver-produced 3×4 scene, then attach sidecards as adjacent
// placeholder cards leave. No history position is invented for the deletion path.
let ids = ["00-a", "01-b", "02-c", "03-d", "04-e", "05-e-slot",
           "06-f", "07-h", "08-h-slot", "09-x", "10-g", "11-g-slot"]
let fresh = try run("history-fresh", previous: [], next: ids.map { member($0) })
let wideIDs = Set(["04-e", "07-h", "10-g"])
let expandedMembers = ids.filter { !$0.hasSuffix("-slot") }.map { member($0, wideIDs.contains($0) ? 2 : 1) }
let expanded = try run("history-expand", previous: fresh.placements, next: expandedMembers)
let seven = expandedMembers.filter { $0.id != "07-h" && $0.id != "09-x" }
let deleted = try run("delete-wide-and-edge", previous: expanded.placements, next: seven)
try run("delete-repeat", previous: deleted.placements, next: seven.reversed())
try run("delete-refill", previous: deleted.placements, next: expandedMembers)

// A necessary notch before shrinking: ABC / DEE / FF. / .GG (10/12).
// F losing its sidecard creates exactly the screenshot's 9/12 footprint.
let beforeShrink = [placement("a", 1, 1, 0, 0), placement("b", 1, 1, 1, 0), placement("c", 1, 1, 2, 0),
                    placement("d", 1, 1, 0, 1), placement("e", 2, 1, 1, 1),
                    placement("f", 2, 1, 0, 2), placement("g", 2, 1, 1, 3)]
let retained = try run("necessary-wide-vacancy", previous: beforeShrink, next: beforeShrink.map(\.member))
let shrunkMembers = beforeShrink.map { member($0.id, $0.id == "f" ? 1 : $0.columns, $0.rows) }
let shrunk = try run("shrink-wide", previous: retained.placements, next: shrunkMembers)
try run("shrink-repeat", previous: shrunk.placements, next: shrunkMembers)
let screenshot = beforeShrink.map { ReplayPlacement(member: member($0.id, $0.id == "f" ? 1 : $0.columns, $0.rows), column: $0.column, row: $0.row) }
try run("screenshot-same-footprints", previous: screenshot, next: shrunkMembers)
let offset = screenshot.map { ReplayPlacement(member: $0.member, column: $0.column + 7, row: $0.row + 11) }
try run("screenshot-offset", previous: offset, next: shrunkMembers)
let transpose = screenshot.map {
    ReplayPlacement(member: member($0.id, $0.rows, $0.columns), column: $0.row, row: $0.column)
}
let wideViewport = NativeOverviewViewport(width: 1920, height: 1100, toolbarBottom: 60)
let wideRegion = NativeOverviewCameraGeometry.framingRegion(wideViewport)
let wideScale = NativeOverviewCameraGeometry.minimumScale(in: wideViewport)
try run("screenshot-transposed", previous: transpose, next: transpose.map(\.member),
    fittingSize: .init(width: wideRegion.width / wideScale, height: wideRegion.height / wideScale),
    preferredSize: .init(width: wideRegion.width / max(1, wideScale), height: wideRegion.height / max(1, wideScale)))
try run("filter-compact", previous: screenshot, next: shrunkMembers, preservePositions: false)
try run("no-viewport-compact", previous: screenshot, next: shrunkMembers, fittingSize: nil)
try run("probe-budget-exhausted", previous: screenshot, next: shrunkMembers, budget: 1)
try run("compact-budget-exhausted", previous: screenshot, next: shrunkMembers, budget: 200)

// A deleted center is necessary vacancy: neither 2×3 nor 3×2 can hold eight cells.
let nine = (0..<9).map { placement("n\($0)", 1, 1, $0 % 3, $0 / 3) }
let center = try run("necessary-center-vacancy", previous: nine, next: nine.filter { $0.id != "n4" }.map(\.member))
try run("center-refill", previous: center.placements, next: nine.map(\.member))
let insufficient = try run("insufficient-capacity", previous: screenshot, next: shrunkMembers, fittingSize: .init(width: 736, height: 416))
try run("capacity-recovery", previous: insufficient.placements, next: shrunkMembers)
let squares = [placement("square-a", 2, 2, 0, 0), placement("square-b", 2, 2, 2, 0), placement("square-c", 2, 2, 0, 2)]
let squareViewport = NativeOverviewViewport(width: 1920, height: 1200, toolbarBottom: 60)
let squareRegion = NativeOverviewCameraGeometry.framingRegion(squareViewport)
let squareScale = NativeOverviewCameraGeometry.minimumScale(in: squareViewport)
try run("necessary-square-vacancy", previous: squares, next: squares.map(\.member),
    fittingSize: .init(width: squareRegion.width / squareScale, height: squareRegion.height / squareScale),
    preferredSize: .init(width: squareRegion.width / max(1, squareScale), height: squareRegion.height / max(1, squareScale)))

// Existing hard boundaries: conflicting growth, legal repack fallback, and a
// fitting witness retained when shape optimization is cut short.
let growth = [placement("card-0", 1, 1, 0, 0), placement("card-1", 1, 1, 1, 0),
              placement("card-2", 1, 1, 0, 2), placement("card-3", 2, 1, 0, 1),
              placement("card-4", 2, 1, 0, 3), placement("card-5", 1, 1, 1, 2)]
let grown = growth.map { member($0.id, $0.columns, $0.id == "card-4" ? 2 : $0.rows) }
try run("growth-repack", previous: growth, next: grown, fittingSize: nil)
let mixed = [member("large", 2, 2), member("small-a"), member("small-b"), member("wide-a", 2), member("wide-b", 2)]
let full = try run("mixed-full", previous: [], next: mixed, fittingSize: .init(width: 1500, height: 700))
try run("mixed-truncated", previous: [], next: mixed, fittingSize: .init(width: 1500, height: 700), budget: full.work.steps - 1)
for count in [100, 500] {
    let members = (0..<count).map { member(String(format: "large-%04d", $0)) }
    let large = try run("large-\(count)", previous: [], next: members)
    try run("large-repeat-\(count)", previous: large.placements, next: members)
}
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]))
