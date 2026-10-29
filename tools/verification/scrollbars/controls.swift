import AppKit
import SwiftUI

@MainActor private final class ScrollControlDraft: ObservableObject {
    @Published var text = String(repeating: "Styled editor line\n", count: 100)
    @Published var showsEditor = true
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
                List(0..<80) { row in Text("Row \(row)") }
                    .nativeControlScrollbars().listStyle(.plain).frame(height: 90)
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
        draft.showsEditor = false
        await layout(host)
        draft.showsEditor = true
        await layout(host)
        let recreated = descendants(host, of: NSScrollView.self).first { ($0.documentView as? NSTextView)?.string.hasPrefix("Styled editor") == true }!
        precondition(recreated.verticalScroller is NativeTracklessScroller)
        precondition(plainScroll.verticalScroller === plainScroller && !(plainScroller is NativeTracklessScroller))
        precondition(host.window == nil)
        print("PASS: windowless SwiftUI overflowing TextEditor/List, nested viewport isolation, native targets/AX role, editor binding, selection/offset retention, preference notification and control replacement")
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
