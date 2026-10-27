import AppKit

/// Only platform actions live here. Markdown parsing, spans, block layout and
/// attributed text use the same macOS rendering policy.
@MainActor
enum MarkdownPlatformActions {
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    static func copy(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }
}

extension NSAttributedString {
    /// Image alt text and invisible code padding carry the same copy semantics
    /// across native TextKit implementations.
    func markdownPlainText() -> String {
        let plain = NSMutableString(string: string)
        var descriptions: [(NSRange, String)] = []
        enumerateAttribute(.init("NSAccessibilityDescription"), in: NSRange(location: 0, length: length)) { value, range, _ in
            if let value = value as? String { descriptions.append((range, value)) }
        }
        for (range, description) in descriptions.reversed() { plain.replaceCharacters(in: range, with: description) }
        return plain as String
    }
}
