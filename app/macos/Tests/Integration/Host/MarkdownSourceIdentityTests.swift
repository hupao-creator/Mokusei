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

    @Test(arguments: [
        "ordinary text\n[x]: https://example.com/a*b*c",
        "[x]: https://example.com/a*b*c trailing prose",
        "[x]:\nhttps://example.com/a*b*c trailing prose"
    ]) func referenceLikeProseRetainsBareURL(_ source: String) {
        let document = MarkdownParser.parse(source)
        guard case .paragraph(let spans) = document.blocks.first else {
            Issue.record("Missing prose paragraph"); return
        }
        #expect(spans.contains { $0.link == "https://example.com/a*b*c" })
        #expect(!spans.contains { $0.emphasis })
    }

    @Test(arguments: [
        "Use [^two words].\n\n[^two\nwords]: https://example.com/a*b*c",
        "Use [^two words].\n\n[^two words]: https://example.com/a*b*c \"first\nhttps://example.com/title*x*y\nlast\"",
        "Use [^two words].\n\n[^two words]: https://example.com/a*b*c\n  \"https://example.com/title*x*y\""
    ]) func multilineReferenceDefinitionsRetainDestinationAndTitle(_ source: String) {
        let document = MarkdownParser.parse(source)
        guard case .paragraph(let spans) = document.blocks.first,
              let link = spans.first(where: { $0.link != nil }) else {
            Issue.record("Missing reference link"); return
        }
        #expect(link.link == "https://example.com/a*b*c")
        if source.contains("title*x*y") {
            #expect(link.title?.contains("https://example.com/title*x*y") == true)
            #expect(link.title?.contains("[https:") == false)
        }
    }

    @Test func definitionPrefixDoesNotShiftVisibleProseRanges() {
        let document = MarkdownParser.parse("Use [x].\n\n[x]: https://example.com/a*b*c\nordinary https://example.com/d*e*f")
        let spans = document.blocks.flatMap { block -> [MarkdownSpan] in
            if case .paragraph(let spans) = block { return spans }
            return []
        }
        #expect(spans.contains { $0.link == "https://example.com/a*b*c" })
        #expect(spans.contains { $0.link == "https://example.com/d*e*f" })
        #expect(!spans.contains { $0.emphasis })
    }

    @Test func extractedFootnoteRetainsCompleteBareURL() {
        let document = MarkdownParser.parse("Note[^one].\n\n[^one]: https://example.com/a*b*c")
        let spans = document.blocks.flatMap { block -> [MarkdownSpan] in
            guard case .footnote(_, _, let children) = block else { return [] }
            return children.flatMap { child -> [MarkdownSpan] in
                if case .paragraph(let spans) = child { return spans }
                return []
            }
        }
        #expect(spans.contains { $0.link == "https://example.com/a*b*c" })
        #expect(!spans.contains { $0.emphasis })
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
