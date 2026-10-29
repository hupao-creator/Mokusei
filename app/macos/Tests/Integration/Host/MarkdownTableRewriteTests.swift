import Testing
@testable import MokuseiPluginUI

struct MarkdownTableRewriteTests {
    private func spans(_ blocks: [MarkdownBlock]) -> [MarkdownSpan] {
        blocks.flatMap { block -> [MarkdownSpan] in
            switch block {
            case .paragraph(let s), .heading(_, let s): return s
            case .quote(let children), .footnote(_, _, let children): return spans(children)
            case .list(let items): return items.flatMap { spans($0.blocks) }
            case .table(let rows, _): return rows.flatMap { $0.flatMap { $0 } }
            case .code(_, let text): return [MarkdownSpan(text: text, code: true)]
            default: return []
            }
        }
    }
    private func wrap(_ source: String, prefix: String) -> String {
        let continuation = prefix.replacingOccurrences(of: "-", with: " ")
        return source.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            .map { ($0.offset == 0 ? prefix : continuation) + $0.element }.joined(separator: "\n")
    }

    @Test(arguments: ["", "   ", "> ", "- ", "> - "])
    func precedingParagraphAndHeaderKeepTheirOwnProvenance(prefix: String) {
        let url = "https://example.com/a*b*c"
        for lead in ["lead", "lead\ncontinued", "lead `prefix [^n]` and real[^n].",
                     "lead <span title=\"[^n]\"> and real[^n].", "lead <span\ntitle=\"[^n]\"> and real[^n].",
                     "lead `prefix\n[^n]` and real[^n].", "lead https://example.com/prefix*a*b",
                     "lead https://example.com/prefix\\|a*b"] {
            for gap in ["\n", "\n\n"] {
                for indent in 0...3 {
                    let table = String(repeating: " ", count: indent) + "| [^n]`literal [^n]` | URL |\n| --- | --- |\n| nul\0 | " + url + " |"
                    let source = "\u{FEFF}" + wrap(lead + gap + table, prefix: prefix) + "\n\n[^n]: note"
                    let result = spans(MarkdownParser.parse(source).blocks)
                    // After a blank line, four or more root spaces form a code
                    // block rather than a table header; keep this literal control.
                    let indentedCode = prefix == "   " && gap == "\n\n" && indent > 0
                    let notes = (lead.contains("and real") ? 1 : 0) + (indentedCode ? 0 : 1)
                    #expect(result.filter(\.superscript).count == notes, "source: \(source.debugDescription)")
                    if indentedCode {
                        #expect(result.contains { $0.code && $0.text.contains("[^n]`literal [^n]`") }, "source: \(source.debugDescription)")
                    } else {
                        #expect(result.contains { $0.code && $0.text == "literal [^n]" }, "source: \(source.debugDescription)")
                    }
                    #expect(result.contains { $0.link == url }, "source: \(source.debugDescription)")
                    #expect(!result.contains { $0.text.contains("\u{E000}mokusei-") }, "source: \(source.debugDescription)")
                    if lead.contains("https:") {
                        let target = lead.contains("\\|") ? "https://example.com/prefix|a*b" : "https://example.com/prefix*a*b"
                        #expect(result.contains { $0.link == target }, "source: \(source.debugDescription)")
                    }
                }
            }
        }
    }

    @Test(arguments: ["https://example.com/a\\|b*c*d", "https://example.com/a\\|中*b*c",
                      "https://example.com/a\\\\\\|b*c*d", "https://example.com/a\\[b\\]*c*d",
                      "www.example.com/a\\|b*c*d", "https://example.com/a&#124;b*c*d",
                      "https://example.com/a\\\\*b*c"])
    func rawEscapesMatchExplicitControlWithoutEatingLaterCells(rawURL: String) throws {
        let second = "https://example.com/next*a*b"
        for outer in [false, true] {
            for space in ["", " "] {
                let edge = outer ? "|" : ""
                let head = edge + "URL|Next|Note" + edge + "\n" + edge + "---|---|---" + edge + "\n"
                let tail = space + "|" + space + second + space + "|" + space + "real[^n]" + edge + "\n\n[^n]: note"
                let source = head + edge + rawURL + tail
                let destination = rawURL.hasPrefix("www.") ? "http://" + rawURL : rawURL
                let control = spans(MarkdownParser.parse(head + edge + "[link](<" + destination + ">)" + tail).blocks)
                let expected = try #require(control.first { $0.text == "link" }?.link)
                let document = MarkdownParser.parse(source)
                let result = spans(document.blocks)
                let visible = rawURL.hasPrefix("www.") ? String(expected.dropFirst(7)) : expected
                #expect(result.contains { $0.link == expected && $0.text == visible }, "source: \(source.debugDescription)")
                #expect(result.contains { $0.link == second }, "source: \(source.debugDescription)")
                #expect(result.filter(\.superscript).count == 1, "source: \(source.debugDescription)")
                guard case .table(let rows, _) = document.blocks.first else { Issue.record("Missing table"); continue }
                #expect(rows.count == 2 && rows.allSatisfy { $0.count == 3 }, "source: \(source.debugDescription)")
            }
        }
    }
    @Test(arguments: ["https://example.com/a|b*c*d", "https://example.com/a\\\\*b*c", "www.example.com/a\\|b*c*d"])
    func ordinaryURLsKeepTheirContext(rawURL: String) throws {
        let target = rawURL.hasPrefix("www.") ? "http://" + rawURL : rawURL
        let control = spans(MarkdownParser.parse("lead [link](<" + target + ">)").blocks)
        let expected = try #require(control.first { $0.text == "link" }?.link)
        let document = MarkdownParser.parse("lead " + rawURL + "\n\nplain")
        let visible = rawURL.hasPrefix("www.") ? String(expected.dropFirst(7)) : expected
        #expect(spans(document.blocks).contains { $0.link == expected && $0.text == visible })
        #expect(!document.blocks.contains { if case .table = $0 { return true }; return false })
    }

}
