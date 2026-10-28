import AppKit

// No windows, screens, event injection or preference writes. Compile this with
// the production NativeScrollView source, so this exercises real AppKit controls.
@main
struct ScrollbarReplay {
    @MainActor static func main() {
        let untouched = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        untouched.hasVerticalScroller = true
        let originalSize = untouched.verticalScroller?.controlSize
        let originalStyle = untouched.scrollerStyle

        for appearance in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            let scroll = NativeStyledScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
            scroll.appearance = NSAppearance(named: appearance)
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            let document = NSTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 1200))
            document.isHorizontallyResizable = true
            document.isVerticallyResizable = true
            document.string = String(repeating: "Selectable text\n", count: 100)
            scroll.documentView = document
            scroll.tile()
            scroll.contentView.scroll(to: NSPoint(x: 110, y: 240))
            scroll.reflectScrolledClipView(scroll.contentView)
            document.setSelectedRange(NSRange(location: 12, length: 4))
            let offset = scroll.contentView.bounds.origin
            let size = scroll.frame.size
            let selection = document.selectedRange()
            let clip = scroll.contentView
            let vertical = scroll.verticalScroller
            let horizontal = scroll.horizontalScroller

            for _ in 0..<20 {
                NativeScrollbarStyle.apply(to: scroll)
                scroll.tile()
            }
            precondition(scroll.documentView === document && scroll.contentView === clip)
            precondition(scroll.verticalScroller === vertical && scroll.horizontalScroller === horizontal)
            precondition(scroll.frame.size == size && scroll.contentView.bounds.origin == offset)
            precondition(document.selectedRange() == selection)
            precondition(scroll.hasVerticalScroller && scroll.hasHorizontalScroller)
            precondition(scroll.verticalScroller?.controlSize == .mini && scroll.horizontalScroller?.controlSize == .mini)
            precondition(scroll.scrollerStyle == NSScroller.preferredScrollerStyle && scroll.autohidesScrollers)
            precondition(scroll.verticalScroller?.target as? NSScrollView === scroll)
            precondition(scroll.horizontalScroller?.target as? NSScrollView === scroll)

            // Native scrolling still reaches both ends and preserves text selection.
            scroll.contentView.scroll(to: NSPoint(x: 500, y: 800))
            scroll.reflectScrolledClipView(scroll.contentView)
            precondition(scroll.contentView.bounds.minX > offset.x && scroll.contentView.bounds.minY > offset.y)
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            precondition(scroll.contentView.bounds.origin == .zero && document.selectedRange() == selection)

            scroll.hasHorizontalScroller = false
            NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
            precondition(!scroll.hasHorizontalScroller && scroll.hasVerticalScroller)
            precondition(scroll.scrollerStyle == NSScroller.preferredScrollerStyle)
        }
        precondition(untouched.verticalScroller?.controlSize == originalSize && untouched.scrollerStyle == originalStyle)
        print("PASS: four appearances; native axes, targets, selection, offsets, idempotence and scoped preference updates (headless)")
    }
}
