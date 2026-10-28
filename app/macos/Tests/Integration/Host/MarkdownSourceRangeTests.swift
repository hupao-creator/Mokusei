import Foundation
import Testing
@testable import MokuseiPluginUI

struct MarkdownSourceRangeTests {
    private func spans(_ blocks: [MarkdownBlock]) -> [MarkdownSpan] {
        blocks.flatMap { block -> [MarkdownSpan] in
            switch block {
            case .paragraph(let spans), .heading(_, let spans): return spans
            case .quote(let children), .footnote(_, _, let children): return spans(children)
            case .list(let items): return items.flatMap { spans($0.blocks) }
            case .table(let rows, _): return rows.flatMap { $0.flatMap { $0 } }
            case .code(_, let source): return [MarkdownSpan(text: source, code: true)]
            case .rule: return []
            }
        }
    }

    private let prefixes = [
        "",
        "[x]: https://example.com/target\n",
        "[x]: /target\n[y]: /second\n",
        "[x]: /target trailing prose\n",
        "[two\nwords]: /target\n",
        "[x]: /café \"first\nsecond\"\n"
    ]

    private func nested(_ source: String, container: String) -> String {
        let lines = source.components(separatedBy: "\n")
        switch container {
        case "quote": return lines.map { "> " + $0 }.joined(separator: "\n")
        case "list": return lines.enumerated().map { ($0.offset == 0 ? "- " : "  ") + $0.element }.joined(separator: "\n")
        case "nested": return lines.enumerated().map { ($0.offset == 0 ? "> 1. " : ">    ") + $0.element }.joined(separator: "\n")
        default: return source
        }
    }

    @Test(arguments: ["root", "quote", "list", "nested"])
    func fullURLsAcrossBlockAndPrefixBoundaries(container: String) {
        let url = "https://example.com/a*b*c"
        for prefix in prefixes {
            for body in [url, "多字节\t\(url)", "多字节 e\u{301} \(url)\nnext", "\(url)  \nnext",
                         "\(url)\n===", "\(url)\n---", "多字节 e\u{301}\n\(url)\n===",
                         "# \(url)", "## \(url) ##", "| URL |\n| --- |\n| \(url) |"] {
                for ending in ["", "\n", "\r\n"] {
                    var source = nested(prefix + body, container: container) + ending
                    if ending == "\r\n" { source = source.replacingOccurrences(of: "\n", with: "\r\n").replacingOccurrences(of: "\r\r\n", with: "\r\n") }
                    let result = spans(MarkdownParser.parse(source).blocks)
                    #expect(result.contains { $0.link == url }, "source: \(source.debugDescription)")
                    #expect(!result.contains { $0.emphasis }, "source: \(source.debugDescription)")
                }
            }
        }
    }

    @Test(arguments: ["root", "quote", "list", "nested"])
    func literalCodeAndLinksDoNotExposeFootnoteTokens(container: String) {
        for prefix in prefixes {
            for body in ["`literal [^n]` and real[^n].", "`literal [^n]` and real[^n].\n===",
                         "`literal [^n]` and real[^n].\n---", "# `literal [^n]` and real[^n].",
                         "多字节 e\u{301}\n`literal [^n]` and real[^n].\n===",
                         "`literal\n[^n]` and real[^n].\n===",
                         "| Code | Note |\n| --- | --- |\n| `literal [^n]` | real[^n] |"] {
                let source = nested(prefix + body, container: container) + "\n\n[^n]: note"
                let result = spans(MarkdownParser.parse(source).blocks)
                #expect(result.contains { $0.code && $0.text == "literal [^n]" }, "source: \(source.debugDescription)")
                #expect(result.filter(\.superscript).count == 1, "source: \(source.debugDescription)")
                #expect(!result.contains { $0.text.contains("\u{E000}mokusei-") }, "source: \(source.debugDescription)")
            }
        }
    }

    @Test(arguments: ["", "\n", "\n\n", "\nnext", "\n===", "\n---", "\n# next", "\n> next", "\n[x]: /next"])
    func setextEndingAndFollowingBlockBoundaries(suffix: String) {
        let url = "https://example.com/a*b*c"
        for prefix in prefixes {
            for body in [url, "=\n" + url, "多字节\n" + url] {
                let source = prefix + body + "\n===" + suffix
                let result = spans(MarkdownParser.parse(source).blocks)
                #expect(result.contains { $0.link == url }, "source: \(source.debugDescription)")
            }
        }
    }

    @Test(arguments: ["root", "quote", "list", "nested"])
    func multilineHTMLProtectsLiteralFootnoteSyntax(container: String) {
        for prefix in prefixes {
            for underline in ["", "\n==="] {
                let body = "text <span\ntitle=\"[^n]\">body</span> and real[^n]." + underline
                let source = nested(prefix + body, container: container) + "\n\n[^n]: note"
                let result = spans(MarkdownParser.parse(source).blocks)
                #expect(result.contains { $0.text.contains("title=\"[^n]\"") }, "source: \(source.debugDescription)")
                #expect(result.filter(\.superscript).count == 1, "source: \(source.debugDescription)")
                #expect(!result.contains { $0.text.contains("\u{E000}mokusei-") }, "source: \(source.debugDescription)")
            }
        }
    }

    @Test(arguments: ["> ", "- ", "> 1. "])
    func lazyMultilineCodeKeepsAdjacentRealFootnote(prefix: String) {
        for delimiter in ["`", "``", "```"] {
            let source = prefix + "text " + delimiter + "literal\n[^n]" + delimiter + "[^n]\n\n[^n]: note"
            let result = spans(MarkdownParser.parse(source).blocks)
            #expect(result.contains { $0.code && $0.text == "literal [^n]" }, "source: \(source.debugDescription)")
            #expect(result.filter(\.superscript).count == 1, "source: \(source.debugDescription)")
            #expect(!result.contains { $0.text.contains("\u{E000}mokusei-") }, "source: \(source.debugDescription)")
        }
    }

    @Test func fencedCodeAndExplicitLinksRemainLiteral() {
        let source = """
        [x]: /target
        ```text
        https://example.com/a*b*c and [^n]
        ```

        [literal [^n]](https://example.com/a*b*c) and real[^n].

        [^n]: note
        """
        let result = spans(MarkdownParser.parse(source).blocks)
        #expect(result.contains { $0.code && $0.text.contains("https://example.com/a*b*c and [^n]") })
        #expect(result.contains { $0.link == "https://example.com/a*b*c" && $0.text == "literal [^n]" })
        #expect(result.filter(\.superscript).count == 1)
        #expect(!result.contains { $0.text.contains("\u{E000}mokusei-") })
    }
}
