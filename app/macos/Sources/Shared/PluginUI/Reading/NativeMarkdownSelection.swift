import AppKit

/// Independent layouts in one document share selection focus, while AppKit
/// still chooses the active/inactive appearance for the window and application.
class MarkdownSelectionLayoutManager: NSLayoutManager {
    override func layoutManagerOwnsFirstResponder(in window: NSWindow) -> Bool {
        if super.layoutManagerOwnsFirstResponder(in: window) { return true }
        // These layouts are attached to displayed NSTextViews and are used only
        // on the main actor; NSLayoutManager's override is not actor-annotated.
        let view = firstTextView as? MarkdownTextView
        return MainActor.assumeIsolated {
            view?.selectionScopeOwnsFirstResponder(in: window) == true
        }
    }
}

/// A Markdown document contains independent text layouts (including horizontally
/// scrolling fences and table cells). This scope joins their native selections
/// for drag selection, Select All, and Copy without flattening their layout.
@MainActor
final class MarkdownSelectionScope {
    private static var scopes: [String: MarkdownSelectionScope] = [:]
    private let views = NSHashTable<MarkdownTextView>.weakObjects()
    private weak var anchor: MarkdownTextView?
    private weak var persistentAnchor: MarkdownTextView?
    private var persistentRange = NSRange(location: 0, length: 0)
    private var anchorIndex = 0
    private var anchorRange = NSRange(location: 0, length: 0)
    private var granularity: NSSelectionGranularity = .selectByCharacter
    private var joined = false
    private var applyingSelection = false

    static func register(_ view: MarkdownTextView, id: String) -> MarkdownSelectionScope {
        let scope = scopes[id] ?? MarkdownSelectionScope()
        scopes[id] = scope; scope.views.add(view)
        if view.markdownHasFocus { scope.invalidateSelectionAppearance() }
        // Dead conversation views do not leave an unbounded registry behind.
        for key in scopes.keys where scopes[key]?.views.allObjects.isEmpty == true { scopes.removeValue(forKey: key) }
        return scope
    }

    func unregister(_ view: MarkdownTextView) {
        views.remove(view)
        view.setDocumentSelectionActive(false)
        if anchor === view { end() }
        if view.markdownHasFocus { invalidateSelectionAppearance() }
    }

    func ownsFirstResponder(in window: NSWindow) -> Bool {
        guard let view = window.firstResponder as? MarkdownTextView,
              view.window === window, !view.isHiddenOrHasHiddenAncestor else { return false }
        return views.contains(view)
    }


    func invalidateSelectionAppearance() {
        for view in views.allObjects where view.markdownSelectedRange.length > 0 { view.invalidateSelectionAppearance() }
    }

    private var orderedViews: [MarkdownTextView] {
        views.allObjects.filter { $0.window != nil && !$0.markdownHidden }.sorted { lhs, rhs in
            let left = lhs.convert(lhs.bounds, to: nil), right = rhs.convert(rhs.bounds, to: nil)
            if abs(left.maxY - right.maxY) > 2 { return left.maxY > right.maxY }
            return left.minX < right.minX
        }
    }

    func begin(_ view: MarkdownTextView, event: NSEvent) {
        end(); joined = false
        if event.modifierFlags.contains(.shift), let persistentAnchor {
            anchor = persistentAnchor; anchorRange = persistentRange; granularity = .selectByCharacter
            extend(to: event.locationInWindow); return
        }
        for other in views.allObjects where other !== view { other.setMarkdownSelectedRange(NSRange(location: 0, length: 0)) }
        anchor = view
        anchorIndex = view.characterIndexForInsertion(at: view.convert(event.locationInWindow, from: nil))
        granularity = event.clickCount >= 3 ? .selectByParagraph : event.clickCount == 2 ? .selectByWord : .selectByCharacter
        anchorRange = view.selectionRange(forProposedRange: NSRange(location: anchorIndex, length: 0), granularity: granularity)
        view.setMarkdownSelectedRange(anchorRange)
        persistentAnchor = view; persistentRange = anchorRange
    }

    func end() { anchor = nil }

    func extend(to point: NSPoint) {
        guard let anchor else { return }
        let ordered = orderedViews
        guard let first = ordered.firstIndex(where: { $0 === anchor }) else { return }
        let destination = ordered.enumerated().min { lhs, rhs in distance(point, from: lhs.element) < distance(point, from: rhs.element) }
        guard let destination else { return }
        let last = destination.offset
        joined = first != last
        let target = destination.element
        let targetIndex = min(target.string.utf16.count, target.characterIndexForInsertion(at: target.convert(point, from: nil)))
        let targetRange = target.selectionRange(forProposedRange: NSRange(location: targetIndex, length: 0), granularity: granularity)
        for (index, view) in ordered.enumerated() {
            let length = view.markdownString.utf16.count
            let range: NSRange
            if first == last, index == first {
                let start = min(anchorRange.location, targetRange.location)
                range = NSRange(location: start, length: max(NSMaxRange(anchorRange), NSMaxRange(targetRange)) - start)
            } else if index < min(first, last) || index > max(first, last) {
                range = NSRange(location: 0, length: 0)
            } else if index == first {
                range = first < last ? NSRange(location: min(anchorRange.location, length), length: max(0, length - anchorRange.location))
                    : NSRange(location: 0, length: min(NSMaxRange(anchorRange), length))
            } else if index == last {
                range = first < last ? NSRange(location: 0, length: NSMaxRange(targetRange))
                    : NSRange(location: targetRange.location, length: length - targetRange.location)
            } else { range = NSRange(location: 0, length: length) }
            view.setMarkdownSelectedRange(range)
        }
    }

    private func distance(_ point: NSPoint, from view: NSView) -> CGFloat {
        let frame = view.convert(view.bounds, to: nil)
        let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
        let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
        return dy * 10_000 + dx
    }


    func clearOtherSelections(keeping view: MarkdownTextView) {
        guard !applyingSelection else { return }
        joined = false
        for other in views.allObjects {
            other.setDocumentSelectionActive(false)
            if other !== view { other.setMarkdownSelectedRange(NSRange(location: 0, length: 0)) }
        }
    }

    var hasJoinedSelection: Bool { joined && orderedViews.contains { $0.markdownSelectedRange.length > 0 } }

    func canSelectAll() -> Bool {
        orderedViews.contains { $0.markdownSelectedRange != NSRange(location: 0, length: $0.markdownString.utf16.count) }
    }

    func selectAll() {
        applyingSelection = true
        defer { applyingSelection = false }
        joined = true
        for view in orderedViews {
            view.setMarkdownSelectedRange(NSRange(location: 0, length: view.markdownString.utf16.count))
            view.setDocumentSelectionActive(true)
        }
    }

    func copy() -> Bool {
        guard joined else { return false }
        var result = ""
        var previous: MarkdownTextView?
        for view in orderedViews {
            let range = view.markdownSelectedRange
            guard range.length > 0, NSMaxRange(range) <= view.markdownString.utf16.count else { continue }
            if let previous {
                let first = previous.convert(previous.bounds, to: nil)
                let second = view.convert(view.bounds, to: nil)
                result += abs(first.maxY - second.maxY) <= 2 ? "\t" : "\n"
            }
            if let storage = view.markdownStorage {
                result += storage.attributedSubstring(from: range).markdownPlainText()
            } else { result += (view.markdownString as NSString).substring(with: range) }
            previous = view
        }
        guard !result.isEmpty else { return false }
        return MarkdownPlatformActions.copy(result)
    }
}
