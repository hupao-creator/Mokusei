import Foundation
import CoreGraphics

func member(_ id: String) -> NativeOverviewMember { .init(id: id, columns: 1, rows: 1) }
func rect(_ p: NativeOverviewPlacement) -> CGRect {
    .init(x: Double(p.column) * 376, y: Double(p.row) * 216,
          width: Double(p.columns) * 376 - 16, height: Double(p.rows) * 216 - 16)
}
func bounds(_ ps: [NativeOverviewPlacement]) -> NativeOverviewContentRect {
    let b = ps.map(rect).reduce(CGRect.null) { $0.union($1) }
    return .init(left: b.minX, top: b.minY, width: b.width, height: b.height)
}
func plain<T: Encodable>(_ value: T) -> Any {
    try! JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
}
var records = [[String: Any]]()
@discardableResult func run(_ name: String, _ members: [NativeOverviewMember],
                            previous: [NativeOverviewPlacement] = [], width: Double = 1420,
                            height: Double = 900) throws -> [NativeOverviewPlacement] {
    let viewport = NativeOverviewViewport(width: width, height: height, toolbarBottom: width <= 620 ? 120 : 60)
    let region = NativeOverviewCameraGeometry.framingRegion(viewport)
    let minimum = NativeOverviewCameraGeometry.minimumScale(in: viewport)
    let fitting = CGSize(width: region.width / minimum, height: region.height / minimum)
    let preferred = CGSize(width: region.width / max(1, minimum), height: region.height / max(1, minimum))
    let start = ProcessInfo.processInfo.systemUptime
    let result = try NativeOverviewLayout.plan(previous: previous, next: members, fittingSize: fitting /*PREFERRED*/)
    let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
    precondition(Set(result.placements.map(\.member)) == Set(members))
    for (i, p) in result.placements.enumerated() {
        for q in result.placements.dropFirst(i + 1) { precondition(!rect(p).intersects(rect(q))) }
    }
    let content = bounds(result.placements)
    let before = previous.isEmpty ? NativeOverviewTransform.identity : NativeOverviewCameraGeometry.fit(bounds(previous), viewport: viewport)
    var after = NativeOverviewCameraGeometry.fit(content, viewport: viewport)
    // Matches ordinary zero-world-travel Canvas revisions; explicit scene/resize
    // actions use default framing. Native integration covers the actual lifecycle.
    /*READING_POSITION*/
    let clip = CGRect(x: region.left, y: region.top, width: region.width, height: region.height)
    func screen(_ p: NativeOverviewPlacement, _ t: NativeOverviewTransform) -> CGRect {
        let r = rect(p)
        return CGRect(x: r.minX * t.scale + t.x, y: r.minY * t.scale + t.y,
                      width: r.width * t.scale, height: r.height * t.scale)
    }
    let old = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
    let distances = result.placements.compactMap { p -> Double? in
        guard let q = old[p.id] else { return nil }
        let a = screen(q, before), b = screen(p, after)
        return hypot(a.minX - b.minX, a.minY - b.minY)
    }
    let visibleArea = result.placements.reduce(0.0) { sum, p in
        let intersection = screen(p, after).intersection(clip)
        return sum + (intersection.isNull ? 0 : intersection.width * intersection.height)
    }
    records.append(["scenario": name, "viewport": ["width": width, "height": height, "toolbarBottom": viewport.toolbarBottom], "elapsedMs": elapsed,
                    "result": plain(result), "beforeCamera": plain(before), "afterCamera": plain(after),
                    "visibleFill": visibleArea / (region.width * region.height),
                    "fullCards": result.placements.filter { clip.insetBy(dx: -0.001, dy: -0.001).contains(screen($0, after)) }.count,
                    "screenMoved": distances.filter { $0 > 1 }.count, "screenMax": distances.max() ?? 0,
                    "screenTotal": distances.reduce(0, +)])
    return result.placements
}
for (width, height) in [(600.0, 750.0), (900, 750), (1420, 900), (1920, 1080), (2560, 1440)] {
    try run("three-\(Int(width))", (0..<3).map { member("c\($0)") }, width: width, height: height)
}
let six = (0..<6).map { member("c\($0)") }
let initial = try run("six", six)
try run("six-repeat", six, previous: initial)
try run("six-reversed", six.reversed(), previous: initial)
try run("six-to-seven", six + [member("c6")], previous: initial)
let nine = (0..<9).map { NativeOverviewPlacement(member: member("n\($0)"), column: $0 % 3, row: $0 / 3) }
let removed = try run("delete-center", nine.filter { $0.id != "n4" }.map(\.member), previous: nine)
try run("refill-center", removed.map(\.member) + [member("new")], previous: removed)
for n in [16, 30, 100, 500] { try run("fresh-\(n)", (0..<n).map { member(String(format: "c%04d", $0)) }) }
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]))
