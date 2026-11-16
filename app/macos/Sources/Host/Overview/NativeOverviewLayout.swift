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
/// means automatic framing uses the raw fit scale.
public struct NativeOverviewGeometryPolicy: Equatable, Sendable {
    public var metrics: NativeOverviewGridMetrics
    public var scaleCap: Double?

    public init(metrics: NativeOverviewGridMetrics = .standard, scaleCap: Double? = 1.7) {
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

    /// Fit the complete arrangement into the usable viewport and center it.
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

    private struct Candidate {
        let placements: [NativeOverviewPlacement]
        let bounds: NativeOverviewBounds
        let fitScale: Double
        let area: Double
        let seed: Int
    }

    private static func choosePlacement(members: [NativeOverviewMember],
                                        viewport: NativeOverviewContentRect,
                                        metrics: NativeOverviewGridMetrics) -> [NativeOverviewPlacement] {
        var best: Candidate?
        var nextOrdinal = 0
        func consider(_ candidate: Candidate) {
            guard let current = best else { best = candidate; return }
            if isBetter(candidate, current) { best = candidate }
        }
        func makeCandidate(_ placements: [NativeOverviewPlacement]) -> Candidate {
            defer { nextOrdinal += 1 }
            return candidate(placements, viewport: viewport, metrics: metrics, seed: nextOrdinal)
        }

        let maxColumns = members.map(\.columns).max()!
        let maxRows = members.map(\.rows).max()!
        for columns in 1...members.count {
            let placements = members.enumerated().map { index, member in
                NativeOverviewPlacement(member: member,
                                        column: index % columns * maxColumns,
                                        row: index / columns * maxRows)
            }
            consider(makeCandidate(placements))
        }

        for vertical in [false, true] {
            let sorted = members.enumerated().sorted { lhs, rhs in
                let a = lhs.element, b = rhs.element
                let primaryA = vertical ? a.columns : a.rows
                let primaryB = vertical ? b.columns : b.rows
                if primaryA != primaryB { return primaryA > primaryB }
                let secondaryA = vertical ? a.rows : a.columns
                let secondaryB = vertical ? b.rows : b.columns
                if secondaryA != secondaryB { return secondaryA > secondaryB }
                return lhs.offset < rhs.offset
            }.map(\.element)
            let total = members.reduce(0) { $0 + (vertical ? $1.columns : $1.rows) }
            let minimum = members.map { vertical ? $0.columns : $0.rows }.max()!
            for target in shelfTargets(minimum: minimum, maximum: total) {
                consider(makeCandidate(shelf(sorted, target: target, vertical: vertical)))
            }
        }

        let totalColumns = members.reduce(0) { $0 + $1.columns }
        let minimumColumns = members.map(\.columns).max()!
        for target in shelfTargets(minimum: minimumColumns, maximum: totalColumns) {
            consider(makeCandidate(shelf(members, target: target, vertical: false)))
        }

        return best?.placements ?? members.map {
            NativeOverviewPlacement(member: $0, column: 0, row: 0)
        }
    }

    private static func isBetter(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.fitScale != rhs.fitScale { return lhs.fitScale > rhs.fitScale }
        if lhs.area != rhs.area { return lhs.area < rhs.area }
        if lhs.bounds.width != rhs.bounds.width { return lhs.bounds.width < rhs.bounds.width }
        return lhs.seed < rhs.seed
    }

    private static func candidate(_ placements: [NativeOverviewPlacement],
                                  viewport: NativeOverviewContentRect,
                                  metrics: NativeOverviewGridMetrics,
                                  seed: Int) -> Candidate {
        let bounds = summarize(placements, metrics: metrics)
        let fitScale: Double
        if viewport.width > 0, viewport.height > 0, bounds.width > 0, bounds.height > 0 {
            fitScale = min(viewport.width / bounds.width, viewport.height / bounds.height)
        } else {
            fitScale = 0
        }
        return Candidate(placements: placements, bounds: bounds, fitScale: fitScale,
                         area: bounds.width * bounds.height, seed: seed)
    }

    /// The grid pass in `choosePlacement` uses each card's actual span in a
    /// max-span cell for every column count; it includes the independent
    /// regular-grid quality baseline, so the selected result cannot be worse.
    /// Shelf outcomes change only at target boundaries, but a pathological
    /// span can make every integer expensive. Sample a deterministic bounded
    /// set of at most 65 targets; the uniform-grid candidates still guarantee
    /// the quality floor.
    private static func shelfTargets(minimum: Int, maximum: Int) -> [Int] {
        let count = maximum - minimum + 1
        guard count > 64 else { return Array(minimum...maximum) }
        let step = max(1, count / 63)
        var targets = Array(stride(from: minimum, through: maximum, by: step))
        if targets.last != maximum { targets.append(maximum) }
        return targets
    }

    private static func shelf(_ members: [NativeOverviewMember], target: Int,
                              vertical: Bool) -> [NativeOverviewPlacement] {
        var placements = [NativeOverviewPlacement]()
        placements.reserveCapacity(members.count)
        var x = 0, y = 0, band = 0
        for member in members {
            let extent = vertical ? member.rows : member.columns
            let cross = vertical ? member.columns : member.rows
            if x > 0, x + extent > target {
                y += band
                x = 0
                band = 0
            }
            placements.append(.init(member: member,
                                    column: vertical ? y : x,
                                    row: vertical ? x : y))
            x += extent
            band = max(band, cross)
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
            guard cap.isFinite, cap > 0 else {
                throw NativeOverviewLayoutError.invalidInput("Overview scale cap must be finite and positive")
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
