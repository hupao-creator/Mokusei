import AppKit
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiUI

@MainActor @Suite(.serializedNative, .serialized, .requiresDisplay)
struct NativeMokuTalkClippingTests {
    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }

    @Test func selectableProseFitsTheNativeClipWithEitherScrollbarStyle() async throws {
        let reported = "正在移除 Overview 轮播模式及相关实现，同时协调保留普通相机和筛选功能。"
        let messages = [reported, String(repeating: "界", count: 160), String(repeating: "W", count: 160),
                        "中文 English e\u{301} 👩🏽‍💻 混合文本，完整保留末尾。", "一\n二\n三\n四\n五\n六"]
        for style in [NSScroller.Style.overlay, .legacy] {
            for width: CGFloat in [76, 160, 272, 434, 448, 476] {
                for (index, text) in messages.enumerated() {
                    let height = min(NativeMokuTalkTypography.maximumHeight,
                        NativeMokuTalkTypography.height(text, width: width - NativeMokuTalkTypography.scrollbarGutter(for: style)))
                    let host = NSHostingView(rootView: NativeMokuTalkContent(message: .init(id: "clipping", text: text), scrollbarStyle: style)
                        .foregroundStyle(.white).background(Color.gray)
                        .frame(width: width, height: max(20, height)))
                    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: max(20, height)),
                                          styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    window.orderFront(nil)
                    defer { window.close() }
                    host.layoutSubtreeIfNeeded()
                    let scroll = try #require(descendants(host, of: NSScrollView.self).first)
                    // Exercise both native modes locally, without writing the
                    // user's system preference or changing adjacent viewports.
                    scroll.scrollerStyle = style
                    scroll.autohidesScrollers = style == .overlay
                    scroll.verticalScroller?.controlSize = .mini
                    for _ in 0..<5 {
                        host.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    let label = try #require(descendants(host, of: NSTextField.self).first { $0.stringValue == text })
                    #expect(label.isSelectable && !label.isEditable)
                    // SwiftUI's selectable label includes a native 4pt field
                    // editor margin on either side, outside its text layout seat.
                    let prose = scroll.contentView.convert(label.bounds.insetBy(dx: 4, dy: 0), from: label)
                    #expect(prose.minX >= -0.5 && prose.maxX <= scroll.contentView.bounds.width + 0.5,
                            "Clipped prose: style \(style), width \(width), message \(index), prose \(prose), clip \(scroll.contentView.bounds)")
                    let document = try #require(scroll.documentView)
                    if height < NativeMokuTalkTypography.maximumHeight {
                        #expect(document.bounds.height <= scroll.contentView.bounds.height + 1)
                    } else if document.bounds.height > scroll.contentView.bounds.height + 1 {
                        scroll.contentView.scroll(to: CGPoint(x: 0, y: 0))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        #expect(abs(scroll.contentView.bounds.minY) <= 1)
                        scroll.contentView.scroll(to: CGPoint(x: 0, y: document.bounds.height - scroll.contentView.bounds.height))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        #expect(abs(scroll.contentView.bounds.maxY - document.bounds.height) <= 1)
                    }
                    if let directory = ProcessInfo.processInfo.environment["MOKU_TALK_CLIPPING_EVIDENCE"], index == 0, width == 448 {
                        let url = URL(fileURLWithPath: directory)
                        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        try #require(bitmap.representation(using: .png, properties: [:]))
                            .write(to: url.appendingPathComponent("reported-\(style == .legacy ? "legacy" : "overlay").png"))
                    }
                    window.close()
                }
            }
        }
    }
}
