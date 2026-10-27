import Foundation
import MokuseiCore

/// Decoration is never used as a selection, search, or membership identity.
public enum SemanticTagLabel {
    private static let emojis = Set(SemanticTagEmojiData.sequences.split(separator: "\n").map(String.init))

    public static func display(name: String, emoji: String) -> String {
        "\(emoji) \(name)"
    }

    private static func hasEmojiPrefix(_ text: String) -> Bool {
        // Match the runtime's scalar-prefix check, including a valid emoji
        // followed by a dangling joiner or an unsupported compound sequence.
        var prefix = ""
        for scalar in text.unicodeScalars {
            prefix.unicodeScalars.append(scalar)
            if prefix.utf8.count > 128 { return false }
            if emojis.contains(prefix) { return true }
        }
        return false
    }

    static func decodeEmojis(_ json: JSONValue, names: [JSONText]) throws -> [JSONText: JSONText] {
        guard let values = json.objectValue else { throw PluginContractError("tagEmojis must be an object") }
        guard Set(values.keys) == Set(names) else { throw PluginContractError("tagEmojis must match semantic tag names") }
        guard names.allSatisfy({ name in
            let text = name.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && !hasEmojiPrefix(text)
        }) else { throw PluginContractError("semantic tag names must not have emoji prefixes") }
        return try values.mapValues { value in
            guard let text = value.stringValue, emojis.contains(text) else {
                throw PluginContractError("tagEmojis values must be complete emoji sequences")
            }
            return JSONText(text)
        }
    }
}
