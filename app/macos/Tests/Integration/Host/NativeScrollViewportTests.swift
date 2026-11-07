import AppKit
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiPluginUI

@MainActor private final class PlainViewportDraft: ObservableObject {
    @Published var height: CGFloat = 500
    var styledContentHeight: CGFloat = 0
    var referenceContentHeight: CGFloat = 0
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
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    // Readiness observes delivered content geometry without
                    // publishing another SwiftUI update or changing the model.
                    if styled { draft.styledContentHeight = height }
                    else { draft.referenceContentHeight = height }
                }
        }
    }
}

@MainActor
@Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeScrollViewportTests {
    @Test func plainViewportKeepsSwiftUIAutohidingAndLoadedWidths() async throws {
        let draft = PlainViewportDraft()
        let viewportSize = NSSize(width: 360, height: 300)
        // Pure SwiftUI scroll documents need a mounted display lifecycle. An
        // unattached NSHostingView can expose its scroll view with a 0×0 document.
        let plainWindow = SwiftUIReplay.window(PlainViewportFixture(draft: draft, styled: true),
                                               width: viewportSize.width, height: viewportSize.height)
        let referenceWindow = SwiftUIReplay.window(PlainViewportFixture(draft: draft, styled: false),
                                                   width: viewportSize.width, height: viewportSize.height)
        defer { plainWindow.close(); referenceWindow.close() }
        let availableFrame = try #require(plainWindow.screen).visibleFrame
        plainWindow.setFrameOrigin(availableFrame.origin)
        referenceWindow.setFrameOrigin(NSPoint(x: plainWindow.frame.maxX + 12, y: plainWindow.frame.minY))
        try #require(availableFrame.contains(plainWindow.frame) && availableFrame.contains(referenceWindow.frame)
                     && !plainWindow.frame.intersects(referenceWindow.frame),
                     "Both scroll viewport fixtures must be visible without occluding each other")
        let plainHost = try #require(plainWindow.contentView)
        let referenceHost = try #require(referenceWindow.contentView)
        try #require(plainHost.window === plainWindow && referenceHost.window === referenceWindow
                     && plainWindow.isVisible && referenceWindow.isVisible)
        do {
            try await waitForDocuments(height: draft.height, canScroll: true, draft: draft,
                                       plainHost: plainHost, referenceHost: referenceHost)
        } catch {
            logGeometry(height: draft.height, canScroll: true, draft: draft, plainHost: plainHost, referenceHost: referenceHost)
            throw error
        }
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)

        for (height, canScroll) in [(CGFloat(80), false), (900, true), (80, false)] {
            draft.height = height
            do {
                try await waitForDocuments(height: height, canScroll: canScroll, draft: draft,
                                           plainHost: plainHost, referenceHost: referenceHost)
                let viewport = try #require(descendants(plainHost, of: NSScrollView.self).first)
                let reference = try #require(descendants(referenceHost, of: NSScrollView.self).first)
                let viewportScroller = try #require(viewport.verticalScroller)
                let viewportDocument = try #require(viewport.documentView)
                logGeometry(height: height, canScroll: canScroll, draft: draft, plainHost: plainHost, referenceHost: referenceHost)
                for (host, scroll) in [(plainHost, viewport), (referenceHost, reference)] {
                    try #require(host.bounds.size == viewportSize && scroll.frame.size == viewportSize,
                                 "Plain viewport must retain its fixed SwiftUI layout proposal")
                    try #require(scroll.contentSize.width > 0 && scroll.contentSize.width <= viewportSize.width
                                 && scroll.contentSize.height > 0 && scroll.contentSize.height <= viewportSize.height,
                                 "Plain viewport clip must remain inside its fixed viewport")
                }
                try #require(viewportScroller is NativeTracklessScroller)
                try #require(!(reference.verticalScroller is NativeTracklessScroller))
                try #require(viewport.scrollerStyle == NSScroller.preferredScrollerStyle)
                try #require(viewport.autohidesScrollers == reference.autohidesScrollers,
                             "plain viewport changed SwiftUI autohiding at document height \(height)")
                try #require((viewportDocument.frame.height > viewport.contentSize.height) == canScroll)
                // Only legacy indicators paint a knob at rest; AppKit owns
                // overlay fading. Keep both branches across the same threshold.
                if viewport.scrollerStyle == .legacy {
                    try #require((scrollerInk(viewportScroller) > 0) == canScroll,
                                 "plain viewport knob did not follow overflow at document height \(height)")
                } else {
                    try #require(scrollerInk(viewportScroller) == 0,
                                 "plain viewport overlay scroller painted at rest at document height \(height)")
                }
                let clipWidth = viewport.contentView.frame.width
                let documentWidth = viewportDocument.frame.width
                let positions: [CGFloat] = canScroll ? [100, 0] : [0]
                for y in positions {
                    viewport.contentView.scroll(to: NSPoint(x: 0, y: y))
                    viewport.reflectScrolledClipView(viewport.contentView)
                    try await SwiftUIReplay.wait { viewport.contentView.bounds.origin == NSPoint(x: 0, y: y) }
                    try #require(viewport.contentView.bounds.origin == NSPoint(x: 0, y: y))
                    try #require(viewport.contentView.frame.width == clipWidth && viewportDocument.frame.width == documentWidth,
                                 "plain viewport changed loaded width after scrolling at document height \(height)")
                }
            } catch {
                logGeometry(height: height, canScroll: canScroll, draft: draft, plainHost: plainHost, referenceHost: referenceHost)
                throw error
            }
        }
    }

    private func waitForDocuments(height: CGFloat, canScroll: Bool, draft: PlainViewportDraft,
                                  plainHost: NSView, referenceHost: NSView) async throws {
        try await SwiftUIReplay.wait {
            guard draft.styledContentHeight == height, draft.referenceContentHeight == height,
                  let styled = descendants(plainHost, of: NSScrollView.self).first,
                  let reference = descendants(referenceHost, of: NSScrollView.self).first,
                  styled.verticalScroller is NativeTracklessScroller,
                  let referenceScroller = reference.verticalScroller,
                  !(referenceScroller is NativeTracklessScroller) else { return false }
            return [styled, reference].allSatisfy { scroll in
                guard let document = scroll.documentView else { return false }
                return document.frame.width > 0 && document.frame.height > 0
                    && scroll.contentSize.width > 0 && scroll.contentSize.height > 0
                    && (document.frame.height > scroll.contentSize.height) == canScroll
            }
        }
    }

    private func logGeometry(height: CGFloat, canScroll: Bool, draft: PlainViewportDraft,
                             plainHost: NSView, referenceHost: NSView) {
        var geometry = "Plain viewport height=\(height) expectedOverflow=\(canScroll) "
            + "styledContentHeight=\(draft.styledContentHeight) referenceContentHeight=\(draft.referenceContentHeight)\n"
        for (label, host) in [("styled", plainHost), ("reference", referenceHost)] {
            guard let scroll = descendants(host, of: NSScrollView.self).first else {
                geometry += "\(label): hostFrame=\(host.frame) hostBounds=\(host.bounds) scrollView=missing\n"
                continue
            }
            geometry += "\(label): hostFrame=\(host.frame) hostBounds=\(host.bounds) scrollFrame=\(scroll.frame) "
                + "clipFrame=\(scroll.contentView.frame) clipBounds=\(scroll.contentView.bounds) contentSize=\(scroll.contentSize) "
                + "documentFrame=\(String(describing: scroll.documentView?.frame)) "
                + "scrollerFrame=\(String(describing: scroll.verticalScroller?.frame)) "
                + "knobProportion=\(String(describing: scroll.verticalScroller?.knobProportion)) "
                + "style=\(scroll.scrollerStyle.rawValue) autohides=\(scroll.autohidesScrollers)\n"
        }
        FileHandle.standardError.write(Data(geometry.utf8))
    }

    private func scrollerInk(_ scroller: NSScroller) -> Int {
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

    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }
}
