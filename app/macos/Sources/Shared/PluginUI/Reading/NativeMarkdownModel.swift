import Foundation
import MokuseiCore

struct MarkdownSpan: Hashable, Sendable {
    var text: String
    var strong = false
    var emphasis = false
    var strikethrough = false
    var code = false
    var link: String?
    var linkContext = false
    var image: String?
    var title: String?
    var superscript = false
    var anchor: String?
}

indirect enum MarkdownBlock: Hashable, Sendable {
    case paragraph([MarkdownSpan])
    case heading(Int, [MarkdownSpan])
    case quote([MarkdownBlock])
    case list([MarkdownListItem])
    case code(language: String, source: String)
    case table(rows: [[[MarkdownSpan]]], alignments: [MarkdownAlignment])
    case rule
    case footnote(id: String, index: Int, blocks: [MarkdownBlock])
}

struct MarkdownListItem: Hashable, Sendable {
    let marker: String
    let checked: Bool?
    let tight: Bool
    let blocks: [MarkdownBlock]
}

enum MarkdownAlignment: Hashable, Sendable { case left, center, right }

struct MarkdownDocument: Sendable {
    let blocks: [MarkdownBlock]
    let sourceBytes: Int

    /// The viewport observer can only certify documents whose content has no
    /// nested scrolling or asynchronous media reflow.
    var coverageEligible: Bool { blocks.allSatisfy(eligible) && blocks.contains(where: hasText) }

    private func hasText(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .paragraph(let spans), .heading(_, let spans):
            return spans.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        case .quote(let children), .footnote(_, _, let children): return children.contains(where: hasText)
        case .list(let items): return items.contains { $0.blocks.contains(where: hasText) }
        case .code, .table, .rule: return false
        }
    }

    private func eligible(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .paragraph(let spans), .heading(_, let spans):
            return !spans.isEmpty && spans.allSatisfy { $0.image == nil &&
                ($0.link == nil || MarkdownURLPolicy.localFileURL($0.link!) == nil) }
        case .quote(let children), .footnote(_, _, let children):
            return !children.isEmpty && children.allSatisfy(eligible)
        case .list(let items):
            return !items.isEmpty && items.allSatisfy { !$0.blocks.isEmpty && $0.blocks.allSatisfy(eligible) }
        case .rule: return true
        case .code, .table: return false
        }
    }
}

/// Matches the renderer's safeUrl policy: relative URLs and the listed schemes
/// survive, while executable URLs and data URLs are displayed without navigation.
enum MarkdownURLPolicy {
    static func sanitized(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if let colon = value.firstIndex(of: ":") {
            let delimiter = value.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" })
            if delimiter == nil || colon < delimiter! {
                if String(value[..<colon]).lowercased() == "file" {
                    return localFileURL(value) == nil ? nil : value
                }
                let allowed = ["http", "https", "irc", "ircs", "mailto", "xmpp"]
                guard allowed.contains(String(value[..<colon]).lowercased()) else { return nil }
            }
        }
        return value
    }

    static func url(_ value: String?, baseURL: URL? = nil) -> URL? {
        guard let safe = sanitized(value) else { return nil }
        if let local = localFileURL(safe) { return local }
        return URL(string: safe, relativeTo: baseURL)?.absoluteURL
    }

    /// Absolute paths are filesystem paths, not relative web URLs. Decode URL
    /// escapes once while preserving literal spaces, Unicode and path delimiters.
    static func localFileURL(_ value: String) -> URL? {
        if value.hasPrefix("/"), !value.hasPrefix("//") {
            return URL(fileURLWithPath: value.removingPercentEncoding ?? value)
        }
        guard let url = URL(string: value), url.isFileURL,
              url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
              url.path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: url.path)
    }
}

/// Per-document tasks are coalesced by the view model; this actor bounds retained
/// parse results across a long conversation, without retaining parser AST objects.
actor NativeMarkdownParser {
    static let shared = NativeMarkdownParser()
    private var cache: [String: MarkdownDocument] = [:]
    private var order: [String] = []
    private var bytes = 0
    private let budget = 4 * 1024 * 1024

    func parse(_ source: String) throws -> MarkdownDocument {
        try Task.checkCancellation()
        if let cached = cache[source] {
            NativePerformance.event(.markdownCache, values: ["hit": 1])
            order.removeAll { $0 == source }; order.append(source)
            return cached
        }
        NativePerformance.event(.markdownCache, values: ["hit": 0])
        let measurement = NativePerformance.begin(.markdownParse)
        let result = MarkdownParser.parse(source)
        measurement?.end(values: ["bytes": Double(result.sourceBytes), "blocks": Double(result.blocks.count)])
        try Task.checkCancellation()
        if result.sourceBytes <= budget {
            cache[source] = result; order.append(source); bytes += result.sourceBytes
            while bytes > budget || order.count > 48 {
                let key = order.removeFirst()
                bytes -= cache.removeValue(forKey: key)?.sourceBytes ?? 0
            }
        }
        return result
    }
}
