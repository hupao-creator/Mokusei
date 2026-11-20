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

    struct Contents {
        let textValue: JSONText
        // Chip writes and receipt restoration retain the editable body’s identity.
        let textEditID: UUID
        var text: String { textValue.string }
        let directories: [NativeComposerDirectory]
        let attachments: [NativeComposerAttachment]

        func restoring(_ original: Contents) -> Contents {
            let nextPaths = Set(directories.map(\.path)), nextIDs = Set(attachments.map(\.id))
            return Contents(textValue: JSONText(Self.recoveredText(submitted: original.text, next: text)),
                textEditID: textEditID,
                directories: original.directories.filter { !nextPaths.contains($0.path) } + directories,
                attachments: original.attachments.filter { !nextIDs.contains($0.id) } + attachments)
        }
        static func recoveredText(submitted: String, next: String) -> String {
            if next.isEmpty { return submitted }
            if submitted.isEmpty { return next }
            return submitted + "\n\n" + next
        }
    }

    struct Pending {
        let id: String
        let original: Contents
        var receiptID: String? = nil
        var reviewFork = false
    }

    struct Snapshot {
        let revision: String
        let contents: Contents
        let pending: Pending?
        var cleanupReceipt: String? = nil
        var text: String { contents.text }
        var directories: [NativeComposerDirectory] { contents.directories }
        var attachments: [NativeComposerAttachment] { contents.attachments }
    }

    public struct TextSnapshot: Sendable {
        public let revision: String
        public let textValue: JSONText
    }

    @MainActor public func loadText() throws -> TextSnapshot? {
        try load().map { .init(revision: $0.revision, textValue: $0.contents.textValue) }
    }

    @MainActor func load() throws -> Snapshot? {
        guard let value = try store.load() else { return nil }
        return try decode(value)
    }

    @MainActor func loadRetainingAttachments() throws -> (snapshot: Snapshot?, owner: RuntimeAttachmentOwner) {
        let retained = try store.loadRetainingAttachments()
        let snapshot = try retained.value.map(decode)
        let chips = (snapshot?.attachments ?? []) + (snapshot?.pending?.original.attachments ?? [])
        let ready = Set(chips.compactMap(\.attachment).map(\.id))
        guard ready == Set(retained.attachmentIDs) else { throw PluginContractError("保存的草稿附件归属无法读取") }
        return (snapshot, retained.owner)
    }

    @MainActor private func decode(_ value: JSONValue) throws -> Snapshot {
        guard let revision = value["revision"]?.stringValue, let fallbackID = UUID(uuidString: revision) else {
            throw PluginContractError("保存的草稿无法读取")
        }
        let pending: Pending?
        if let raw = value["pendingSend"] {
            guard let id = raw["id"]?.stringValue, RuntimeProtocol.isReceiptID(id) else {
                throw PluginContractError("保存的发送内容无法读取")
            }
            pending = Pending(id: id, original: try decodeContents(raw, fallbackID: fallbackID), receiptID: raw["receiptID"]?.stringValue,
                              reviewFork: raw["reviewFork"]?.boolValue == true)
        } else { pending = nil }
        return Snapshot(revision: revision, contents: try decodeContents(value, fallbackID: fallbackID),
                        pending: pending, cleanupReceipt: value["cleanupReceipt"]?.stringValue)
    }

    @MainActor private func decodeContents(_ value: JSONValue, fallbackID: UUID) throws -> Contents {
        guard case let .string(text) = value["text"], let directories = value["directories"]?.arrayValue,
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
        let textEditID: UUID
        if let field = value["textEditID"] {
            guard let id = field.stringValue.flatMap(UUID.init(uuidString:)) else {
                throw PluginContractError("保存的草稿无法读取")
            }
            textEditID = id
        } else {
            // Owners reopening a draft without this field must agree on its initial identity.
            textEditID = fallbackID
        }
        return Contents(textValue: text, textEditID: textEditID, directories: restoredDirectories, attachments: restoredAttachments)
    }

    func acquireSubmissionLease() throws -> RuntimeDraftSubmissionLease { try store.acquireSubmissionLease() }

    @MainActor
    private func fields(_ contents: Contents) -> [JSONText: JSONValue] {
        let directories = contents.directories, attachments = contents.attachments
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
        return ["text": .string(contents.textValue), "textEditID": .text(contents.textEditID.uuidString),
                "directories": .array(directoryValues), "attachments": .array(attachmentValues)]
    }

    @MainActor @discardableResult
    func save(_ contents: Contents, pending: Pending?, expectedRevision: String?, revision: String) throws -> String {
        var value = fields(contents)
        value["revision"] = .text(revision)
        let chips = contents.attachments + (pending?.original.attachments ?? [])
        try store.update { current in
            guard current?["revision"]?.stringValue == expectedRevision else {
                throw PluginContractError("Another owner changed this draft. Reopen it to review the saved input.")
            }
            if pending != nil, current?["cleanupReceipt"] != nil {
                throw PluginContractError("Finish previous receipt cleanup before sending.")
            }
            value["cleanupReceipt"] = current?["cleanupReceipt"]
            if let pending {
                if let original = current?["pendingSend"], original["id"]?.stringValue == pending.id {
                    value["pendingSend"] = original
                } else {
                    var original = fields(pending.original)
                    original["id"] = .text(pending.id)
                    if let id = pending.receiptID { original["receiptID"] = .text(id) }
                    value["pendingSend"] = .object(original)
                }
            }
            return (.object(value), Array(Set(chips.compactMap(\.attachment).map(\.id))))
        }
        return revision
    }

    /// Receipt metadata belongs to the send ID independently of successor edits.
    @MainActor func bindReceipt(_ receipt: String?, to id: String, reviewFork: Bool) throws {
        try store.update { raw in
            guard let raw, var fields = raw.objectValue, var pending = raw["pendingSend"]?.objectValue,
                  pending["id"]?.stringValue == id else {
                throw PluginContractError("This send is no longer pending.")
            }
            let before = try decode(raw)
            pending["receiptID"] = receipt.map(JSONValue.text)
            pending["reviewFork"] = reviewFork ? .bool(true) : nil
            fields["pendingSend"] = .object(pending)
            let chips = before.attachments + (before.pending?.original.attachments ?? [])
            return (.object(fields), Array(Set(chips.compactMap(\.attachment).map(\.id))))
        }
    }

    /// Resolve the captured send against the latest successor, even if its
    /// writer has retired. Keep the successor's raw pending-import status.
    @MainActor
    func finish(_ id: String, restore: Bool, cleanupReceipt: String?) throws -> (previousRevision: String, snapshot: Snapshot) {
        var result: (String, Snapshot)?
        try store.update { raw in
            guard let raw, var value = raw.objectValue,
                  let original = value["pendingSend"],
                  original["id"]?.stringValue == id else {
                throw PluginContractError("The saved send has already been resolved. Reopen the draft.")
            }
            let before = try decode(raw)
            if restore, let pending = before.pending {
                value["text"] = .text(Contents.recoveredText(submitted: pending.original.text, next: before.text))
                // decode validated the two arrays and their literal UTF-16 keys.
                for (field, key) in [("directories", "path"), ("attachments", "id")] {
                    let next = raw[field]!.arrayValue!
                    let keys = Set(next.compactMap { $0[key] })
                    let previous = original[field]!.arrayValue!.filter { !keys.contains($0[key]!) }
                    value[JSONText(field)] = .array(previous + next)
                }
            }
            value["textEditID"] = .text(before.contents.textEditID.uuidString)
            value["pendingSend"] = nil
            value["cleanupReceipt"] = cleanupReceipt.map(JSONValue.text)
            value["revision"] = .text(UUID().uuidString)
            let snapshot = try decode(.object(value))
            result = (before.revision, snapshot)
            return (.object(value), snapshot.attachments.compactMap(\.attachment).map(\.id))
        }
        return result!
    }

    @MainActor func completeCleanup(_ id: String) throws {
        try store.update { raw in
            guard let raw, var fields = raw.objectValue, raw["cleanupReceipt"]?.stringValue == id else { return nil }
            let saved = try decode(raw)
            fields["cleanupReceipt"] = nil
            return (.object(fields), saved.attachments.compactMap(\.attachment).map(\.id))
        }
    }

    /// Accepted files are consumed by both chip and staged-file identity even
    /// when a successor has edited the draft. Preserve the other serialized
    /// fields verbatim: decoding for restoration turns pending imports into
    /// failures, which must not interrupt a live successor's import.
    @MainActor
    func consumeAcceptedAttachments(_ identities: [JSONText: JSONText]) throws -> (previousRevision: String, revision: String)? {
        guard !identities.isEmpty else { return nil }
        var result: (String, String)?
        try store.update { raw in
            guard let raw, raw["pendingSend"] == nil else { return nil }
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
            value["textEditID"] = .text(snapshot.contents.textEditID.uuidString)
            value["attachments"] = .array(value["attachments"]!.arrayValue!.filter {
                guard case .string(let id) = $0["id"] else { return true }
                return !removed.contains(id)
            })
            result = (snapshot.revision, revision)
            return (.object(value), snapshot.attachments
                .filter { !removed.contains($0.id) }.compactMap(\.attachment).map(\.id))
        }
        return result
    }

    /// A late accepted receipt consumes only its exact persisted draft. Edits
    /// made by a reopened owner must never be overwritten by the retired owner.
    @MainActor
    func consume(expectedRevision: String, attachmentIDs: Set<JSONText>, directoryPaths: Set<JSONText>, clearText: Bool = true) throws -> Snapshot? {
        guard let snapshot = try load(), snapshot.pending == nil, snapshot.revision == expectedRevision else { return nil }
        let directories = snapshot.directories.filter { !directoryPaths.contains($0.path) }
        let attachments = snapshot.attachments.filter { !attachmentIDs.contains($0.id) }
        let contents = Contents(textValue: clearText ? "" : snapshot.contents.textValue,
                                textEditID: clearText ? UUID() : snapshot.contents.textEditID,
                                directories: directories, attachments: attachments)
        let revision = try save(contents, pending: nil, expectedRevision: expectedRevision, revision: UUID().uuidString)
        return Snapshot(revision: revision, contents: contents, pending: nil)
    }

}
