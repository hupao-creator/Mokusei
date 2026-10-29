import Foundation

public struct NativeOverviewMember: Equatable, Hashable, Codable, Sendable {
    public let id: String
    public let columns: Int
    public let rows: Int

    public init(id: String, columns: Int, rows: Int) {
        self.id = id
        self.columns = columns
        self.rows = rows
    }
}

public struct NativeOverviewPlacement: Equatable, Hashable, Codable, Sendable {
    public let member: NativeOverviewMember
    public let column: Int
    public let row: Int
    public var id: String { member.id }
    public var columns: Int { member.columns }
    public var rows: Int { member.rows }

    public init(member: NativeOverviewMember, column: Int, row: Int) {
        self.member = member
        self.column = column
        self.row = row
    }
}

public struct NativeOverviewBounds: Equatable, Codable, Sendable {
    public let column: Int
    public let row: Int
    public let columns: Int
    public let rows: Int
    public let width: Double
    public let height: Double
}

public struct NativeOverviewSearchWork: Equatable, Codable, Sendable {
    public fileprivate(set) var steps = 0
    public fileprivate(set) var candidateSteps = 0
    public fileprivate(set) var firstFeasibleStep: Int?
    public fileprivate(set) var bestStep: Int?
}

public struct NativeOverviewLayoutResult: Equatable, Codable, Sendable {
    public let placements: [NativeOverviewPlacement]
    public let bounds: NativeOverviewBounds
    public let moveOrder: [String]
    public let shiftedIDs: [String]
    public let totalShiftDistance: Double
    public fileprivate(set) var searchComplete: Bool
    /// Geometry is legal, but the bounded search could not certify a sequence
    /// of single straight moves. Retire the old presentation before relocating.
    public fileprivate(set) var requiresRepack = false
    /// Only a zero-travel result certifies the mathematical distance optimum.
    public let distanceOptimal: Bool
    public let aspect: Double?
    public fileprivate(set) var work: NativeOverviewSearchWork
}

public enum NativeOverviewLayoutError: LocalizedError, Equatable {
    case invalidInput(String)
    case searchLimit
    case noLegalLayout

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let message): message
        case .searchLimit: "Layout search budget exceeded; full search did not complete"
        case .noLegalLayout: "No legal layout found"
        }
    }
}

/// Pure, history-aware packing. Natural footprints determine compact, non-dominated
/// bounds; readable viewport fit precedes aspect preference and survivor travel.
/// Incremental readable layouts may retain bounded vacancies. `requiresRepack` distinguishes a legal
/// geometric fallback from a certified collision-free straight move order.
public enum NativeOverviewLayout {
    public static let columnWidth: Double = 360
    public static let rowHeight: Double = 200
    public static let gap: Double = 16

    public static func plan(
        previous: [NativeOverviewPlacement], next: [NativeOverviewMember],
        // World-space extent available at the camera's existing readable floor.
        fittingSize: CGSize? = nil,
        preferredSize: CGSize? = nil,
        preservePositions: Bool = true,
        maxSearchSteps: Int = 2_000_000
    ) throws -> NativeOverviewLayoutResult {
        try OverviewPackingSolver(previous: previous, next: next, fittingSize: fittingSize, preferredSize: preferredSize, preservePositions: preservePositions, budget: maxSearchSteps).run()
    }
}

private typealias Member = NativeOverviewMember
private typealias Placement = NativeOverviewPlacement
private typealias Result = NativeOverviewLayoutResult
private typealias Tick = () throws -> Void
private let maximumSafeInteger = 9_007_199_254_740_991
private let pitchX = NativeOverviewLayout.columnWidth + NativeOverviewLayout.gap
private let pitchY = NativeOverviewLayout.rowHeight + NativeOverviewLayout.gap

private struct Cell: Hashable {
    let column: Int
    let row: Int
}

private struct LayoutContour {
    let size: Cell
    let perimeter: Int
    let vacancyRegions: Int
    let vacancies: [Cell]

    func fits(_ limits: [Cell: LayoutContour]) -> Bool {
        guard let limit = limits[size] else { return false }
        return perimeter <= limit.perimeter && vacancyRegions <= limit.vacancyRegions
    }
}

private struct SearchBox {
    let column: Int
    let row: Int
    let columns: Int
    let rows: Int
    var lowerBound: Double = 0
}

private struct SlotAssignment {
    let placements: [Placement]
    let rowCells: [Int]
}

private struct AssignmentCandidate {
    let forbidden: Set<Int>
    let assignment: SlotAssignment
    let distance: Double
}

private func idPrecedes(_ a: String, _ b: String) -> Bool {
    // JavaScript compares UTF-16 units; preserve its deterministic identity ordering.
    a.utf16.lexicographicallyPrecedes(b.utf16)
}

private func intersects(_ a: Placement, _ b: Placement) -> Bool {
    a.column < b.column + b.columns && b.column < a.column + a.columns &&
    a.row < b.row + b.rows && b.row < a.row + a.rows
}

private func shifted(_ before: Placement?, _ next: Placement) -> Bool {
    guard let before else { return false }
    return before.column != next.column || before.row != next.row
}

// Match the reference runtime's scaled Math.hypot evaluation. Small rounding
// changes can choose a different equal-distance assignment in bounded searches.
private func overviewHypot(_ x: Double, _ y: Double) -> Double {
    let scale = max(abs(x), abs(y))
    if scale == 0 { return 0 }
    let a = abs(x) / scale, b = abs(y) / scale
    return sqrt(a * a + b * b) * scale
}

private func shiftDistance(_ before: Placement?, _ cell: Cell) -> Double {
    guard let before else { return 0 }
    return overviewHypot(Double(cell.column - before.column) * pitchX, Double(cell.row - before.row) * pitchY)
}

private func summarize(_ placements: [Placement], old: [String: Placement], moveOrder: [String] = []) throws -> Result {
    for placement in placements {
        guard placement.column >= 0, placement.row >= 0,
              placement.column <= maximumSafeInteger - placement.columns,
              placement.row <= maximumSafeInteger - placement.rows else {
            throw NativeOverviewLayoutError.invalidInput("Layout coordinate extent cannot be represented")
        }
    }
    let column = placements.map(\.column).min() ?? 0
    let row = placements.map(\.row).min() ?? 0
    let columns = (placements.map { $0.column + $0.columns }.max() ?? 0) - column
    let rows = (placements.map { $0.row + $0.rows }.max() ?? 0) - row
    let width = columns > 0 ? Double(columns) * NativeOverviewLayout.columnWidth + Double(columns - 1) * NativeOverviewLayout.gap : 0
    let height = rows > 0 ? Double(rows) * NativeOverviewLayout.rowHeight + Double(rows - 1) * NativeOverviewLayout.gap : 0
    let aspect = placements.isEmpty ? nil : max(width, height) / min(width, height)
    let sorted = placements.sorted { idPrecedes($0.id, $1.id) }
    let distance = sorted.reduce(0) { $0 + shiftDistance(old[$1.id], Cell(column: $1.column, row: $1.row)) }
    guard width.isFinite, height.isFinite, distance.isFinite,
          placements.isEmpty || (width > 0 && height > 0 && aspect!.isFinite) else {
        throw NativeOverviewLayoutError.invalidInput("Layout pixel bounds or shift distance cannot be represented")
    }
    let shiftedIDs = sorted.filter { shifted(old[$0.id], $0) }.map(\.id)
    return Result(placements: sorted,
                  bounds: NativeOverviewBounds(column: column, row: row, columns: columns, rows: rows, width: width, height: height),
                  moveOrder: moveOrder, shiftedIDs: shiftedIDs, totalShiftDistance: distance,
                  searchComplete: false, distanceOptimal: shiftedIDs.isEmpty, aspect: aspect, work: NativeOverviewSearchWork())
}

private func validate(previous: [Placement], next: [Member], budget: Int) throws {
    guard budget > 0, budget <= maximumSafeInteger else {
        throw NativeOverviewLayoutError.invalidInput("Invalid layout search budget")
    }
    for members in [previous.map(\.member), next] {
        guard Set(members.map(\.id)).count == members.count else {
            throw NativeOverviewLayoutError.invalidInput("Layout member IDs must be unique")
        }
        var columnSum = 0, rowSum = 0, areaSum = 0
        for member in members {
            guard !member.id.isEmpty, member.columns > 0, member.rows > 0,
                  member.columns <= maximumSafeInteger, member.rows <= maximumSafeInteger else {
                throw NativeOverviewLayoutError.invalidInput("Layout footprints must be positive integer grid spans")
            }
            guard member.columns <= maximumSafeInteger - columnSum,
                  member.rows <= maximumSafeInteger - rowSum,
                  member.columns <= (maximumSafeInteger - areaSum) / member.rows else {
                throw NativeOverviewLayoutError.invalidInput("Layout aggregate grid size exceeds safe integers")
            }
            columnSum += member.columns
            rowSum += member.rows
            areaSum += member.columns * member.rows
        }
    }
    for placement in previous {
        guard placement.column >= 0, placement.row >= 0,
              placement.column <= maximumSafeInteger - placement.columns,
              placement.row <= maximumSafeInteger - placement.rows else {
            throw NativeOverviewLayoutError.invalidInput("Layout positions or coordinate extents cannot be represented")
        }
    }
    for (index, placement) in previous.enumerated() {
        if previous.dropFirst(index + 1).contains(where: { intersects(placement, $0) }) {
            throw NativeOverviewLayoutError.invalidInput("Previous layout members must not overlap")
        }
    }
}

/// Flood exterior vacancies; inter-card pixel gaps do not count as grid holes.
private func layoutHoles(_ placements: [Placement], tick: Tick) throws -> [Cell] {
    guard !placements.isEmpty else { return [] }
    let left = placements.map(\.column).min()!
    let top = placements.map(\.row).min()!
    let right = placements.map { $0.column + $0.columns }.max()!
    let bottom = placements.map { $0.row + $0.rows }.max()!
    let width = right - left, height = bottom - top
    var occupied = Set<Cell>(), outside = Set<Cell>(), queue = [Cell]()
    for placement in placements {
        for row in placement.row..<(placement.row + placement.rows) {
            for column in placement.column..<(placement.column + placement.columns) {
                try tick()
                occupied.insert(Cell(column: column - left, row: row - top))
            }
        }
    }
    func add(_ column: Int, _ row: Int) throws {
        try tick()
        guard column >= 0, column < width, row >= 0, row < height else { return }
        let cell = Cell(column: column, row: row)
        if !occupied.contains(cell), outside.insert(cell).inserted { queue.append(cell) }
    }
    for column in 0..<width { try add(column, 0); try add(column, height - 1) }
    for row in 0..<height { try add(0, row); try add(width - 1, row) }
    var index = 0
    while index < queue.count {
        let cell = queue[index]
        try add(cell.column - 1, cell.row); try add(cell.column + 1, cell.row)
        try add(cell.column, cell.row - 1); try add(cell.column, cell.row + 1)
        index += 1
    }
    var holes = [Cell]()
    for row in 0..<height {
        for column in 0..<width {
            try tick()
            let cell = Cell(column: column, row: row)
            if !occupied.contains(cell), !outside.contains(cell) {
                holes.append(Cell(column: column + left, row: row + top))
            }
        }
    }
    return holes
}

/// Enclosed-hole detection alone permits ragged edges and separated corner gaps.
/// Compare the occupied perimeter and vacancy regions *inside* the bounds with
/// natural packing. Connecting vacancies through the exterior would hide them.
private func layoutContour(_ placements: [Placement], tick: Tick) throws -> LayoutContour {
    let left = placements.map(\.column).min() ?? 0
    let top = placements.map(\.row).min() ?? 0
    let right = placements.map { $0.column + $0.columns }.max() ?? 0
    let bottom = placements.map { $0.row + $0.rows }.max() ?? 0
    var occupied = Set<Cell>()
    for placement in placements {
        for row in placement.row..<(placement.row + placement.rows) {
            for column in placement.column..<(placement.column + placement.columns) {
                try tick()
                occupied.insert(Cell(column: column, row: row))
            }
        }
    }
    func neighbors(_ cell: Cell) -> [Cell] {
        [Cell(column: cell.column - 1, row: cell.row), Cell(column: cell.column + 1, row: cell.row),
         Cell(column: cell.column, row: cell.row - 1), Cell(column: cell.column, row: cell.row + 1)]
    }
    var perimeter = 0, vacancies = [Cell]()
    for row in top..<bottom {
        for column in left..<right {
            try tick()
            let cell = Cell(column: column, row: row)
            if occupied.contains(cell) { perimeter += neighbors(cell).filter { !occupied.contains($0) }.count }
            else { vacancies.append(cell) }
        }
    }
    var remaining = Set(vacancies), regions = 0
    for cell in vacancies where remaining.remove(cell) != nil {
        regions += 1
        var queue = [cell], index = 0
        while index < queue.count {
            try tick()
            for neighbor in neighbors(queue[index]) where remaining.remove(neighbor) != nil { queue.append(neighbor) }
            index += 1
        }
    }
    return LayoutContour(size: Cell(column: right - left, row: bottom - top),
                         perimeter: perimeter, vacancyRegions: regions, vacancies: vacancies)
}

private struct PixelRect {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ placement: Placement, columns: Int, rows: Int) {
        x = Double(placement.column) * pitchX
        y = Double(placement.row) * pitchY
        width = Double(columns) * NativeOverviewLayout.columnWidth + Double(columns - 1) * NativeOverviewLayout.gap
        height = Double(rows) * NativeOverviewLayout.rowHeight + Double(rows - 1) * NativeOverviewLayout.gap
    }
}

private struct Survivor {
    let id: String
    let from: PixelRect
    let to: PixelRect
    let moved: Bool
}

private struct StraightMovePlan {
    var moveOrder: [String] = []
    var conflictIDs: [String]?
    var blockedBy: (moving: String, stationary: String)?
}

/// Open time intervals detect collisions throughout the swept rectangle, not sampled frames.
private func crosses(_ from: PixelRect, _ to: PixelRect, _ obstacle: PixelRect) -> Bool {
    var enter = 0.0, leave = 1.0
    for (start, end, minimum, maximum) in [
        (from.x, to.x, obstacle.x - from.width, obstacle.x + obstacle.width),
        (from.y, to.y, obstacle.y - from.height, obstacle.y + obstacle.height)
    ] {
        let velocity = end - start
        if velocity == 0 {
            if start <= minimum || start >= maximum { return false }
        } else {
            let a = (minimum - start) / velocity, b = (maximum - start) / velocity
            enter = max(enter, min(a, b)); leave = min(leave, max(a, b))
        }
    }
    return enter < leave
}

/// Exits disappear and decreasing axes shrink before survivors each move once.
/// Growing axes and entrants follow the move order. Stationary members never move aside.
private func planStraightMoves(_ previous: [Placement], _ next: [Placement], tick: Tick) throws -> StraightMovePlan {
    let old = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
    let survivors = next.compactMap { placement -> Survivor? in
        guard let before = old[placement.id] else { return nil }
        let columns = min(before.columns, placement.columns), rows = min(before.rows, placement.rows)
        return Survivor(id: placement.id,
                        from: PixelRect(before, columns: columns, rows: rows),
                        to: PixelRect(placement, columns: columns, rows: rows), moved: shifted(before, placement))
    }.sorted { idPrecedes($0.id, $1.id) }
    let moving = survivors.filter(\.moved).map(\.id)
    // Keep insertion order, as the JS Map/Set traversal chooses a deterministic order.
    var edges = Dictionary(uniqueKeysWithValues: moving.map { ($0, [String]()) })
    func addEdge(_ before: String, _ after: String) {
        if !edges[before]!.contains(after) { edges[before]!.append(after) }
    }
    for a in survivors where a.moved {
        for b in survivors where a.id != b.id {
            try tick()
            if crosses(a.from, a.to, b.from) {
                if !b.moved { return StraightMovePlan(conflictIDs: [a.id, b.id], blockedBy: (a.id, b.id)) }
                addEdge(b.id, a.id)
            }
            if b.moved, crosses(a.from, a.to, b.to) { addEdge(a.id, b.id) }
        }
    }
    var visited = Set<String>(), stack = [String]()
    func visit(_ id: String) -> [String]? {
        if let start = stack.firstIndex(of: id) { return Array(stack[start...]) }
        guard visited.insert(id).inserted else { return nil }
        stack.append(id)
        for after in edges[id]! { if let cycle = visit(after) { return cycle } }
        stack.removeLast()
        return nil
    }
    for id in moving { if let cycle = visit(id) { return StraightMovePlan(conflictIDs: cycle) } }
    var order = [String]()
    while !edges.isEmpty {
        try tick()
        let ready = moving.first { id in edges[id] != nil && edges.values.allSatisfy { !$0.contains(id) } }!
        order.append(ready)
        edges.removeValue(forKey: ready)
    }
    return StraightMovePlan(moveOrder: order)
}

private func packBox(fixed: [Placement], free: [Member], box: SearchBox, tick: Tick) throws -> [Placement]? {
    try tick()
    var counts = [Cell: Int]()
    for member in free {
        try tick()
        let key = Cell(column: member.columns, row: member.rows)
        let count = (counts[key] ?? 0) + 1
        if Double(count) > Double(box.columns / member.columns) * Double(box.rows / member.rows) { return nil }
        counts[key] = count
    }
    let first = free.first
    if fixed.isEmpty, let first, free.allSatisfy({ $0.columns == first.columns && $0.rows == first.rows }) {
        let columns = box.columns / first.columns
        guard columns > 0, Double(free.count) <= Double(columns) * Double(box.rows / first.rows) else { return nil }
        return try free.enumerated().map { index, member in
            try tick()
            return Placement(member: member, column: box.column + index % columns * member.columns,
                             row: box.row + index / columns * member.rows)
        }
    }
    var placed = fixed
    // Shared dimensions can be snapped into bands for geometry feasibility only.
    let columnStep = fixed.isEmpty && first != nil && free.allSatisfy({ $0.columns == first!.columns }) ? first!.columns : 1
    let rowStep = fixed.isEmpty && first != nil && free.allSatisfy({ $0.rows == first!.rows }) ? first!.rows : 1
    if Double(free.reduce(0, { $0 + $1.columns * $1.rows })) >
        Double(box.columns / columnStep * columnStep) * Double(box.rows / rowStep * rowStep) { return nil }
    func place(_ index: Int) throws -> Bool {
        try tick()
        if index == free.count { return try layoutHoles(placed, tick: tick).isEmpty }
        if free[index].columns == 1 && free[index].rows == 1 {
            let start = placed.count
            var n = index
            var row = box.row
            while row < box.row + box.rows, n < free.count {
                var column = box.column
                while column < box.column + box.columns, n < free.count {
                    try tick()
                    let candidate = Placement(member: free[n], column: column, row: row)
                    if !placed.contains(where: { intersects($0, candidate) }) { placed.append(candidate); n += 1 }
                    column += 1
                }
                row += 1
            }
            if n == free.count, try layoutHoles(placed, tick: tick).isEmpty { return true }
            placed.removeLast(placed.count - start)
        }
        let member = free[index]
        guard member.rows <= box.rows, member.columns <= box.columns else { return false }
        for row in stride(from: box.row, through: box.row + box.rows - member.rows, by: rowStep) {
            for column in stride(from: box.column, through: box.column + box.columns - member.columns, by: columnStep) {
                try tick()
                let candidate = Placement(member: member, column: column, row: row)
                if placed.contains(where: { intersects($0, candidate) }) { continue }
                placed.append(candidate)
                if try place(index + 1) { return true }
                placed.removeLast()
            }
        }
        return false
    }
    return try place(0) ? placed : nil
}

/// Hungarian assignment with exact lexicographic tie-breaking on squared individual travel.
/// Dummy rows represent unoccupied cells, so constraints can require holes to be filled.
private func assignSlots(_ members: [Member], cells: [Cell], old: [String: Placement], tick: Tick,
                         forbidden: Set<Int> = [], slotMembers: [Member]? = nil) throws -> SlotAssignment? {
    guard cells.count >= members.count else { return nil }
    let n = cells.count, m = cells.count
    var costs = [[Double]]()
    var costScale = 1.0
    for row in 0..<n {
        var values = [Double]()
        for (column, cell) in cells.enumerated() {
            try tick()
            let cost = forbidden.contains(row * m + column) ? Double.infinity :
                (row < members.count ? shiftDistance(old[members[row].id], cell) : 0)
            values.append(cost)
            if cost.isFinite { costScale = max(costScale, cost) }
        }
        costs.append(values)
    }
    var u = [Double](repeating: 0, count: n + 1), v = [Double](repeating: 0, count: m + 1)
    var u2 = u, v2 = v
    var match = [Int](repeating: 0, count: m + 1), way = match
    for i in 1..<(n + 1) {
        match[0] = i
        var column = 0
        var minimum = [Double](repeating: .infinity, count: m + 1), minimum2 = minimum
        var used = [Bool](repeating: false, count: m + 1)
        repeat {
            used[column] = true
            let row = match[column]
            var delta = Double.infinity, delta2 = Double.infinity, nextColumn = 0
            for j in 1..<(m + 1) where !used[j] {
                try tick()
                let cost = costs[row - 1][j - 1]
                let reduced = cost - u[row] - v[j]
                let normalized = cost / costScale
                let reduced2 = normalized * normalized - u2[row] - v2[j]
                if reduced < minimum[j] || (reduced == minimum[j] && reduced2 < minimum2[j]) {
                    minimum[j] = reduced; minimum2[j] = reduced2; way[j] = column
                }
                if minimum[j] < delta || (minimum[j] == delta && minimum2[j] < delta2) {
                    delta = minimum[j]; delta2 = minimum2[j]; nextColumn = j
                }
            }
            guard delta.isFinite else { return nil }
            for j in 0...m {
                if used[j] {
                    u[match[j]] += delta; v[j] -= delta
                    u2[match[j]] += delta2; v2[j] -= delta2
                } else { minimum[j] -= delta; minimum2[j] -= delta2 }
            }
            column = nextColumn
        } while match[column] != 0
        repeat {
            let before = way[column]; match[column] = match[before]; column = before
        } while column != 0
    }
    var rowCells = [Int](repeating: 0, count: n)
    for column in 1..<(m + 1) { rowCells[match[column] - 1] = column - 1 }
    let placements = members.enumerated().map { row, member in
        let cell = cells[rowCells[row]]
        // The frozen renderer spreads a full non-unit slot over its assigned
        // member. Preserve that slot identity to keep migration layout/motion
        // identical; unit-cell assignments carry coordinates only.
        let identity = slotMembers?[rowCells[row]] ?? member
        return Placement(member: identity, column: cell.column, row: cell.row)
    }
    return SlotAssignment(placements: placements, rowCells: rowCells)
}

private func originDistanceLowerBound(old: [String: Placement], members: [Member], box: SearchBox) -> Double {
    let survivors = members.filter { old[$0.id] != nil }
    let projected = survivors.reduce(0.0) { sum, member in
        let before = old[member.id]!
        let column = max(box.column, min(before.column, box.column + box.columns - member.columns))
        let row = max(box.row, min(before.row, box.row + box.rows - member.rows))
        return sum + shiftDistance(before, Cell(column: column, row: row))
    }
    guard survivors.count == members.count,
          Double(box.columns) * Double(box.rows) == Double(members.count),
          members.allSatisfy({ $0.columns == 1 && $0.rows == 1 }) else { return projected }
    // A full unit box fixes the sum of target anchors. Other shapes do not.
    let oldX = survivors.reduce(0.0) { $0 + Double(old[$1.id]!.column) }
    let oldY = survivors.reduce(0.0) { $0 + Double(old[$1.id]!.row) }
    let nextX = Double(members.count) * Double(box.column) + Double(box.rows) * Double(box.columns) * Double(box.columns - 1) / 2
    let nextY = Double(members.count) * Double(box.row) + Double(box.columns) * Double(box.rows) * Double(box.rows - 1) / 2
    guard [oldX, oldY, nextX, nextY].allSatisfy({ $0 <= Double(maximumSafeInteger) && $0.rounded(.towardZero) == $0 }) else { return projected }
    return max(projected, overviewHypot((nextX - oldX) * pitchX, (nextY - oldY) * pitchY))
}

/// Enumerate complete repairs of a unit assignment, with larger rectangles fixed.
/// nil means legal; an empty array means no unit-only repair exists in this branch.
private func unitAssignmentRepairs(previous: [Placement], fixed: [Placement], assignment: SlotAssignment,
                                   cells: [Cell], forbidden: Set<Int>, contourLimits: [Cell: LayoutContour],
                                   tick: Tick) throws -> [Set<Int>]? {
    let all = fixed + assignment.placements
    var branches = [Set<Int>]()
    let holes = try layoutHoles(all, tick: tick)
    if !holes.isEmpty {
        for hole in holes {
            guard let cell = cells.firstIndex(of: hole) else { continue }
            var branch = forbidden
            for row in assignment.placements.count..<cells.count { branch.insert(row * cells.count + cell) }
            branches.append(branch)
        }
        for (row, member) in assignment.placements.enumerated() where holes.contains(where: {
            abs($0.column - member.column) + abs($0.row - member.row) == 1
        }) {
            branches.append(forbidden.union([row * cells.count + assignment.rowCells[row]]))
        }
        return branches
    }
    let contour = try layoutContour(all, tick: tick)
    if !contour.fits(contourLimits) {
        // Any different occupancy must fill at least one current vacancy. Each
        // branch forbids every dummy row from taking that cell, while leaving
        // the real-member assignment free to minimize travel and avoid collisions.
        for vacancy in contour.vacancies {
            guard let cell = cells.firstIndex(of: vacancy) else { continue }
            var branch = forbidden
            for row in assignment.placements.count..<cells.count { branch.insert(row * cells.count + cell) }
            branches.append(branch)
        }
        return branches
    }
    let plan = try planStraightMoves(previous, all, tick: tick)
    guard let conflictIDs = plan.conflictIDs else { return nil }
    if let blockedBy = plan.blockedBy {
        if let aRow = assignment.placements.firstIndex(where: { $0.id == blockedBy.moving }) {
            let a = assignment.placements[aRow]
            let obstacle = all.first { $0.id == blockedBy.stationary }!
            var branch = forbidden
            for (index, cell) in cells.enumerated() {
                let pair = try planStraightMoves(previous.filter { $0.id == a.id || $0.id == obstacle.id },
                                                 [Placement(member: a.member, column: cell.column, row: cell.row), obstacle], tick: tick)
                if pair.conflictIDs != nil { branch.insert(aRow * cells.count + index) }
            }
            branches.append(branch)
        }
        if let bRow = assignment.placements.firstIndex(where: { $0.id == blockedBy.stationary }) {
            let b = assignment.placements[bRow]
            let index = cells.firstIndex(of: Cell(column: b.column, row: b.row))!
            branches.append(forbidden.union([bRow * cells.count + index]))
        }
        return branches
    }
    for id in conflictIDs {
        guard let row = assignment.placements.firstIndex(where: { $0.id == id }) else { continue }
        branches.append(forbidden.union([row * cells.count + assignment.rowCells[row]]))
    }
    return branches
}

private final class OverviewPackingSolver {
    private enum CandidateBudgetExhausted: Error { case exhausted }
    private let previous: [Placement]
    private let next: [Member]
    private let fittingSize: CGSize?
    private let preservePositions: Bool
    private let preferredSize: CGSize?
    private let budget: Int
    private var old: [String: Placement] = [:]
    private var work = NativeOverviewSearchWork()
    private var best: Result?
    private var geometricFallback: Result?
    private var contourLimits: [Cell: LayoutContour] = [:]

    init(previous: [Placement], next: [Member], fittingSize: CGSize?, preferredSize: CGSize?, preservePositions: Bool, budget: Int) {
        self.previous = previous
        self.next = next
        self.fittingSize = fittingSize
        self.preservePositions = preservePositions
        self.preferredSize = preferredSize
        self.budget = budget
    }

    private func tick() throws {
        // Native owners cancel obsolete detached plans when membership changes.
        // Poll without charging cancellation checks against the search budget.
        if work.steps.isMultiple(of: 1_024) { try Task.checkCancellation() }
        if work.steps >= budget { throw NativeOverviewLayoutError.searchLimit }
        work.steps += 1
    }

    private func candidateTick() throws {
        if work.candidateSteps >= 1_000_000 { throw CandidateBudgetExhausted.exhausted }
        try tick()
        work.candidateSteps += 1
    }

    private func finish(_ result: Result, searchComplete: Bool = true) -> Result {
        var result = result
        result.searchComplete = searchComplete
        result.work = work
        return result
    }

    private func accept(_ placed: [Placement], tick: Tick) throws {
        guard try layoutHoles(placed, tick: tick).isEmpty else { return }
        guard try layoutContour(placed, tick: tick).fits(contourLimits) else { return }
        let plan = try planStraightMoves(previous, placed, tick: tick)
        guard plan.conflictIDs == nil else { return }
        let result = try summarize(placed, old: old, moveOrder: plan.moveOrder)
        if work.firstFeasibleStep == nil { work.firstFeasibleStep = work.steps }
        if best == nil || result.totalShiftDistance < best!.totalShiftDistance {
            best = result
            work.bestStep = work.steps
        }
    }

    func run() throws -> Result {
        try Task.checkCancellation()
        try validate(previous: previous, next: next, budget: budget)
        for fittingSize in [fittingSize, preferredSize].compactMap({ $0 }) {
            guard fittingSize.width.isFinite, fittingSize.height.isFinite,
                  fittingSize.width >= 0, fittingSize.height >= 0 else {
                throw NativeOverviewLayoutError.invalidInput("Readable layout size must be finite and nonnegative")
            }
        }
        old = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        do { return try search() }
        catch NativeOverviewLayoutError.searchLimit {
            if let best { return finish(best, searchComplete: false) }
            if var fallback = geometricFallback {
                fallback.requiresRepack = !previous.isEmpty
                return finish(fallback, searchComplete: false)
            }
            throw NativeOverviewLayoutError.searchLimit
        }
    }

    private func search() throws -> Result {
        let members = next.sorted { idPrecedes($0.id, $1.id) }
        if members.isEmpty { return finish(try summarize([], old: old)) }
        let free = members.sorted {
            let a = $0.columns * $0.rows, b = $1.columns * $1.rows
            return a == b ? idPrecedes($0.id, $1.id) : a > b
        }
        // A readable, reasonably occupied history is more valuable than a
        // cosmetic contour repair. Keep every survivor fixed unless packing
        // proves an entire row or column is avoidable. Conflicting growth still
        // uses the existing planner and its collision-certified move order.
        if preservePositions, let fittingSize, !previous.isEmpty {
            var placed = members.compactMap { member in
                old[member.id].map { Placement(member: member, column: $0.column, row: $0.row) }
            }
            let overlap = placed.enumerated().contains { index, p in
                placed.dropFirst(index + 1).contains { intersects(p, $0) }
            }
            if !overlap, !placed.isEmpty {
                let oldBounds = try summarize(previous, old: old).bounds
                let columns = min(members.reduce(0) { $0 + $1.columns },
                                  Int(min(Double(maximumSafeInteger), floor((fittingSize.width + 16) / pitchX))))
                let rows = min(members.reduce(0) { $0 + $1.rows },
                               Int(min(Double(maximumSafeInteger), floor((fittingSize.height + 16) / pitchY))))
                for member in free where old[member.id] == nil {
                    var slot: Placement?
                    if columns >= member.columns, rows >= member.rows {
                        // Search the existing envelope before extending it, so
                        // a deletion vacancy is reusable even near an outer edge.
                        for envelope in [(min(columns, oldBounds.columns), min(rows, oldBounds.rows)), (columns, rows)] {
                            guard slot == nil, envelope.0 >= member.columns, envelope.1 >= member.rows else { continue }
                            outer: for row in oldBounds.row...(oldBounds.row + envelope.1 - member.rows) {
                                for column in oldBounds.column...(oldBounds.column + envelope.0 - member.columns) {
                                    try tick()
                                    let candidate = Placement(member: member, column: column, row: row)
                                    if !placed.contains(where: { intersects(candidate, $0) }) {
                                        slot = candidate; break outer
                                    }
                                }
                            }
                        }
                    }
                    guard let slot else { break }
                    placed.append(slot)
                }
                let result = try summarize(placed, old: old)
                let area = Double(members.reduce(0) { $0 + $1.columns * $1.rows })
                if placed.count == members.count,
                   result.bounds.width <= fittingSize.width + 1e-6,
                   result.bounds.height <= fittingSize.height + 1e-6,
                   area >= Double(result.bounds.columns) * Double(result.bounds.rows) * 0.75 {
                    // Occupancy alone can keep a wide card stranded below a
                    // vacancy after deletion or shrink. Only reject history
                    // when a smaller envelope is actually packable; necessary
                    // vacancies (such as a deleted center cell) stay stable.
                    var dominated = false
                    do {
                        for size in [Cell(column: result.bounds.columns - 1, row: result.bounds.rows),
                                     Cell(column: result.bounds.columns, row: result.bounds.rows - 1)] {
                            guard size.column > 0, size.row > 0,
                                  area <= Double(size.column) * Double(size.row) else { continue }
                            if let compact = try packBox(fixed: [], free: free,
                                box: SearchBox(column: result.bounds.column, row: result.bounds.row,
                                               columns: size.column, rows: size.row), tick: tick) {
                                // Preserve this readable witness if subsequent
                                // shape/move optimization exhausts the budget.
                                geometricFallback = try summarize(compact, old: old)
                                dominated = true
                                break
                            }
                        }
                    } catch NativeOverviewLayoutError.searchLimit {
                        // No smaller witness was established. The original
                        // zero-travel candidate is still a legal readable fit.
                        return finish(result, searchComplete: false)
                    }
                    if !dominated { return finish(result) }
                }
            }
        }
        let minColumns = members.map(\.columns).max()!, minRows = members.map(\.rows).max()!
        let maxColumns = members.reduce(0) { $0 + $1.columns }, maxRows = members.reduce(0) { $0 + $1.rows }
        let area = members.reduce(0) { $0 + $1.columns * $1.rows }
        var frontier = [Result]()
        var lastHeight = maxRows + 1
        func fit(_ columns: Int, _ rows: Int) throws -> [Placement]? {
            guard Double(columns) * Double(rows) >= Double(area) else { return nil }
            return try packBox(fixed: [], free: free, box: SearchBox(column: 0, row: 0, columns: columns, rows: rows), tick: tick)
        }
        if let fittingSize, geometricFallback == nil {
            let columns = Int(min(Double(maxColumns), floor((fittingSize.width + NativeOverviewLayout.gap + 1e-6) / pitchX)))
            let rows = Int(min(Double(maxRows), floor((fittingSize.height + NativeOverviewLayout.gap + 1e-6) / pitchY)))
            // Establish viewport feasibility before spending work on aspect or
            // animation. A truncated frontier must not choose overflow when an
            // unexplored fitting shape exists. Failure to finish this decision
            // remains a search error, rather than a claim of insufficient space.
            if columns >= minColumns, rows >= minRows, let placement = try fit(columns, rows) {
                geometricFallback = try summarize(placement, old: old)
            }
        }
        for columns in minColumns...maxColumns {
            try tick()
            var low = max(minRows, Int(ceil(Double(area) / Double(columns))))
            var high = min(maxRows, lastHeight - 1)
            if low > high { continue }
            guard var placement = try fit(columns, high) else { continue }
            while low < high {
                let mid = (low + high) / 2
                if let candidate = try fit(columns, mid) { high = mid; placement = candidate }
                else { low = mid + 1 }
            }
            lastHeight = high
            let shape = try summarize(placement, old: old)
            frontier.append(shape)
            // A legal packing is already useful even if proving a better shape
            // or a one-move-per-survivor animation exhausts the search budget.
            if geometricFallback == nil { geometricFallback = shape }
        }
        if let fittingSize {
            let fitting = frontier.filter {
                $0.bounds.width <= fittingSize.width + 1e-6 && $0.bounds.height <= fittingSize.height + 1e-6
            }
            if !fitting.isEmpty { frontier = fitting }
            // Keep an already readable shape when another aspect becomes feasible
            // during resize. Capacity takes precedence over cosmetic reshuffling.
            let oldBounds = try summarize(previous, old: old).bounds
            let retained = fitting.filter {
                $0.bounds.columns == oldBounds.columns && $0.bounds.rows == oldBounds.rows
            }
            if !retained.isEmpty { frontier = retained }
        }
        // At a fixed natural footprint, visible card area scales quadratically
        // with camera scale. Prefer the largest natural-scale fit before aspect.
        if let preferredSize, let fittingSize,
           frontier.contains(where: { $0.bounds.width <= fittingSize.width + 1e-6 && $0.bounds.height <= fittingSize.height + 1e-6 }) {
            func scale(_ result: Result) -> Double {
                min(1, preferredSize.width / result.bounds.width, preferredSize.height / result.bounds.height)
            }
            let bestScale = frontier.map(scale).max()!
            frontier = frontier.filter { scale($0) >= bestScale - 1e-9 }
        }
        frontier.sort { $0.aspect == $1.aspect ? $0.bounds.width < $1.bounds.width : $0.aspect! < $1.aspect! }
        guard let first = frontier.first else { throw NativeOverviewLayoutError.noLegalLayout }
        let optimalBoxes = frontier.filter { $0.aspect == first.aspect }
        geometricFallback = optimalBoxes.min { $0.totalShiftDistance < $1.totalShiftDistance }
        for shape in optimalBoxes {
            let contour = try layoutContour(shape.placements, tick: tick)
            contourLimits[contour.size] = contour
        }
        let survivors = members.filter { old[$0.id] != nil }
        // Checking old anchors first makes budget-truncated results idempotent.
        if survivors.count == members.count {
            let preserved = members.map { Placement(member: $0, column: old[$0.id]!.column, row: old[$0.id]!.row) }
            let summary = try summarize(preserved, old: old)
            let shapeMatches = optimalBoxes.contains { $0.bounds.columns == summary.bounds.columns && $0.bounds.rows == summary.bounds.rows }
            let overlap = preserved.enumerated().contains { index, p in preserved.dropFirst(index + 1).contains { intersects(p, $0) } }
            if shapeMatches, !overlap { try accept(preserved, tick: tick) }
        }
        if let best, best.distanceOptimal { return finish(best) }
        for shape in optimalBoxes { try accept(shape.placements, tick: tick) }
        if let best, best.totalShiftDistance == 0 { return finish(best) }
        let maxLeft = max(0, survivors.map { old[$0.id]!.column }.max() ?? 0)
        let maxTop = max(0, survivors.map { old[$0.id]!.row }.max() ?? 0)
        var proposals = [SearchBox]()
        for shape in optimalBoxes {
            let columns = shape.bounds.columns, rows = shape.bounds.rows
            let centerColumn = survivors.reduce(0.0) { $0 + Double(old[$1.id]!.column) + Double($1.columns) / 2 } / Double(max(1, survivors.count)) - Double(columns) / 2
            let centerRow = survivors.reduce(0.0) { $0 + Double(old[$1.id]!.row) + Double($1.rows) / 2 } / Double(max(1, survivors.count)) - Double(rows) / 2
            var seen = Set<Cell>()
            for row in [Int(floor(centerRow)), Int(ceil(centerRow)), 0] {
                for column in [Int(floor(centerColumn)), Int(ceil(centerColumn)), 0] {
                    let cell = Cell(column: max(0, column), row: max(0, row))
                    guard seen.insert(cell).inserted else { continue }
                    var box = SearchBox(column: cell.column, row: cell.row, columns: columns, rows: rows)
                    box.lowerBound = originDistanceLowerBound(old: old, members: members, box: box)
                    proposals.append(box)
                }
            }
        }
        proposals.sort(by: boxPrecedes)
        do {
            if members.contains(where: { $0.columns != 1 || $0.rows != 1 }) {
                // Preserve footprint-group insertion order when assigning interchangeable slots.
                var groups = [[Member]]()
                for member in members {
                    if let index = groups.firstIndex(where: { $0[0].columns == member.columns && $0[0].rows == member.rows }) { groups[index].append(member) }
                    else { groups.append([member]) }
                }
                for box in proposals {
                    let shape = optimalBoxes.first { $0.bounds.columns == box.columns && $0.bounds.rows == box.rows }!
                    var candidates = [[Placement]]()
                    for flipX in [false, true] {
                        for flipY in [false, true] {
                            candidates.append(shape.placements.map {
                                Placement(member: $0.member,
                                          column: box.column + (flipX ? box.columns - $0.column - $0.columns : $0.column),
                                          row: box.row + (flipY ? box.rows - $0.row - $0.rows : $0.row))
                            })
                        }
                    }
                    let anchors = groups.filter { $0.count == 1 }.compactMap { group -> Placement? in
                        let member = group[0]
                        guard let before = old[member.id], before.column >= box.column, before.row >= box.row,
                              before.column + member.columns <= box.column + box.columns,
                              before.row + member.rows <= box.row + box.rows else { return nil }
                        return Placement(member: member, column: before.column, row: before.row)
                    }
                    if !anchors.isEmpty, !anchors.enumerated().contains(where: { index, a in anchors.dropFirst(index + 1).contains { intersects(a, $0) } }) {
                        if let anchored = try packBox(fixed: anchors, free: free.filter { m in !anchors.contains { $0.id == m.id } }, box: box, tick: candidateTick) {
                            candidates.append(anchored)
                        }
                    }
                    for slots in candidates {
                        for axisOnly in [false, true] {
                            var candidate = [Placement]()
                            for group in groups {
                                let matchingSlots = slots.filter { $0.columns == group[0].columns && $0.rows == group[0].rows }
                                let cells = matchingSlots.map { Cell(column: $0.column, row: $0.row) }
                                var forbidden = Set<Int>()
                                if axisOnly {
                                    for (row, member) in group.enumerated() {
                                        guard let before = old[member.id] else { continue }
                                        for (column, cell) in cells.enumerated() where before.column != cell.column && before.row != cell.row {
                                            forbidden.insert(row * cells.count + column)
                                        }
                                    }
                                }
                                guard let assignment = try assignSlots(group, cells: cells, old: old, tick: candidateTick, forbidden: forbidden, slotMembers: matchingSlots.map(\.member)) else { break }
                                candidate += assignment.placements
                            }
                            if candidate.count == members.count { try accept(candidate, tick: candidateTick) }
                            if let best, best.distanceOptimal { return finish(best) }
                        }
                    }
                }
            }
            for box in proposals {
                if best == nil || box.lowerBound < best!.totalShiftDistance { try searchBox(box, free: free, tick: candidateTick, local: true) }
                if let best, best.distanceOptimal { return finish(best) }
            }
        } catch CandidateBudgetExhausted.exhausted { /* Continue the unrestricted search. */ }
        // Collisions can require origins beyond old anchors. Expand until survivor
        // travel proves no outside origin could improve the current feasible result.
        var radius = 0
        while true {
            try tick()
            var origins = [SearchBox]()
            for shape in optimalBoxes {
                let columns = shape.bounds.columns, rows = shape.bounds.rows
                for row in 0...(maxTop + radius) {
                    for column in 0...(maxLeft + radius) {
                        if radius > 0 && row < maxTop + radius && column < maxLeft + radius { continue }
                        try tick()
                        var box = SearchBox(column: column, row: row, columns: columns, rows: rows)
                        box.lowerBound = originDistanceLowerBound(old: old, members: members, box: box)
                        if best == nil || box.lowerBound < best!.totalShiftDistance { origins.append(box) }
                    }
                }
            }
            origins.sort(by: boxPrecedes)
            for box in origins {
                if let best, box.lowerBound >= best.totalShiftDistance { continue }
                try searchBox(box, free: free, tick: tick, local: false)
                if let best, best.totalShiftDistance == 0 { return finish(best) }
            }
            if let best {
                let outsideX = survivors.reduce(0.0) { $0 + Double(max(0, maxLeft + radius + 1 - old[$1.id]!.column)) * pitchX }
                let outsideY = survivors.reduce(0.0) { $0 + Double(max(0, maxTop + radius + 1 - old[$1.id]!.row)) * pitchY }
                if outsideX >= best.totalShiftDistance && outsideY >= best.totalShiftDistance { return finish(best) }
            }
            radius += 1
        }
    }

    private func boxPrecedes(_ a: SearchBox, _ b: SearchBox) -> Bool {
        if a.lowerBound != b.lowerBound { return a.lowerBound < b.lowerBound }
        if a.row != b.row { return a.row < b.row }
        if a.column != b.column { return a.column < b.column }
        return a.columns < b.columns
    }

    private func searchBox(_ box: SearchBox, free: [Member], tick: Tick, local: Bool) throws {
        guard box.column <= maximumSafeInteger - box.columns, box.row <= maximumSafeInteger - box.rows else { return }
        var placed = [Placement]()
        func search(_ index: Int, _ distance: Double) throws {
            try tick()
            if let best, distance >= best.totalShiftDistance { return }
            if index == free.count { try accept(placed, tick: tick); return }
            if free[index].columns == 1 && free[index].rows == 1 {
                var cells = [Cell]()
                for row in box.row..<(box.row + box.rows) {
                    for column in box.column..<(box.column + box.columns) {
                        try tick()
                        let unit = Placement(member: Member(id: "", columns: 1, rows: 1), column: column, row: row)
                        if !placed.contains(where: { intersects($0, unit) }) { cells.append(Cell(column: column, row: row)) }
                    }
                }
                let units = Array(free[index...])
                var localForbidden = Set<Int>()
                if local {
                    for (row, member) in units.enumerated() {
                        guard let before = old[member.id] else { continue }
                        for (column, cell) in cells.enumerated() where abs(before.column - cell.column) > 1 || abs(before.row - cell.row) > 1 {
                            localForbidden.insert(row * cells.count + column)
                        }
                    }
                }
                var queue = [AssignmentCandidate](), seen = Set<[Int]>()
                func enqueue(_ initialForbidden: Set<Int>) throws {
                    let forbidden = local ? initialForbidden.union(localForbidden) : initialForbidden
                    guard seen.insert(forbidden.sorted()).inserted else { return }
                    guard let assignment = try assignSlots(units, cells: cells, old: old, tick: tick, forbidden: forbidden) else { return }
                    let cost = try summarize(placed + assignment.placements, old: old).totalShiftDistance
                    if best == nil || cost < best!.totalShiftDistance { queue.append(AssignmentCandidate(forbidden: forbidden, assignment: assignment, distance: cost)) }
                }
                var axisOnly = Set<Int>()
                for (memberIndex, member) in units.enumerated() {
                    guard let before = old[member.id] else { continue }
                    for (index, cell) in cells.enumerated() where before.column != cell.column && before.row != cell.row {
                        axisOnly.insert(memberIndex * cells.count + index)
                    }
                }
                if units.count < cells.count {
                    for row in units.count..<cells.count {
                        for (index, cell) in cells.enumerated() where cell.column > box.column && cell.column < box.column + box.columns - 1 && cell.row > box.row && cell.row < box.row + box.rows - 1 {
                            axisOnly.insert(row * cells.count + index)
                        }
                    }
                }
                if let seed = try assignSlots(units, cells: cells, old: old, tick: tick, forbidden: axisOnly.union(localForbidden)) {
                    try accept(placed + seed.placements, tick: tick)
                }
                try enqueue([])
                while !queue.isEmpty {
                    try tick()
                    queue.sort { $0.distance > $1.distance }
                    let candidate = queue.removeLast()
                    if let best, candidate.distance >= best.totalShiftDistance { break }
                    if let repairs = try unitAssignmentRepairs(previous: previous, fixed: placed, assignment: candidate.assignment,
                                                              cells: cells, forbidden: candidate.forbidden,
                                                              contourLimits: contourLimits, tick: tick) {
                        for forbidden in repairs { try enqueue(forbidden) }
                    } else { try accept(placed + candidate.assignment.placements, tick: tick); break }
                }
                return
            }
            let member = free[index]
            var candidates = [(placement: Placement, cost: Double)]()
            guard member.rows <= box.rows, member.columns <= box.columns else { return }
            for row in box.row...(box.row + box.rows - member.rows) {
                for column in box.column...(box.column + box.columns - member.columns) {
                    try tick()
                    let before = old[member.id]
                    if local, let before, abs(before.column - column) > 1 || abs(before.row - row) > 1 { continue }
                    let placement = Placement(member: member, column: column, row: row)
                    let cost = shiftDistance(before, Cell(column: column, row: row))
                    if (best == nil || distance + cost < best!.totalShiftDistance), !placed.contains(where: { intersects($0, placement) }) {
                        candidates.append((placement, cost))
                    }
                }
            }
            candidates.sort {
                if $0.cost != $1.cost { return $0.cost < $1.cost }
                if $0.placement.row != $1.placement.row { return $0.placement.row < $1.placement.row }
                return $0.placement.column < $1.placement.column
            }
            for candidate in candidates {
                placed.append(candidate.placement)
                try search(index + 1, distance + candidate.cost)
                placed.removeLast()
                if best?.totalShiftDistance == 0 { return }
            }
        }
        try search(0, 0)
    }
}
