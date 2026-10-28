import AppKit
import SwiftUI
import Testing
import MokuseiTestSupport
import MokuseiPluginUI

@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized)
struct MarkdownRawSourceRenderingTests {
    @MainActor private final class Source: ObservableObject {
        @Published var text = "caf\u{e9}\n\n```\ncaf\u{e9}\n```"
    }
    private struct Reader: View {
        @ObservedObject var source: Source
        var body: some View { ThreadMessage(id: "unicode-audit", author: .assistant, content: source.text) }
    }
    private func texts(_ view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(texts)
    }
    @Test func mountedPlainAndCodeKeepRawBytes() async throws {
        let source = Source()
        let window = SwiftUIReplay.window(Reader(source: source), width: 700, height: 400)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { texts(root).count >= 2 }
        source.text = "cafe\u{301}\n\n```\ncafe\u{301}\n```"
        try await SwiftUIReplay.wait {
            texts(root).filter { $0.string.utf8.elementsEqual("cafe\u{301}".utf8) }.count >= 2
        }
    }
}
