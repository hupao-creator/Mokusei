import Foundation
import Testing
@testable import MokuseiPluginUI

struct MarkdownSourceIdentityTests {
    @Test func spacedCaretLabelsRemainOrdinaryReferenceLinks() {
        let document = MarkdownParser.parse("""
        First[^two words] and tab[^two\tparts] and next[^next line] and second[^one].

        [^two words]: https://example.com/space
        [^two\tparts]: https://example.com/tab
        [^next line]:
          https://example.com/next
        [^one]: EXPECT_ONE
        """)
        guard case .paragraph(let spans) = document.blocks.first else {
            Issue.record("Missing paragraph"); return
        }
        #expect(spans.contains { $0.link == "https://example.com/space" })
        #expect(spans.contains { $0.link == "https://example.com/tab" })
        #expect(spans.contains { $0.link == "https://example.com/next" })
        #expect(spans.filter(\.superscript).count == 1)
        #expect(document.blocks.contains {
            if case .footnote(_, _, let blocks) = $0,
               case .paragraph(let spans) = blocks.first {
                return spans.filter { $0.link == nil }.map(\.text).joined() == "EXPECT_ONE"
            }
            return false
        })
    }

    @Test func canonicalEquivalenceDoesNotReplaceSourceBytes() async throws {
        let nfc = "[caf\u{e9}](http://127.0.0.1/caf\u{e9})\n\n```\ncaf\u{e9}\n```"
        let nfd = "[cafe\u{301}](http://127.0.0.1/cafe\u{301})\n\n```\ncafe\u{301}\n```"
        #expect(nfc == nfd)
        let parser = NativeMarkdownParser()
        let first = try await parser.parse(nfc)
        let second = try await parser.parse(nfd)
        let again = try await parser.parse(nfd)
        let direct = MarkdownParser.parse(nfd)
        #expect(first.blocks != second.blocks)
        #expect(second.blocks == direct.blocks)
        #expect(again.blocks == direct.blocks)
        #expect(second.sourceBytes == nfd.utf8.count)
        guard case .paragraph(let spans) = second.blocks.first else {
            Issue.record("Missing paragraph"); return
        }
        #expect(spans.first?.text.utf8.elementsEqual("cafe\u{301}".utf8) == true)
        #expect(spans.first?.link?.utf8.elementsEqual("http://127.0.0.1/cafe\u{301}".utf8) == true)
        #expect(MarkdownRevision(text: nfc, streaming: false, token: nil) !=
                MarkdownRevision(text: nfd, streaming: false, token: nil))
        #expect(MarkdownBlock.code(language: "", source: "\u{e9}") !=
                MarkdownBlock.code(language: "", source: "e\u{301}"))
    }
}
