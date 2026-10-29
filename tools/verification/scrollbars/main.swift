import AppKit

// No windows, screens, event injection or preference writes. Compile this with
// the production NativeScrollView source, so this exercises real AppKit controls.
@main
struct ScrollbarReplay {
    @MainActor static func main() async throws {
        // Record the branch the runner's preference selected; knob visibility
        // and gutter reservations differ between them.
        print("Preferred scroller style: \(NSScroller.preferredScrollerStyle == .legacy ? "legacy" : "overlay")")
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
            precondition(scroll.scrollerStyle == NSScroller.preferredScrollerStyle)
            precondition(scroll.autohidesScrollers == NativeScrollbarStyle.autohidesScrollers(for: scroll.scrollerStyle))
            precondition(scroll.verticalScroller?.target as? NSScrollView === scroll)
            precondition(scroll.horizontalScroller?.target as? NSScrollView === scroll)
            for scroller in [vertical, horizontal].compactMap({ $0 }) {
                precondition(scroller is NativeTracklessScroller)
                precondition(scroller.action != nil && scroller.accessibilityRole() == .scrollBar)
                for style in [NSScroller.Style.legacy, .overlay] {
                    scroller.scrollerStyle = style
                    // Draw the real production slot into an offscreen bitmap.
                    // Both normal and highlighted tracks must leave it untouched.
                    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 80,
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = context
                    NSColor.clear.setFill()
                    NSRect(x: 0, y: 0, width: 24, height: 80).fill(using: .copy)
                    for highlight in [false, true] {
                        scroller.drawKnobSlot(in: NSRect(x: 0, y: 0, width: 24, height: 80), highlight: highlight)
                    }
                    NSGraphicsContext.restoreGraphicsState()
                    for y in 0..<80 {
                        for x in 0..<24 { precondition(bitmap.colorAt(x: x, y: y)!.alphaComponent == 0) }
                    }
                }
                scroller.scrollerStyle = scroll.scrollerStyle
            }
            NativeScrollbarStyle.apply(to: scroll)

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
        // Styling an already-scrolled plain viewport must retain its content and
        // selection too, including when it has no enabled indicators.
        let existing = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        existing.hasVerticalScroller = true
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 1200))
        text.string = String(repeating: "Keep selection\n", count: 100)
        existing.documentView = text
        existing.tile()
        existing.contentView.scroll(to: NSPoint(x: 0, y: 100))
        text.setSelectedRange(NSRange(location: 5, length: 4))
        let offset = existing.contentView.bounds.origin
        NativeScrollbarStyle.apply(to: existing)
        existing.tile()
        precondition(existing.contentView.bounds.origin == offset && text.selectedRange() == NSRange(location: 5, length: 4))
        existing.hasVerticalScroller = false
        NativeScrollbarStyle.apply(to: existing)
        precondition(!existing.hasVerticalScroller && !existing.hasHorizontalScroller)
        precondition(NativeTracklessScroller.isCompatibleWithOverlayScrollers)
        checkGutterStability()
        print("PASS: four appearances; transparent normal/highlighted tracks in both styles; stable legacy gutters across the overflow threshold in both axes; native axes, targets, accessibility role, selection, offsets, idempotence and scoped preference updates (headless)")
        try await ScrollControlReplay.run()
        try await WebScrollbarReplay.run()
    }

    // Overlay indicators float, but whichever style the system prefers must not
    // resize the viewport when content crosses the overflow threshold. Both axes
    // are checked at just below, exactly at, and just above that threshold.
    @MainActor private static func checkGutterStability() {
        precondition(NativeScrollbarStyle.autohidesScrollers(for: .legacy) == false)
        precondition(NativeScrollbarStyle.autohidesScrollers(for: .overlay) == true)

        let vertical = NativeStyledScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        vertical.hasVerticalScroller = true
        let verticalDocument = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 180))
        vertical.documentView = verticalDocument
        vertical.tile()
        let verticalClip = vertical.contentView.frame.width
        let verticalScroller = vertical.verticalScroller
        precondition(verticalScroller is NativeTracklessScroller)
        let legacy = vertical.scrollerStyle == .legacy
        if legacy {
            precondition(verticalClip < vertical.frame.width)
            precondition(!(verticalScroller?.isHidden ?? true))
        }
        for height in [CGFloat(180), 359, 360, 361, 900, 180, 360] {
            verticalDocument.frame.size.height = height
            vertical.tile()
            precondition(vertical.contentView.frame.width == verticalClip, "vertical gutter changed at content height \(height)")
            // The resident scroller must paint only while content can scroll; a
            // stale knobProportion after shrinking is not a rendered knob.
            // Overlay indicators instead fade until the user scrolls, and AppKit
            // owns that paint, so only a resident legacy scroller has a knob to
            // observe at rest. Both styles must leave a resting viewport blank
            // at the same threshold.
            let overflowing = height > vertical.contentSize.height
            if legacy {
                precondition((scrollerInk(verticalScroller!) > 0) == overflowing,
                             "vertical knob did not follow overflow at content height \(height)")
            } else {
                precondition(scrollerInk(verticalScroller!) == 0,
                             "overlay scroller painted at rest at content height \(height)")
            }
        }
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        vertical.tile()
        precondition(vertical.contentView.frame.width == verticalClip)
        precondition(vertical.autohidesScrollers == NativeScrollbarStyle.autohidesScrollers(for: vertical.scrollerStyle))

        let horizontal = NativeStyledScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        horizontal.hasHorizontalScroller = true
        let horizontalDocument = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 360))
        horizontal.documentView = horizontalDocument
        horizontal.tile()
        let horizontalClip = horizontal.contentView.frame.height
        for width in [CGFloat(320), 639, 640, 641, 1200, 320] {
            horizontalDocument.frame.size.width = width
            horizontal.tile()
            precondition(horizontal.contentView.frame.height == horizontalClip,
                         "horizontal gutter changed at content width \(width)")
        }

        // Overlay indicators never consume layout space, in either autohide state.
        let overlay = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        overlay.hasVerticalScroller = true
        overlay.scrollerStyle = .overlay
        overlay.autohidesScrollers = NativeScrollbarStyle.autohidesScrollers(for: .overlay)
        let overlayDocument = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 180))
        overlay.documentView = overlayDocument
        overlay.tile()
        for height in [CGFloat(180), 360, 361, 900] {
            overlayDocument.frame.size.height = height
            overlay.tile()
            precondition(overlay.contentView.frame.width == overlay.frame.width,
                         "overlay scroller consumed layout at content height \(height)")
        }
    }

    // Draw the production scroller offscreen and count painted pixels. An empty
    // legacy knob and the suppressed slot must leave the bitmap untouched.
    @MainActor private static func scrollerInk(_ scroller: NSScroller) -> Int {
        guard let bitmap = scroller.bitmapImageRepForCachingDisplay(in: scroller.bounds) else { return 0 }
        scroller.cacheDisplay(in: scroller.bounds, to: bitmap)
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.02 { count += 1 }
            }
        }
        return count
    }
}
