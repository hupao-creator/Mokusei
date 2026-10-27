import Foundation
import MokuseiCore

public struct NativeComposerDirectory: Hashable, Sendable, Identifiable {
    public let name: JSONText
    public let path: JSONText
    public let hostID: String?
    public var id: JSONText { path }
    public init(name: JSONText, path: JSONText, hostID: String? = nil) { self.name = name; self.path = path; self.hostID = hostID }
}

/// Validated runtime attachment metadata. Identity and paths retain UTF-16 wire
/// representation; display names are converted only when drawn by the view.
public struct NativeComposerStoredAttachment: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case image, document, file }
    public let id: JSONText
    public let path: JSONText
    public let name: JSONText
    public let mimeType: JSONText
    public let size: Int
    public let kind: Kind
    public init(id: JSONText, path: JSONText, name: JSONText, mimeType: JSONText, size: Int, kind: Kind) {
        precondition(size >= 0, "Attachment size must be validated before constructing presentation metadata")
        self.id = id; self.path = path; self.name = name; self.mimeType = mimeType
        self.size = size; self.kind = kind
    }
}

/// Downsampled PNG preview (112px long edge) that rides with an attachment
/// while it stages. Kept as encoded bytes rather than a `CGImage` so the value
/// stays `Sendable`, `Hashable`, and cheap to carry across the pending → ready
/// transition without re-decoding the original.
public struct NativeComposerPreview: Hashable, Sendable {
    public let data: Data
    /// Content identity computed once at construction. The chip's decode cache
    /// uses it as an `O(1)` key instead of rehashing the PNG on every render.
    let identity: Int
    public init(data: Data) {
        self.data = data
        // FNV-1a over the encoded bytes; previews are a few KB, so hashing once
        // at construction keeps per-frame cache lookups free.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        data.withUnsafeBytes { buffer in
            for byte in buffer { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        }
        identity = Int(truncatingIfNeeded: hash)
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identity == rhs.identity && lhs.data == rhs.data
    }
    public func hash(into hasher: inout Hasher) { hasher.combine(identity) }
}

public struct NativeComposerAttachment: Hashable, Sendable, Identifiable {
    public enum Status: Hashable, Sendable {
        case pending(size: Int, mimeType: String)
        case ready(NativeComposerStoredAttachment)
        case failed(String)
    }
    /// Remains stable across staging so removing a pending chip cannot resurrect
    /// it when its asynchronous import completes.
    public let id: JSONText
    public let name: JSONText
    public let status: Status
    /// Real-image preview decoded at paste/import time. Lives here, not in the
    /// chip, so switching surfaces reuses it and removing the attachment frees it.
    public let preview: NativeComposerPreview?
    public init(id: JSONText, name: JSONText, status: Status, preview: NativeComposerPreview? = nil) {
        self.id = id; self.name = name; self.status = status; self.preview = preview
    }
    public init(attachment: NativeComposerStoredAttachment) {
        self.init(id: attachment.id, name: attachment.name, status: .ready(attachment))
    }
    /// `preview` is presentation-only and deliberately excluded: a preview that
    /// lands while a send is awaiting its receipt must not make an already-sent
    /// attachment compare unequal to the value captured at submit time.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.status == rhs.status
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id); hasher.combine(name); hasher.combine(status)
    }
    public var attachment: NativeComposerStoredAttachment? {
        if case .ready(let value) = status { value } else { nil }
    }
    public var pending: Bool { if case .pending = status { true } else { false } }
}

public struct NativeComposerSubmission: Sendable {
    public let text: String
    public let directories: [NativeComposerDirectory]
    public let attachments: [NativeComposerStoredAttachment]
    public init(text: String, directories: [NativeComposerDirectory], attachments: [NativeComposerStoredAttachment]) {
        self.text = text; self.directories = directories; self.attachments = attachments
    }
    public var input: JSONValue {
        var parts: [JSONValue] = []
        let trimmed = NativeComposerSubmissionPolicy.trimmedText(text)
        if !trimmed.isEmpty { parts.append(.object(["kind": .string("text"), "text": .string(JSONText(trimmed))])) }
        parts += directories.map { .object([
            "kind": .string("mention"), "name": .string($0.name), "path": .string($0.path), "pathType": .string("directory")
        ]) }
        parts += attachments.map { .object([
            "kind": .string($0.kind == .image ? "image" : "local-file"), "file": .object(["id": .string($0.id)])
        ]) }
        return .object(["parts": .array(parts)])
    }
}

public enum NativeComposerSubmissionPolicy {
    /// ECMAScript String.trim's exact WhiteSpace + LineTerminator set. Foundation
    /// whitespace also includes NEL and omits BOM, changing whether a draft sends.
    public static func trimmedText(_ text: String) -> String {
        trimmedText(JSONText(text)).string
    }
    /// Boundary trimming never decodes the interior, including lone surrogates.
    public static func trimmedText(_ text: JSONText) -> JSONText {
        let units = text.codeUnits
        var start = 0, end = units.count
        while start < end, isWhitespace(units[start]) { start += 1 }
        while end > start, isWhitespace(units[end - 1]) { end -= 1 }
        return JSONText(codeUnits: Array(units[start..<end]))
    }
    private static func isWhitespace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x0009...0x000D, 0x0020, 0x00A0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
        default: false
        }
    }
    public static func canSubmit(text: String, attachments: [NativeComposerAttachment], directories: [NativeComposerDirectory] = []) -> Bool {
        !attachments.contains(where: \.pending)
            && (!trimmedText(text).isEmpty
                || !directories.isEmpty || attachments.contains { $0.attachment != nil })
    }
}
