import Foundation
import MokuseiPluginAPI

public enum ThreadCardComposerError: Error, LocalizedError {
    case invalidPreferredSize(component: ThreadCardComponentKind, size: ThreadCardSize)
    case invalidCustomCellBounds
    case overlappingCustomCells
    case duplicateCustomSlotIDs
    case incompleteCustomFootprint
    case noCompleteRectangle

    public var errorDescription: String? {
        switch self {
        case let .invalidPreferredSize(component, size):
            return "Thread card preferred size \(size.cols)x\(size.rows) is not allowed for \(component.rawValue)"
        case .invalidCustomCellBounds:
            return "Invalid custom card cell bounds"
        case .overlappingCustomCells:
            return "Custom card cells overlap"
        case .duplicateCustomSlotIDs:
            return "Custom card slot IDs must be unique"
        case .incompleteCustomFootprint:
            return "Custom card cells must fill their footprint"
        case .noCompleteRectangle:
            return "Thread card composer failed to produce a complete rectangle"
        }
    }
}

/// Exhaustively composes a filled rectangle using only component size contracts
/// and geometry. Ranking follows the shared renderer: column overflow, unmet
/// primary preferences, portrait orientation, area, identity growth, unmet
/// derived preferences, then Todo's upper row and a stable structural key.
public func composeThreadCard(
    _ projection: ThreadCardProjection,
    layoutContext: ThreadCardLayoutContext
) throws -> ThreadCardPresentation {
    try ThreadCardComposer.compose(projection, layoutContext: layoutContext)
}

/// Host extensions enter the same sizing/placement pass as Harness extensions.
public func composeThreadCard(_ projection: ThreadCardProjection, git: HarnessGitStatus?,
                              layoutContext: ThreadCardLayoutContext) throws -> ThreadCardPresentation {
    guard let git, git.isActive, case .standard(let identity, let extensions) = projection else {
        return try composeThreadCard(projection, layoutContext: layoutContext)
    }
    return try composeThreadCard(.standard(identity: identity, extensions: extensions + [.git(git)]), layoutContext: layoutContext)
}

private enum ThreadCardComposer {
    private static let size1x1 = ThreadCardSize(cols: 1, rows: 1)
    private static let size2x1 = ThreadCardSize(cols: 2, rows: 1)
    private static let size1x2 = ThreadCardSize(cols: 1, rows: 2)
    private static let maximumSafeInteger = 9_007_199_254_740_991

    private struct ExtensionContract {
        let projection: ThreadCardExtensionProjection
        let sizing: ThreadCardSizeContract
    }

    private struct ExtensionSelection {
        let contract: ExtensionContract
        let selectedSize: ThreadCardSize
    }

    private struct Candidate {
        let size: ThreadCardSize
        let identity: ThreadCardSizeSelection
        let placements: [ThreadCardExtensionPlacement]
        let rank: [Int]
        let key: String
    }

    private struct Cell: Hashable {
        let col: Int
        let row: Int
    }

    static func compose(
        _ projection: ThreadCardProjection,
        layoutContext: ThreadCardLayoutContext
    ) throws -> ThreadCardPresentation {
        let extensions: [ThreadCardExtensionProjection]
        switch projection {
        case let .slots(_, layout):
            return try composeSlots(projection, layout: layout)
        case let .standard(_, projectedExtensions):
            extensions = projectedExtensions
        }

        let contracts = try canonicalExtensions(extensions).map {
            ExtensionContract(projection: $0, sizing: try sizeContract(component: component(for: $0)))
        }
        let identityContract = try sizeContract(component: .identity)
        if contracts.isEmpty {
            let identity = select(identityContract, size: identityContract.preferredSize)
            return ThreadCardPresentation(
                projection: projection,
                composition: .standard(
                    size: identity.selectedSize, identity: identity, placements: [], key: "identity:1x1"
                ),
                size: identity.selectedSize,
                key: "identity:1x1"
            )
        }

        let availableCols = positiveInteger(layoutContext.availableCols)
        var best: Candidate?
        for identitySize in identityContract.allowedSizes {
            let identity = select(identityContract, size: identitySize)
            for selection in sizeSelections(contracts) {
                let totalArea = area(identitySize) + selection.reduce(0) { $0 + area($1.selectedSize) }
                for cols in 1...totalArea {
                    guard totalArea.isMultiple(of: cols) else { continue }
                    let rows = totalArea / cols
                    // A one-column viewport must be able to stack every extension.
                    guard abs(cols - rows) <= 1 || (availableCols == 1 && cols == 1) else { continue }
                    guard identitySize.cols <= cols, identitySize.rows <= rows else { continue }
                    for placements in enumeratePlacements(selection, cols: cols, rows: rows, identitySize: identitySize) {
                        let size = ThreadCardSize(cols: cols, rows: rows)
                        let candidate = Candidate(
                            size: size,
                            identity: identity,
                            placements: placements,
                            rank: candidateRank(placements, size: size, identity: identity, availableCols: availableCols),
                            key: candidateKey(size: size, identity: identity, placements: placements)
                        )
                        if best.map({ precedes(candidate, $0) }) ?? true { best = candidate }
                    }
                }
            }
        }

        guard let best else { throw ThreadCardComposerError.noCompleteRectangle }
        let key = "standard:\(best.key)"
        return ThreadCardPresentation(
            projection: projection,
            composition: .standard(size: best.size, identity: best.identity, placements: best.placements, key: key),
            size: best.size,
            key: key
        )
    }

    private static func composeSlots(
        _ projection: ThreadCardProjection,
        layout: ThreadCardSlotLayout
    ) throws -> ThreadCardPresentation {
        let size = layout.size
        var occupied = Set<Cell>()
        var ids = Set<String>()
        func place(col: Int, row: Int, cell: ThreadCardSize) throws {
            guard [size.cols, size.rows, cell.cols, cell.rows].allSatisfy(isPositiveSafeInteger),
                  [col, row].allSatisfy({ $0 >= 0 && $0 <= maximumSafeInteger }),
                  cell.cols <= size.cols, cell.rows <= size.rows,
                  col <= size.cols - cell.cols, row <= size.rows - cell.rows,
                  !size.cols.multipliedReportingOverflow(by: size.rows).overflow else {
                throw ThreadCardComposerError.invalidCustomCellBounds
            }
            for cell in rectangleCells(col: col, row: row, cols: cell.cols, rows: cell.rows) {
                guard occupied.insert(cell).inserted else { throw ThreadCardComposerError.overlappingCustomCells }
            }
        }

        try place(col: 0, row: 0, cell: layout.identitySize)
        for slot in layout.slots {
            guard !slot.id.isEmpty, ids.insert(slot.id).inserted else {
                throw ThreadCardComposerError.duplicateCustomSlotIDs
            }
            try place(col: slot.col, row: slot.row, cell: slot.size)
        }
        guard occupied.count == area(size) else { throw ThreadCardComposerError.incompleteCustomFootprint }

        let slotKeys = layout.slots.map { "\($0.id)@\($0.col),\($0.row),\(sizeKey($0.size))" }.joined(separator: "|")
        let key = "slots:\(sizeKey(size)):identity.\(sizeKey(layout.identitySize)):\(slotKeys)"
        return ThreadCardPresentation(
            projection: projection,
            composition: .slots(size: size, identitySize: layout.identitySize, slots: layout.slots, key: key),
            size: size,
            key: key
        )
    }

    private static func sizeContract(component: ThreadCardComponentKind) throws -> ThreadCardSizeContract {
        let allowedSizes: [ThreadCardSize]
        let preferredSize: ThreadCardSize
        switch component {
        case .identity, .todo:
            allowedSizes = [size1x1, size1x2]
            preferredSize = size1x1
        case .derived:
            allowedSizes = [size1x1, size2x1, size1x2]
            preferredSize = size2x1
        case .permission, .git:
            allowedSizes = [size1x1]
            preferredSize = size1x1
        case .question:
            allowedSizes = [size1x2]
            preferredSize = size1x2
        }
        guard allowedSizes.contains(where: { sameSize($0, preferredSize) }) else {
            throw ThreadCardComposerError.invalidPreferredSize(component: component, size: preferredSize)
        }
        return ThreadCardSizeContract(component: component, allowedSizes: allowedSizes, preferredSize: preferredSize)
    }

    private static func select(_ contract: ThreadCardSizeContract, size: ThreadCardSize) -> ThreadCardSizeSelection {
        ThreadCardSizeSelection(
            component: contract.component,
            allowedSizes: contract.allowedSizes,
            preferredSize: contract.preferredSize,
            selectedSize: size
        )
    }

    private static func component(for projection: ThreadCardExtensionProjection) -> ThreadCardComponentKind {
        switch projection {
        case .todo: return .todo
        case .derived: return .derived
        case .git: return .git
        case let .intervention(intervention):
            return intervention.questions.isEmpty ? .permission : .question
        }
    }

    private static func canonicalExtensions(_ extensions: [ThreadCardExtensionProjection]) -> [ThreadCardExtensionProjection] {
        var byKind: [ThreadCardExtensionKind: ThreadCardExtensionProjection] = [:]
        for projection in extensions { byKind[projection.kind] = projection }
        return [ThreadCardExtensionKind.intervention, .todo, .derived, .git].compactMap { byKind[$0] }
    }

    private static func sizeSelections(_ extensions: [ExtensionContract]) -> [[ExtensionSelection]] {
        var selections: [[ExtensionSelection]] = [[]]
        for contract in extensions {
            selections = selections.flatMap { selection in
                contract.sizing.allowedSizes.map { selection + [ExtensionSelection(contract: contract, selectedSize: $0)] }
            }
        }
        return selections
    }

    private static func enumeratePlacements(
        _ selection: [ExtensionSelection],
        cols: Int,
        rows: Int,
        identitySize: ThreadCardSize
    ) -> [[ThreadCardExtensionPlacement]] {
        var occupied = Set(rectangleCells(col: 0, row: 0, cols: identitySize.cols, rows: identitySize.rows))
        var result: [[ThreadCardExtensionPlacement]] = []
        var current: [ThreadCardExtensionPlacement] = []
        func place(_ index: Int) {
            guard index < selection.count else {
                result.append(current)
                return
            }
            let contract = selection[index].contract
            let selectedSize = selection[index].selectedSize
            guard selectedSize.cols <= cols, selectedSize.rows <= rows else { return }
            for row in 0...(rows - selectedSize.rows) {
                for col in 0...(cols - selectedSize.cols) {
                    let cells = rectangleCells(col: col, row: row, cols: selectedSize.cols, rows: selectedSize.rows)
                    guard !cells.contains(where: { occupied.contains($0) }) else { continue }
                    occupied.formUnion(cells)
                    current.append(ThreadCardExtensionPlacement(
                        kind: contract.projection.kind,
                        component: contract.sizing.component,
                        variant: variant(for: selectedSize),
                        col: col,
                        row: row,
                        allowedSizes: contract.sizing.allowedSizes,
                        preferredSize: contract.sizing.preferredSize,
                        selectedSize: selectedSize
                    ))
                    place(index + 1)
                    current.removeLast()
                    occupied.subtract(cells)
                }
            }
        }
        place(0)
        return result
    }

    private static func candidateRank(
        _ placements: [ThreadCardExtensionPlacement],
        size: ThreadCardSize,
        identity: ThreadCardSizeSelection,
        availableCols: Int
    ) -> [Int] {
        let unmetPrimary = placements.filter {
            $0.component != .derived && !sameSize($0.selectedSize, $0.preferredSize)
        }.count
        let unmetDerived = placements.filter {
            $0.component == .derived && !sameSize($0.selectedSize, $0.preferredSize)
        }.count
        return [
            max(0, size.cols - availableCols),
            unmetPrimary,
            size.rows > size.cols ? 1 : 0,
            area(size),
            area(identity.selectedSize) - area(identity.preferredSize),
            unmetDerived
        ]
    }

    private static func precedes(_ left: Candidate, _ right: Candidate) -> Bool {
        for (leftValue, rightValue) in zip(left.rank, right.rank) where leftValue != rightValue {
            return leftValue < rightValue
        }
        // Keep the plan above transient extensions when geometry ranks equally.
        // The structural key compares columns first and would move Todo down
        // into a newly available left cell when derived work or a prompt appears.
        if let leftTodo = left.placements.first(where: { $0.kind == .todo }),
           let rightTodo = right.placements.first(where: { $0.kind == .todo }),
           leftTodo.row != rightTodo.row {
            return leftTodo.row < rightTodo.row
        }
        // These keys contain fixed ASCII component names and single-digit grid
        // coordinates, so lexical ordering matches the renderer's localeCompare.
        return left.key < right.key
    }

    private static func rectangleCells(col: Int, row: Int, cols: Int, rows: Int) -> [Cell] {
        var cells: [Cell] = []
        for y in row..<(row + rows) {
            for x in col..<(col + cols) { cells.append(Cell(col: x, row: y)) }
        }
        return cells
    }

    private static func candidateKey(
        size: ThreadCardSize,
        identity: ThreadCardSizeSelection,
        placements: [ThreadCardExtensionPlacement]
    ) -> String {
        let placementKeys = placements.map {
            "\($0.component.rawValue).\($0.variant.rawValue)@\($0.col),\($0.row),\(sizeKey($0.selectedSize))"
        }.joined(separator: "|")
        return "\(sizeKey(size)):identity.\(sizeKey(identity.selectedSize)):\(placementKeys)"
    }

    private static func variant(for size: ThreadCardSize) -> ThreadCardVariantId {
        if size.rows > 1 { return .tall }
        if size.cols > 1 { return .wide }
        return .compact
    }

    private static func area(_ size: ThreadCardSize) -> Int { size.cols * size.rows }

    private static func sameSize(_ left: ThreadCardSize, _ right: ThreadCardSize) -> Bool {
        left.cols == right.cols && left.rows == right.rows
    }

    private static func sizeKey(_ size: ThreadCardSize) -> String { "\(size.cols)x\(size.rows)" }

    private static func isPositiveSafeInteger(_ value: Int) -> Bool {
        value > 0 && value <= maximumSafeInteger
    }

    private static func positiveInteger(_ value: Int) -> Int { isPositiveSafeInteger(value) ? value : 1 }
}
