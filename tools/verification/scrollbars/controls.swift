import AppKit
import SwiftUI

@MainActor private final class ScrollControlDraft: ObservableObject {
    @Published var text = String(repeating: "Styled editor line\n", count: 100)
    @Published var showsEditor = true
    @Published var rowCount = 80
}

private struct ScrollControlFixture: View {
    @ObservedObject var draft: ScrollControlDraft
    var body: some View {
        NativeScrollView {
            VStack {
                if draft.showsEditor {
                    TextEditor(text: $draft.text).nativeControlScrollbars().frame(height: 70)
                }
                // A sibling inside the same timeline must not be opted in by a
                // marker attached to the editor or list above/below it.
                TextEditor(text: .constant("Unstyled sibling")).frame(height: 60)
                List {
                    ForEach(0..<draft.rowCount, id: \.self) { row in Text("Row \(row)") }
                }
                .nativeControlScrollbars().listStyle(.plain).frame(height: 90)
                Color.clear.frame(height: 500)
            }
        }
    }
}

private struct PlainViewportFixture: View {
    var body: some View {
        NativeScrollView {
            VStack(spacing: 0) {
                Text("Plain viewport")
                Color.clear.frame(height: 500)
            }
        }
    }
}

@MainActor enum ScrollControlReplay {
    static func run() async throws {
        let draft = ScrollControlDraft()
        let host = NSHostingView(rootView: ScrollControlFixture(draft: draft))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 300)
        await layout(host)
        let scrolls = descendants(host, of: NSScrollView.self)
        let editorScroll = scrolls.first { ($0.documentView as? NSTextView)?.string.hasPrefix("Styled editor") == true }!
        let plainScroll = scrolls.first { ($0.documentView as? NSTextView)?.string == "Unstyled sibling" }!
        let listScroll = scrolls.first { $0.documentView is NSTableView }!
        let editor = editorScroll.documentView as! NSTextView
        let table = listScroll.documentView as! NSTableView
        let plainScroller = plainScroll.verticalScroller
        precondition(editorScroll.documentView!.frame.height > editorScroll.contentSize.height)
        precondition(table.numberOfRows == 80 && table.frame.height > listScroll.contentSize.height)
        // Match the picker (a non-selection List), then exercise native row
        // selection explicitly without requiring a key window/focus session.
        table.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        precondition(table.selectedRowIndexes == IndexSet(integer: 4))
        for scroll in [editorScroll, listScroll] {
            precondition(scroll.verticalScroller is NativeTracklessScroller)
            precondition(scroll.verticalScroller?.target as? NSScrollView === scroll)
            precondition(scroll.verticalScroller?.action != nil && scroll.verticalScroller?.accessibilityRole() == .scrollBar)
            precondition(scroll.scrollerStyle == NSScroller.preferredScrollerStyle)
            precondition(scroll.autohidesScrollers == NativeScrollbarStyle.autohidesScrollers(for: scroll.scrollerStyle))
        }
        precondition(!(plainScroller is NativeTracklessScroller))
        editor.setSelectedRange(NSRange(location: 6, length: 4))
        editorScroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        listScroll.contentView.scroll(to: NSPoint(x: 0, y: 160))
        let editorOffset = editorScroll.contentView.bounds.origin
        let listOffset = listScroll.contentView.bounds.origin
        let styledScroller = editorScroll.verticalScroller
        for _ in 0..<3 {
            NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
            await layout(host)
        }
        precondition(editorScroll.verticalScroller === styledScroller)
        precondition(editorScroll.contentView.bounds.origin == editorOffset && listScroll.contentView.bounds.origin == listOffset)
        precondition(editor.selectedRange() == NSRange(location: 6, length: 4) && table.selectedRowIndexes == IndexSet(integer: 4))
        precondition(plainScroll.verticalScroller === plainScroller && !(plainScroller is NativeTracklessScroller))
        let end = NSRange(location: editor.string.utf16.count, length: 0)
        precondition(editor.shouldChangeText(in: end, replacementString: "Edited"))
        editor.replaceCharacters(in: end, with: "Edited"); editor.didChangeText()
        await layout(host)
        precondition(draft.text.hasSuffix("Edited"), "Native editor binding stopped updating")
        // Crossing the List's own overflow threshold must not resize its viewport.
        // SwiftUI may rebuild children, so re-find the control after each update.
        let stableListClip = listScroll.contentView.frame.width
        for count in [3, 80, 2, 80] {
            draft.rowCount = count
            await layout(host)
            let current = descendants(host, of: NSScrollView.self).first { $0.documentView is NSTableView }!
            precondition(current.contentView.frame.width == stableListClip,
                         "List gutter changed at row count \(count)")
            precondition(current.verticalScroller is NativeTracklessScroller)
            precondition(current.autohidesScrollers == NativeScrollbarStyle.autohidesScrollers(for: current.scrollerStyle))
        }
        draft.showsEditor = false
        await layout(host)
        draft.showsEditor = true
        await layout(host)
        let recreated = descendants(host, of: NSScrollView.self).first { ($0.documentView as? NSTextView)?.string.hasPrefix("Styled editor") == true }!
        precondition(recreated.verticalScroller is NativeTracklessScroller)
        precondition(plainScroll.verticalScroller === plainScroller && !(plainScroller is NativeTracklessScroller))
        precondition(host.window == nil)

        // The plain SwiftUI viewport adapter is the one the reading timeline
        // uses. A windowless hosting view does not perform the mount notification
        // that configures it, so request one explicitly, then drive the document
        // height across the overflow threshold as SwiftUI layout would.
        let plainHost = NSHostingView(rootView: PlainViewportFixture())
        plainHost.frame = NSRect(x: 0, y: 0, width: 360, height: 300)
        await layout(plainHost)
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        await layout(plainHost)
        let viewport = descendants(plainHost, of: NSScrollView.self).first!
        let viewportScroller = viewport.verticalScroller!
        precondition(viewportScroller is NativeTracklessScroller)
        precondition(viewport.autohidesScrollers == NativeScrollbarStyle.autohidesScrollers(for: viewport.scrollerStyle))
        let viewportClip = viewport.contentView.frame.width
        let viewportDocument = viewport.documentView!
        // As in the resident-scroller replay, only a legacy indicator paints a
        // knob at rest; overlay indicators stay blank until AppKit fades one in.
        let viewportLegacy = viewport.scrollerStyle == .legacy
        for (height, canScroll) in [(CGFloat(80), false), (900, true), (80, false)] {
            viewportDocument.frame = NSRect(x: 0, y: 0, width: viewportClip, height: height)
            viewport.tile()
            precondition(viewport.contentView.frame.width == viewportClip,
                         "plain viewport gutter changed at document height \(height)")
            if viewportLegacy {
                precondition((scrollerInk(viewportScroller) > 0) == canScroll,
                             "plain viewport knob did not follow overflow at document height \(height)")
            } else {
                precondition(scrollerInk(viewportScroller) == 0,
                             "plain viewport overlay scroller painted at rest at document height \(height)")
            }
        }
        precondition(plainHost.window == nil)
        print("PASS: windowless SwiftUI overflowing TextEditor/List, nested viewport isolation, native targets/AX role, editor binding, selection/offset retention, preference notification, control replacement, List threshold width and plain viewport adapter gutter")
    }

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

    private static func layout(_ host: NSView) async {
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
    private static func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }
}
