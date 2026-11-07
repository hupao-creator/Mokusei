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

@MainActor private final class PlainViewportDraft: ObservableObject {
    @Published var height: CGFloat = 500
}

private struct PlainViewportFixture: View {
    @ObservedObject var draft: PlainViewportDraft
    let styled: Bool
    var body: some View {
        if styled { NativeScrollView { content } }
        else { ScrollView { content } }
    }
    private var content: some View {
        VStack(spacing: 0) {
            Text("Plain viewport")
            Color.clear.frame(height: draft.height)
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

        // SwiftUI owns this adapter's autohiding and initial width proposal.
        // Compare with an unstyled SwiftUI viewport, then change actual content
        // instead of overwriting the framework-owned native document frame.
        let viewportDraft = PlainViewportDraft()
        let viewportSize = NSSize(width: 360, height: 300)
        // A windowless hosting view has no parent supplying the SwiftUI layout
        // proposal. Pin both roots before testing content against that viewport.
        let plainHost = NSHostingView(rootView: PlainViewportFixture(draft: viewportDraft, styled: true)
            .frame(width: viewportSize.width, height: viewportSize.height))
        let referenceHost = NSHostingView(rootView: PlainViewportFixture(draft: viewportDraft, styled: false)
            .frame(width: viewportSize.width, height: viewportSize.height))
        for host in [plainHost, referenceHost] {
            host.frame = NSRect(origin: .zero, size: viewportSize)
            await layout(host)
        }
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        for (height, canScroll) in [(CGFloat(80), false), (900, true), (80, false)] {
            viewportDraft.height = height
            await layout(plainHost)
            await layout(referenceHost)
            let viewport = descendants(plainHost, of: NSScrollView.self).first!
            let reference = descendants(referenceHost, of: NSScrollView.self).first!
            let viewportScroller = viewport.verticalScroller!
            let viewportDocument = viewport.documentView!
            let geometry = "Plain viewport height=\(height) expectedOverflow=\(canScroll)\n"
                + viewportGeometry("styled", host: plainHost, scroll: viewport) + "\n"
                + viewportGeometry("reference", host: referenceHost, scroll: reference) + "\n"
            FileHandle.standardError.write(Data(geometry.utf8))
            for (host, scroll) in [(plainHost, viewport), (referenceHost, reference)] {
                precondition(host.bounds.size == viewportSize && scroll.frame.size == viewportSize,
                             "Plain viewport must retain its fixed SwiftUI layout proposal")
                precondition(scroll.contentSize.width > 0 && scroll.contentSize.width <= viewportSize.width
                             && scroll.contentSize.height > 0 && scroll.contentSize.height <= viewportSize.height,
                             "Plain viewport clip must remain inside its fixed viewport")
            }
            precondition(viewportScroller is NativeTracklessScroller)
            precondition(!(reference.verticalScroller is NativeTracklessScroller))
            precondition(viewport.scrollerStyle == NSScroller.preferredScrollerStyle)
            precondition(viewport.autohidesScrollers == reference.autohidesScrollers,
                         "plain viewport changed SwiftUI autohiding at document height \(height)")
            precondition((viewportDocument.frame.height > viewport.contentSize.height) == canScroll)
            // Only legacy indicators paint a knob at rest; AppKit owns overlay
            // fading. Preserve both branches while crossing the same threshold.
            if viewport.scrollerStyle == .legacy {
                precondition((scrollerInk(viewportScroller) > 0) == canScroll,
                             "plain viewport knob did not follow overflow at document height \(height)")
            } else {
                precondition(scrollerInk(viewportScroller) == 0,
                             "plain viewport overlay scroller painted at rest at document height \(height)")
            }
            // Loading longer content may allocate a legacy gutter. Once loaded,
            // scrolling must not change the clip or document-width proposal.
            let clipWidth = viewport.contentView.frame.width
            let documentWidth = viewportDocument.frame.width
            let positions: [CGFloat] = canScroll ? [100, 0] : [0]
            for y in positions {
                viewport.contentView.scroll(to: NSPoint(x: 0, y: y))
                viewport.reflectScrolledClipView(viewport.contentView)
                await layout(plainHost)
                precondition(viewport.contentView.bounds.origin == NSPoint(x: 0, y: y))
                precondition(viewport.contentView.frame.width == clipWidth && viewportDocument.frame.width == documentWidth,
                             "plain viewport changed loaded width after scrolling at document height \(height)")
            }
        }
        precondition(plainHost.window == nil && referenceHost.window == nil)
        print("PASS: windowless SwiftUI overflowing TextEditor/List, nested viewport isolation, native targets/AX role, editor binding, selection/offset retention, preference notification, control replacement, List threshold width and plain viewport SwiftUI autohiding/loaded-width retention")
    }

    private static func viewportGeometry(_ label: String, host: NSView, scroll: NSScrollView) -> String {
        "\(label): hostFrame=\(host.frame) hostBounds=\(host.bounds) scrollFrame=\(scroll.frame) "
            + "clipFrame=\(scroll.contentView.frame) clipBounds=\(scroll.contentView.bounds) contentSize=\(scroll.contentSize) "
            + "documentFrame=\(String(describing: scroll.documentView?.frame)) "
            + "scrollerFrame=\(String(describing: scroll.verticalScroller?.frame)) "
            + "knobProportion=\(String(describing: scroll.verticalScroller?.knobProportion)) "
            + "style=\(scroll.scrollerStyle.rawValue) autohides=\(scroll.autohidesScrollers)"
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
