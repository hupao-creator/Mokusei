import Testing
@testable import MokuseiPluginUI

struct MarkdownFallbackSourceTests {
    private func spans(_ blocks: [MarkdownBlock]) -> [MarkdownSpan] {
        blocks.flatMap { block -> [MarkdownSpan] in
            switch block {
            case .paragraph(let s), .heading(_, let s): return s
            case .quote(let children), .footnote(_, _, let children): return spans(children)
            case .list(let items): return items.flatMap { spans($0.blocks) }
            case .table(let rows, _): return rows.flatMap { $0.flatMap { $0 } }
            case .code(_, let text): return [MarkdownSpan(text: text, code: true)]
            case .rule: return []
            }
        }
    }

    private func wrapped(_ source: String, prefix: String) -> String {
        let continuation = prefix.replacingOccurrences(of: "1.", with: "  ").replacingOccurrences(of: "-", with: " ")
        return source.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            .map { ($0.offset == 0 ? prefix : continuation) + $0.element }.joined(separator: "\n")
    }

    @Test(arguments: ["", "> ", "- ", "> 1. ", ">\t", "-\t", "> -\t"])
    func tableNormalizationPreservesLiteralAndRealNotes(prefix: String) {
        let url = "https://example.com/a*b*c"
        for bom in ["", "\u{FEFF}"] {
            for lead in ["", "界 e\u{301}\t", "nul\0 ", "nul\0\t界 e\u{301} "] {
                for cell in ["[^n]`literal [^n]`", "`literal [^n]`[^n]"] {
                    for ending in ["\n", "\r\n", "\r"] {
                        for header in [true, false] {
                            let title = header ? lead + cell : "A"
                            let body = header ? "nul\0" : lead + cell
                            let table = "| \(title) | URL |\n| --- | --- |\n| \(body) | \(url) |"
                            let source = (bom + wrapped(table, prefix: prefix) + "\n\n[^n]: note")
                                .replacingOccurrences(of: "\n", with: ending)
                            let result = spans(MarkdownParser.parse(source).blocks)
                            #expect(result.filter(\.superscript).count == 1, "source: \(source.debugDescription)")
                            #expect(result.contains { $0.code && $0.text == "literal [^n]" }, "source: \(source.debugDescription)")
                            #expect(result.contains { $0.link == url }, "source: \(source.debugDescription)")
                            #expect(!result.contains { $0.text.contains("\u{E000}mokusei-") }, "source: \(source.debugDescription)")
                        }
                    }
                }
            }
        }
    }

    @Test(arguments: ["", "> ", "- ", "> 1. ", ">\t", "-\t"])
    func fallbackInlineKindsAndEscapedPipesKeepExactRanges(prefix: String) {
        for literal in ["`literal [^n]`", "[literal [^n]](https://example.com/link)",
                        "![literal [^n]](https://example.com/image)", "<span title=\"[^n]\">"] {
            for lead in ["nul\0 界 e\u{301}\t", "nul\0 a\\|b "] {
                let table = "| \(lead)[^n]\(literal)[^n] |\n| --- |\n| item |"
                let source = "\u{FEFF}" + wrapped(table, prefix: prefix) + "\n\n[^n]: note"
                let result = spans(MarkdownParser.parse(source).blocks)
                #expect(result.filter(\.superscript).count == 2, "source: \(source.debugDescription)")
                #expect(result.contains { $0.text.contains("[^n]") }, "source: \(source.debugDescription)")
                #expect(!result.contains { $0.text.contains("\u{E000}mokusei-") }, "source: \(source.debugDescription)")
            }
        }
    }

    @Test func tableRowsUseTheirOwnConsumedContainerPrefix() {
        func rowCount(_ blocks: [MarkdownBlock]) -> Int {
            blocks.reduce(0) { total, block in
                switch block {
                case .table(let rows, _): return total + rows.count
                case .quote(let children), .footnote(_, _, let children): return total + rowCount(children)
                case .list(let items): return total + items.reduce(0) { $0 + rowCount($1.blocks) }
                default: return total
                }
            }
        }
        let url = "https://example.com/a*b*c"
        for (first, continuation) in [("-   ", "\t"), ("1.  ", "\t"), ("> -   ", "> \t  "), (">  ", ">\t"), ("   ", "")] {
            let source = "\u{FEFF}" + first + "| A | URL |\n" + continuation + "| --- | --- |\n"
                + continuation + "| nul\0 a\\|b [^n]`literal [^n]`[^n] | " + url + " |\n\n[^n]: note"
            let document = MarkdownParser.parse(source)
            let result = spans(document.blocks)
            #expect(rowCount(document.blocks) == 2, "source: \(source.debugDescription)")
            #expect(result.filter(\.superscript).count == 2, "source: \(source.debugDescription)")
            #expect(result.contains { $0.code && $0.text == "literal [^n]" }, "source: \(source.debugDescription)")
            #expect(result.contains { $0.link == url }, "source: \(source.debugDescription)")
        }
    }

    @Test(arguments: ["", "> ", "- ", "> 1. ", ">\t", "-\t"])
    func fallbackBlockLiteralsDoNotExposeFootnoteTokens(prefix: String) {
        for body in ["```text\n\0界\t[^n]\n```", "<div>\n\0界\t[^n]\n</div>"] {
            let source = "\u{FEFF}" + wrapped(body, prefix: prefix) + "\n\nreal[^n].\n\n[^n]: note"
            let result = spans(MarkdownParser.parse(source).blocks)
            #expect(result.filter(\.superscript).count == 1, "source: \(source.debugDescription)")
            #expect(result.contains { $0.text.contains("[^n]") }, "source: \(source.debugDescription)")
            #expect(!result.contains { $0.text.contains("\u{E000}mokusei-") }, "source: \(source.debugDescription)")
        }
    }
}
