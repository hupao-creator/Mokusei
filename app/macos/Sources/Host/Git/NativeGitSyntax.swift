import Foundation

/// A deliberately small, stateless lexical palette. Unknown languages retain
/// plain source text. It never needs an executable, grammar download or WebView.
enum GitNativeSyntax {
    private static let extensions: Set<String> = ["swift", "go", "rs", "c", "h", "cpp", "hpp", "m", "mm", "js", "jsx", "ts", "tsx", "py", "rb", "sh", "bash", "zsh", "json", "yaml", "yml", "toml", "css", "sql", "java", "kt"]
    private static let pattern = try! NSRegularExpression(pattern: #"(//[^\r\n]*|/\*.*?\*/|#[^\r\n]*)|("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')|\b(0x[0-9a-fA-F]+|[0-9]+(?:\.[0-9]+)?)\b|\b(import|package|func|function|let|var|const|class|struct|enum|interface|protocol|extension|return|if|else|switch|case|for|while|break|continue|guard|defer|throw|throws|try|catch|async|await|public|private|static|final|type|nil|null|true|false|def|from|in|self|SELECT|FROM|WHERE)\b"#)
    private static let styles: [GitDiffTokenStyle] = [
        style(0x6e7781, 0x8b949e), style(0x0a3069, 0xa5d6ff),
        style(0x0550ae, 0x79c0ff), style(0x8250df, 0xd2a8ff)
    ]
    private static func style(_ light: UInt32, _ dark: UInt32) -> GitDiffTokenStyle {
        .init(light: .init(rgb: light, alpha: 1), dark: .init(rgb: dark, alpha: 1),
              lightFontStyle: 0, darkFontStyle: 0, lightBackground: nil, darkBackground: nil)
    }
    static func tokens(_ text: String, path: String) -> [GitDiffToken] {
        guard extensions.contains((path as NSString).pathExtension.lowercased()), text.utf16.count <= 4096 else { return [] }
        return pattern.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)).compactMap { match in
            for group in 1...4 where match.range(at: group).location != NSNotFound {
                return GitDiffToken(range: match.range, style: styles[group - 1])
            }
            return nil
        }
    }
}
