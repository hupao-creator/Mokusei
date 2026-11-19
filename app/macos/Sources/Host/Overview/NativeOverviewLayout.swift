import Foundation
import MokuseiPluginUI

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

/// The product grid. Card footprints remain the latest measured spans; this
/// metric only maps those spans to world points.
public struct NativeOverviewGridMetrics: Equatable, Sendable {
    public let columnWidth: Double
    public let rowHeight: Double
    public let gap: Double

    public init(columnWidth: Double, rowHeight: Double, gap: Double) {
        self.columnWidth = columnWidth
        self.rowHeight = rowHeight
        self.gap = gap
    }

    public var columnPitch: Double { columnWidth + gap }
    public var rowPitch: Double { rowHeight + gap }

    public static let standard = Self(columnWidth: Double(NativeGeometry.overviewCard.width),
                                      rowHeight: Double(NativeGeometry.overviewCard.height),
                                      gap: Double(NativeGeometry.overviewCardGap))

    public func width(columns: Int) -> Double {
        Double(columns) * columnWidth + Double(columns - 1) * gap
    }

    public func height(rows: Int) -> Double {
        Double(rows) * rowHeight + Double(rows - 1) * gap
    }
}

/// Explicit inputs shared by automatic placement and fit-all framing.
/// `scaleCap` is the product's intentional manual/automatic zoom ceiling; nil
/// means automatic framing has no ceiling. All policies retain the 1x floor.
public struct NativeOverviewGeometryPolicy: Equatable, Sendable {
    public var metrics: NativeOverviewGridMetrics
    public var scaleCap: Double?

    public init(metrics: NativeOverviewGridMetrics = .standard, scaleCap: Double? = 1.0) {
        self.metrics = metrics
        self.scaleCap = scaleCap
    }

    public static let standard = Self()
}

public struct NativeOverviewBounds: Equatable, Codable, Sendable {
    public let column: Int
    public let row: Int
    public let columns: Int
    public let rows: Int
    public let left: Double
    public let top: Double
    public let width: Double
    public let height: Double

    public var centerX: Double { left + width / 2 }
    public var centerY: Double { top + height / 2 }

    public init(column: Int, row: Int, columns: Int, rows: Int,
                left: Double, top: Double, width: Double, height: Double) {
        self.column = column
        self.row = row
        self.columns = columns
        self.rows = rows
        self.left = left
        self.top = top
        self.width = width
        self.height = height
    }

    public static let empty = Self(column: 0, row: 0, columns: 0, rows: 0,
                                   left: 0, top: 0, width: 0, height: 0)
}

public struct NativeOverviewGeometry: Equatable, Sendable {
    public let placements: [NativeOverviewPlacement]
    public let bounds: NativeOverviewBounds
    /// Nil for an empty collection or a viewport without usable area.
    public let automaticCamera: NativeOverviewTransform?

    public init(placements: [NativeOverviewPlacement], bounds: NativeOverviewBounds,
                automaticCamera: NativeOverviewTransform?) {
        self.placements = placements
        self.bounds = bounds
        self.automaticCamera = automaticCamera
    }
}

public enum NativeOverviewLayoutError: LocalizedError, Equatable {
    case invalidInput(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let message): message
        }
    }
}

/// Pure, history-free geometry. The same complete input always produces the
/// same placements, bounds and fit-all camera.
///
/// `members` order is product order (selection/catalog order): it owns card
/// identity order and deterministic tie-breaking. It is not a user-movable
/// position and no previous layout participates.
public enum NativeOverviewLayout {
    private static let maximumSafeInteger = 9_007_199_254_740_991

    public static var metrics: NativeOverviewGridMetrics { .standard }
    public static var columnWidth: Double { metrics.columnWidth }
    public static var rowHeight: Double { metrics.rowHeight }
    public static var gap: Double { metrics.gap }
    public static var columnPitch: Double { metrics.columnPitch }
    public static var rowPitch: Double { metrics.rowPitch }

    public static func solve(members: [NativeOverviewMember],
                             usableViewport: NativeOverviewContentRect,
                             policy: NativeOverviewGeometryPolicy = .standard) throws -> NativeOverviewGeometry {
        try validate(members: members, viewport: usableViewport, policy: policy)
        guard !members.isEmpty else {
            return NativeOverviewGeometry(placements: [], bounds: .empty, automaticCamera: nil)
        }
        let chosen = choosePlacement(members: members, viewport: usableViewport, metrics: policy.metrics)
        // Shelf candidates are size-sorted for packing. Return product order so
        // content-only reuse and callers see a stable, input-aligned sequence.
        let byID = Dictionary(uniqueKeysWithValues: chosen.map { ($0.id, $0) })
        let placements = members.compactMap { byID[$0.id] }
        guard placements.count == members.count else {
            throw NativeOverviewLayoutError.invalidInput("Overview solver lost a member")
        }
        let bounds = summarize(placements, metrics: policy.metrics)
        let camera = automaticCamera(bounds: bounds, usableViewport: usableViewport, policy: policy)
        return NativeOverviewGeometry(placements: placements, bounds: bounds, automaticCamera: camera)
    }

    /// Center the complete arrangement, retaining the card scale floor.
    public static func automaticCamera(bounds: NativeOverviewBounds,
                                       usableViewport: NativeOverviewContentRect,
                                       policy: NativeOverviewGeometryPolicy = .standard) -> NativeOverviewTransform? {
        guard bounds.width > 0, bounds.height > 0,
              usableViewport.width > 0, usableViewport.height > 0 else { return nil }
        let content = NativeOverviewContentRect(left: bounds.left, top: bounds.top,
                                                width: bounds.width, height: bounds.height)
        return NativeOverviewCameraGeometry.centeredTransform(
            content: content, usable: usableViewport, scaleCap: policy.scaleCap)
    }

    // MARK: - Candidate selection

    private struct Score {
        let fit: Double
        let area: Double
        let width: Double

        init(columns: Int, rows: Int, viewport: NativeOverviewContentRect, metrics: NativeOverviewGridMetrics) {
            width = metrics.width(columns: columns)
            let height = metrics.height(rows: rows)
            fit = min(viewport.width / width, viewport.height / height)
            area = width * height
        }

        func improves(on other: Self) -> Bool {
            if fit != other.fit { return fit > other.fit }
            if area != other.area { return area < other.area }
            return width < other.width
        }
    }

    private static func choosePlacement(members: [NativeOverviewMember],
                                        viewport: NativeOverviewContentRect,
                                        metrics: NativeOverviewGridMetrics) -> [NativeOverviewPlacement] {
        let maxColumns = members.map(\.columns).max()!
        let maxRows = members.map(\.rows).max()!
        func gridScore(_ across: Int) -> Score {
            Score(columns: across * maxColumns, rows: (1 + (members.count - 1) / across) * maxRows,
                  viewport: viewport, metrics: metrics)
        }

        // Score regular grids by dimensions alone. Packing each winning row to
        // its members' actual width and height can only improve its raw fit.
        var across = 1
        var bestScore = gridScore(1)
        for count in members.indices.dropFirst() {
            let score = gridScore(count + 1)
            if score.improves(on: bestScore) {
                across = count + 1
                bestScore = score
            }
        }
        var x = 0, y = 0, band = 0
        var best = members.enumerated().map { index, member in
            if index > 0 && index.isMultiple(of: across) {
                y += band
                x = 0
                band = 0
            }
            let placement = NativeOverviewPlacement(member: member, column: x, row: y)
            x += member.columns
            band = max(band, member.rows)
            return placement
        }
        guard members.contains(where: { $0.columns != maxColumns || $0.rows != maxRows }) else { return best }

        func score(_ placements: [NativeOverviewPlacement]) -> Score {
            let bounds = summarize(placements, metrics: metrics)
            return Score(columns: bounds.columns, rows: bounds.rows, viewport: viewport, metrics: metrics)
        }
        bestScore = score(best)
        // Prefer the product-order packing on ties, across both orientations.
        for sizeFirst in [false, true] {
            for vertical in [false, true] {
                var order = members
                if sizeFirst {
                    order.sort { a, b in
                        vertical ? (a.columns, a.rows) > (b.columns, b.rows) : (a.rows, a.columns) > (b.rows, b.columns)
                    }
                    if order == members { continue }
                }
                let minimum = vertical ? maxRows : maxColumns
                let total = members.reduce(0) { $0 + (vertical ? $1.rows : $1.columns) }
                for target in shelfTargets(minimum: minimum, maximum: total) {
                    let placements = pack(order, target: target, vertical: vertical)
                    let candidate = score(placements)
                    if candidate.improves(on: bestScore) {
                        best = placements
                        bestScore = candidate
                    }
                }
            }
        }
        return best
    }

    private static func shelfTargets(minimum: Int, maximum: Int) -> [Int] {
        let count = maximum - minimum + 1
        guard count > 64 else { return Array(minimum...maximum) }
        let step = (count + 62) / 64
        var targets = Array(stride(from: minimum, through: maximum, by: step))
        if targets.last != maximum { targets.append(maximum) }
        return targets
    }

    private struct Opening {
        let x, y, width, height: Int
    }

    /// Work in strip coordinates and transpose the result for vertical bands.
    /// Each opening is disjoint. Splitting it retains both reusable pieces,
    /// including the space directly underneath a shorter card.
    private static func pack(_ members: [NativeOverviewMember], target: Int,
                             vertical: Bool) -> [NativeOverviewPlacement] {
        var openings = [Opening]()
        var end = 0
        var placements = [NativeOverviewPlacement]()
        placements.reserveCapacity(members.count)
        for member in members {
            let width = vertical ? member.rows : member.columns
            let height = vertical ? member.columns : member.rows
            let slot: Opening
            if let index = openings.firstIndex(where: { width <= $0.width && height <= $0.height }) {
                slot = openings.remove(at: index)
            } else {
                slot = Opening(x: 0, y: end, width: target, height: height)
                end += height
            }
            placements.append(.init(member: member, column: vertical ? slot.y : slot.x,
                                    row: vertical ? slot.x : slot.y))
            if width < slot.width {
                openings.append(.init(x: slot.x + width, y: slot.y,
                                      width: slot.width - width, height: slot.height))
            }
            if height < slot.height {
                openings.append(.init(x: slot.x, y: slot.y + height,
                                      width: width, height: slot.height - height))
            }
            // Bound search cost even when every span is distinct. Forgetting
            // an opening leaves it empty and can never admit an overlap.
            if openings.count > 64 { openings.removeFirst(openings.count - 64) }
        }
        return placements
    }

    private static func summarize(_ placements: [NativeOverviewPlacement],
                                  metrics: NativeOverviewGridMetrics) -> NativeOverviewBounds {
        guard let first = placements.first else { return .empty }
        var left = first.column, top = first.row
        var right = first.column + first.columns, bottom = first.row + first.rows
        for placement in placements.dropFirst() {
            left = min(left, placement.column)
            top = min(top, placement.row)
            right = max(right, placement.column + placement.columns)
            bottom = max(bottom, placement.row + placement.rows)
        }
        let columns = right - left, rows = bottom - top
        return .init(column: left, row: top, columns: columns, rows: rows,
                     left: Double(left) * metrics.columnPitch,
                     top: Double(top) * metrics.rowPitch,
                     width: metrics.width(columns: columns),
                     height: metrics.height(rows: rows))
    }

    // MARK: - Validation

    private static func validate(members: [NativeOverviewMember],
                                 viewport: NativeOverviewContentRect,
                                 policy: NativeOverviewGeometryPolicy) throws {
        let metrics = policy.metrics
        guard metrics.columnWidth.isFinite, metrics.columnWidth > 0,
              metrics.rowHeight.isFinite, metrics.rowHeight > 0,
              metrics.gap.isFinite, metrics.gap >= 0 else {
            throw NativeOverviewLayoutError.invalidInput("Overview grid metrics must be finite and positive")
        }
        if let cap = policy.scaleCap {
            guard cap.isFinite, cap >= NativeOverviewCameraGeometry.scaleFloor else {
                throw NativeOverviewLayoutError.invalidInput("Overview scale cap must be finite and at least 1x")
            }
        }
        for value in [viewport.left, viewport.top, viewport.width, viewport.height] {
            guard value.isFinite else {
                throw NativeOverviewLayoutError.invalidInput("Overview viewport must be finite")
            }
        }
        guard viewport.width >= 0, viewport.height >= 0 else {
            throw NativeOverviewLayoutError.invalidInput("Overview viewport must be nonnegative")
        }
        var ids = Set<String>()
        var columnSum = 0, rowSum = 0
        for member in members {
            guard !member.id.isEmpty, member.columns > 0, member.rows > 0,
                  member.columns <= maximumSafeInteger, member.rows <= maximumSafeInteger else {
                throw NativeOverviewLayoutError.invalidInput("Overview footprints must be positive integer grid spans")
            }
            guard member.columns <= maximumSafeInteger - columnSum,
                  member.rows <= maximumSafeInteger - rowSum else {
                throw NativeOverviewLayoutError.invalidInput("Overview aggregate grid size exceeds safe integers")
            }
            columnSum += member.columns
            rowSum += member.rows
            guard ids.insert(member.id).inserted else {
                throw NativeOverviewLayoutError.invalidInput("Overview member IDs must be unique")
            }
        }
        guard metrics.width(columns: columnSum).isFinite,
              metrics.height(rows: rowSum).isFinite else {
            throw NativeOverviewLayoutError.invalidInput("Overview world bounds cannot be represented")
        }
        if members.count > 1 {
            let maxColumns = members.map(\.columns).max()!
            let maxRows = members.map(\.rows).max()!
            let factor = members.count - 1
            guard maxColumns <= maximumSafeInteger / factor,
                  maxRows <= maximumSafeInteger / factor else {
                throw NativeOverviewLayoutError.invalidInput("Overview grid multiplication exceeds safe integers")
            }
        }
    }
}

public extension NativeOverviewBounds {
    var contentRect: NativeOverviewContentRect {
        .init(left: left, top: top, width: width, height: height)
    }
}

public extension NativeOverviewPlacement {
    func cardFrame(using metrics: NativeOverviewGridMetrics) -> CGRect {
        CGRect(x: Double(column) * metrics.columnPitch,
               y: Double(row) * metrics.rowPitch,
               width: metrics.width(columns: columns),
               height: metrics.height(rows: rows))
    }
}
