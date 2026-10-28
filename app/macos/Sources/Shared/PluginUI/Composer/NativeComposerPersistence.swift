import Foundation
import MokuseiCore
import MokuseiPluginAPI

/// One draft file per host/surface. No read-cache eviction can remove this file.
public struct NativeComposerDraftPersistence: Sendable {
    private let store: RuntimeDraftStore
    let identity: String
    public init(storageDirectory: URL, scope: JSONText) {
        store = RuntimeDraftStore(storageDirectory: storageDirectory, scope: scope)
        identity = storageDirectory.standardizedFileURL.path + "\0" + String(reflecting: scope.codeUnits)
    }

    struct Snapshot {
        let revision: String
        let textValue: JSONText
        var text: String { textValue.string }
        let directories: [NativeComposerDirectory]
        let attachments: [NativeComposerAttachment]
    }

    public struct TextSnapshot: Sendable {
        public let revision: String
        public let textValue: JSONText
    }

    public func isSameDraft(as other: Self) -> Bool { identity == other.identity }

    @MainActor public func loadText() throws -> TextSnapshot? {
        try load().map { .init(revision: $0.revision, textValue: $0.textValue) }
    }

    @MainActor @discardableResult
    public func saveText(_ text: JSONText, revision: String = UUID().uuidString) throws -> String {
        try save(textValue: text, directories: [], attachments: [], revision: revision)
    }

    @MainActor public func consumeText(expectedRevision: String) throws -> TextSnapshot? {
        try consume(expectedRevision: expectedRevision, attachmentIDs: [], directoryPaths: [])
            .map { .init(revision: $0.revision, textValue: $0.textValue) }
    }

    @MainActor func load() throws -> Snapshot? {
        guard let value = try store.load() else { return nil }
        return try decode(value)
    }

    @MainActor private func decode(_ value: JSONValue) throws -> Snapshot {
        guard let revision = value["revision"]?.stringValue, UUID(uuidString: revision) != nil,
              case let .string(text) = value["text"], let directories = value["directories"]?.arrayValue,
              directories.count <= NativeComposerDraft.maximumDirectories,
              let attachments = value["attachments"]?.arrayValue, attachments.count <= NativeComposerDraft.maximumAttachments else {
            throw PluginContractError("保存的草稿无法读取")
        }
        let restoredDirectories = try directories.map { value -> NativeComposerDirectory in
            guard case .string(let name) = value["name"], case .string(let path) = value["path"] else {
                throw PluginContractError("保存的草稿目录无法读取")
            }
            return .init(name: name, path: path, hostID: value["hostID"]?.stringValue)
        }
        let restoredAttachments = try attachments.map { value -> NativeComposerAttachment in
            guard case .string(let id) = value["id"], case .string(let name) = value["name"],
                  let status = value["status"]?.stringValue else { throw PluginContractError("保存的草稿附件无法读取") }
            let restoredStatus: NativeComposerAttachment.Status
            if status == "ready" {
                guard let file = value["attachment"], case .string(let storedID) = file["id"],
                      case .string(let path) = file["path"], case .string(let storedName) = file["name"],
                      case .string(let mime) = file["mimeType"], let size = file["size"]?.intValue, size >= 0,
                      let rawKind = file["kind"]?.stringValue, let kind = NativeComposerStoredAttachment.Kind(rawValue: rawKind) else {
                    throw PluginContractError("保存的草稿附件无法读取")
                }
                restoredStatus = .ready(.init(id: storedID, path: path, name: storedName, mimeType: mime, size: size, kind: kind))
            } else if status == "failed" {
                restoredStatus = .failed(value["message"]?.stringValue ?? "附件需要重新添加")
            } else if status == "pending" {
                // Import requests never become an offline queue. The text and
                // chip survive; the user chooses the file again after interruption.
                restoredStatus = .failed("附件导入已中断，请重新添加")
            } else { throw PluginContractError("保存的草稿附件状态无法读取") }
            let preview: NativeComposerPreview?
            if let encoded = value["preview"]?.stringValue, encoded.utf8.count <= 256 * 1024,
               let data = Data(base64Encoded: encoded) { preview = .init(data: data) }
            else { preview = nil }
            return .init(id: id, name: name, status: restoredStatus, preview: preview)
        }
        guard Set(restoredDirectories.map(\.path)).count == restoredDirectories.count,
              Set(restoredAttachments.map(\.id)).count == restoredAttachments.count else {
            throw PluginContractError("保存的草稿包含重复项目")
        }
        return Snapshot(revision: revision, textValue: text, directories: restoredDirectories, attachments: restoredAttachments)
    }

    /// Synchronous main-actor writes serialize replacement owners. The owner
    /// advances semantic revisions without reading the file on every keystroke.
    @MainActor @discardableResult
    func save(text: String, directories: [NativeComposerDirectory], attachments: [NativeComposerAttachment],
              revision: String = UUID().uuidString) throws -> String {
        try save(textValue: JSONText(text), directories: directories, attachments: attachments, revision: revision)
    }

    @MainActor
    private func save(textValue: JSONText, directories: [NativeComposerDirectory], attachments: [NativeComposerAttachment],
                      revision: String) throws -> String {
        let directoryValues = directories.map { directory in
            JSONValue.object(["name": .string(directory.name), "path": .string(directory.path),
                "hostID": directory.hostID.map(JSONValue.text) ?? .null])
        }
        let attachmentValues = attachments.map { draft -> JSONValue in
            var value: [JSONText: JSONValue] = ["id": .string(draft.id), "name": .string(draft.name)]
            if let preview = draft.preview, preview.data.count <= 192 * 1024 { value["preview"] = .text(preview.data.base64EncodedString()) }
            switch draft.status {
            case .pending: value["status"] = .text("pending")
            case .failed(let message): value["status"] = .text("failed"); value["message"] = .text(message)
            case .ready(let file):
                value["status"] = .text("ready")
                value["attachment"] = .object(["id": .string(file.id), "path": .string(file.path), "name": .string(file.name),
                    "mimeType": .string(file.mimeType), "size": .integer(file.size), "kind": .text(file.kind.rawValue)])
            }
            return .object(value)
        }
        try store.save(.object(["revision": .text(revision), "text": .string(textValue),
                               "directories": .array(directoryValues), "attachments": .array(attachmentValues)]))
        return revision
    }

    /// Accepted files are consumed by both chip and staged-file identity even
    /// when a successor has edited the draft. Preserve the other serialized
    /// fields verbatim: decoding for restoration turns pending imports into
    /// failures, which must not interrupt a live successor's import.
    @MainActor
    func consumeAcceptedAttachments(_ identities: [JSONText: JSONText]) throws -> (previousRevision: String, revision: String)? {
        guard !identities.isEmpty, let raw = try store.load() else { return nil }
        let snapshot = try decode(raw)
        let removed = Set(snapshot.attachments.filter { draft in
            guard let file = draft.attachment else { return false }
            return identities[draft.id] == file.id
        }.map(\.id))
        guard !removed.isEmpty else { return nil }
        // decode has validated the root and attachment array at this boundary.
        var value = raw.objectValue!
        let revision = UUID().uuidString
        value["revision"] = .text(revision)
        value["attachments"] = .array(value["attachments"]!.arrayValue!.filter {
            guard case .string(let id) = $0["id"] else { return true }
            return !removed.contains(id)
        })
        try store.save(.object(value))
        return (snapshot.revision, revision)
    }

    /// A late accepted receipt consumes only its exact persisted draft. Edits
    /// made by a reopened owner must never be overwritten by the retired owner.
    @MainActor
    func consume(expectedRevision: String, attachmentIDs: Set<JSONText>, directoryPaths: Set<JSONText>, clearText: Bool = true) throws -> Snapshot? {
        guard let snapshot = try load(), snapshot.revision == expectedRevision else { return nil }
        let directories = snapshot.directories.filter { !directoryPaths.contains($0.path) }
        let attachments = snapshot.attachments.filter { !attachmentIDs.contains($0.id) }
        let textValue: JSONText = clearText ? "" : snapshot.textValue
        let revision = try save(textValue: textValue, directories: directories, attachments: attachments, revision: UUID().uuidString)
        return Snapshot(revision: revision, textValue: textValue, directories: directories, attachments: attachments)
    }

}
