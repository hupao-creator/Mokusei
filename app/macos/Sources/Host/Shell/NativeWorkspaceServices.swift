import AppKit
import ImageIO
import UniformTypeIdentifiers
import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import WebURL

@MainActor
public final class NativeWorkspaceServices {
    private weak var workspace: NativeWorkspaceModel?
    public init(workspace: NativeWorkspaceModel) { self.workspace = workspace }

    public func composer() -> NativeComposerServices {
        NativeComposerServices(stageFiles: { [weak self] files, lifetime in
            guard let self else { throw CancellationError() }
            let attachments = try await within(lifetime) { try await self.stage(files) }
            if lifetime.isCancelled {
                try await self.discard(attachments.map(\.id))
                throw CancellationError()
            }
            return attachments
        }, attachmentPolicy: { [weak self] lifetime in
            guard let self else { throw CancellationError() }
            return try await within(lifetime) { try await self.attachmentPolicy() }
        }, hostDirectory: { [weak self] reference, lifetime in
            guard let self else { throw CancellationError() }
            return try await within(lifetime) { try await self.hostDirectory(reference) }
        }, previewAttachment: { [weak self] attachment, lifetime in
            guard let self else { throw CancellationError() }
            return try await within(lifetime) { try await self.thumbnail(attachment) }
        }, openHostFile: { [weak self] reference, lifetime in
            guard let self else { throw CancellationError() }
            try await within(lifetime) {
                let file = try await self.download(reference)
                do {
                    try lifetime.checkCancellation(); try Task.checkCancellation()
                    try NativeHostFilePreview.present(file, lifetime: lifetime)
                } catch {
                    try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
                    throw error
                }
            }
        }, discardAttachments: { [weak self] ids in
            guard let self else { throw CancellationError() }
            try await self.discard(ids)
        })
    }

    private func within<T: Sendable>(_ lifetime: PluginLifetime, operation: @escaping @MainActor () async throws -> T) async throws -> T {
        try lifetime.checkCancellation()
        let task = Task { try await operation() }
        let handler = lifetime.onCancel { task.cancel() }
        defer { lifetime.removeHandler(handler) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    public func attachmentPolicy() async throws -> RuntimeAttachmentPolicy {
        try await requireWorkspace().client.attachmentPolicy()
    }

    public func hostDirectory(_ reference: RuntimeHostFileReference? = nil) async throws -> RuntimeHostDirectory {
        try await requireWorkspace().client.hostDirectory(reference)
    }

    public func stage(_ files: [NativeComposerFile]) async throws -> [NativeComposerStoredAttachment] {
        let workspace = try requireWorkspace()
        let policy = try await workspace.client.attachmentPolicy()
        guard files.count <= policy.messageCount else { throw PluginContractError("附件数量不能超过 \(policy.messageCount) 个") }
        var selectedBytes = 0
        for file in files {
            guard file.size >= 0, file.size <= policy.maximumBytes(mimeType: file.mimeType),
                  file.size <= policy.messageBytes - selectedBytes else { throw PluginContractError("附件大小超过主机限制") }
            selectedBytes += file.size
        }
        let requiresStream = files.contains {
            switch $0.source {
            case .hostPath: true
            case .bytes(let data): data.count > 20 * 1024 * 1024
            case .file: false
            }
        }
        var records: [JSONValue] = []
        do {
            if requiresStream {
                for file in files {
                    try Task.checkCancellation()
                    switch file.source {
                    case .hostPath(let reference):
                        records += try await workspace.client.stageHostFiles([reference])
                    case .file(let url):
                        records.append(try await workspace.client.uploadAttachment(file: url, name: file.name))
                    case .bytes(let data):
                        guard data.count == file.size, data.count <= policy.maximumBytes(mimeType: file.mimeType) else {
                            throw PluginContractError("附件大小超过主机限制")
                        }
                        let directory = workspace.client.storageDirectory.appendingPathComponent("clipboard/\(UUID().uuidString)", isDirectory: true)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        defer { try? FileManager.default.removeItem(at: directory) }
                        let url = directory.appendingPathComponent("bytes")
                        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
                        records.append(try await workspace.client.uploadAttachment(file: url, name: file.name))
                    }
                }
            } else {
                let encoding = Task.detached(priority: .userInitiated) { try Self.encodeImports(files) }
                let imports = try await withTaskCancellationHandler { try await encoding.value } onCancel: { encoding.cancel() }
                try Task.checkCancellation()
                let result = try await workspace.invoke("moku:stage-attachments", args: [.array(imports)])
                guard let values = result.arrayValue else { throw PluginContractError("Invalid attachment import response") }
                records = values
            }
            guard records.count == files.count else { throw PluginContractError("Attachment import returned an incomplete result") }
            let result = try records.map(Self.attachment)
            guard result.reduce(0, { $0 + $1.size }) <= policy.messageBytes else { throw PluginContractError("附件总大小不能超过 100 MB") }
            try Task.checkCancellation()
            return result
        } catch {
            let ids = records.compactMap { value -> JSONText? in
                guard case let .string(id) = value["id"] else { return nil }; return id
            }
            // Cleanup is best effort after cancellation/disconnect. Unknown partial
            // uploads never become successful chips or executable attachments.
            try? await discard(ids)
            throw error
        }
    }

    nonisolated private static func attachment(_ value: JSONValue) throws -> NativeComposerStoredAttachment {
        guard case let .string(id) = value["id"], case let .string(path) = value["path"],
              case let .string(name) = value["name"], case let .string(mime) = value["mimeType"],
              let size = value["size"]?.intValue, size >= 0,
              let kind = value["kind"]?.stringValue.flatMap(NativeComposerStoredAttachment.Kind.init(rawValue:)) else {
            throw PluginContractError("Invalid imported attachment metadata")
        }
        return .init(id: id, path: path, name: name, mimeType: mime, size: size, kind: kind)
    }

    private func thumbnail(_ attachment: NativeComposerStoredAttachment) async throws -> Data? {
        guard attachment.kind == .image else { return nil }
        let url = URL(fileURLWithPath: attachment.path.string)
        let task = Task.detached(priority: .userInitiated) { () throws -> Data? in
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 112
                  ] as CFDictionary) else { return nil }
            let bytes = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            try Task.checkCancellation()
            return bytes as Data
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    public func hostReference(path: JSONText) async throws -> RuntimeHostFileReference {
        guard Array(path.string.utf16) == path.codeUnits, path.string.hasPrefix("/") else { throw PluginContractError("无效的主机文件路径") }
        let workspace = try requireWorkspace()
        return try await .init(hostID: workspace.client.hostDirectory().reference.hostID, path: path.string)
    }

    public func download(_ reference: RuntimeHostFileReference) async throws -> RuntimeDownloadedFile {
        try await requireWorkspace().client.downloadHostFile(reference)
    }

    nonisolated private static func encodeImports(_ files: [NativeComposerFile]) throws -> [JSONValue] {
        guard files.count <= 20 else { throw PluginContractError("附件数量不能超过 20 个") }
        var bytesCount = 0
        return try files.map { file in
            try Task.checkCancellation()
            switch file.source {
            case .file(let url):
                guard url.isFileURL else { throw PluginContractError("Attachments must be local files") }
                return .object(["source": .text("path"), "path": .text(url.path), "displayName": .text(file.name)])
            case .hostPath:
                throw PluginContractError("Host references require the host file capability")
            case .bytes(let data):
                guard data.count <= 20 * 1024 * 1024 else { throw PluginContractError("无路径的粘贴内容不能超过 20 MB") }
                bytesCount += data.count
                guard bytesCount <= 100 * 1024 * 1024 else { throw PluginContractError("附件总大小不能超过 100 MB") }
                // This marker is the existing runtime JSON codec's ArrayBuffer
                // representation; the command schema still receives real bytes.
                return .object(["source": .text("bytes"), "displayName": .text(file.name),
                    "bytes": .object(["$mokuseiArrayBuffer": .text(data.base64EncodedString())])])
            }
        }
    }

    public func discard(_ ids: [JSONText]) async throws {
        guard !ids.isEmpty else { return }
        let workspace = try requireWorkspace()
        _ = try await workspace.invoke("attachment:discard", args: [.array(ids.map(JSONValue.string))])
    }

    public func preview(threadID: JSONText, attachmentID: JSONText) async throws -> Data {
        let workspace = try requireWorkspace()
        // Runtime verifies durable Thread ownership and only returns PNG
        // annotation screenshots. This API never accepts arbitrary file paths.
        let value = try await workspace.client.invoke("attachment:preview", args: [.string(threadID), .string(attachmentID)])
        guard let source = value.stringValue, source.hasPrefix("data:image/png;base64,"),
              let bytes = Data(base64Encoded: String(source.dropFirst("data:image/png;base64,".count))),
              bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw PluginContractError("Invalid annotation screenshot response")
        }
        return bytes
    }

    public func followUp(threadID: JSONText, input: JSONValue) async throws -> SidecardSendReceipt {
        let workspace = try requireWorkspace()
        guard let thread = workspace.catalog.thread(threadID), thread.archived != true else {
            throw PluginContractError("此 Thread 已归档或不可用，无法追加任务。")
        }
        let result = try await workspace.invoke("thread:follow-up", args: [.object(["threadId": .string(threadID), "input": input])])
        guard case let .string(id) = result["executionId"] else { throw PluginContractError("The runtime returned no accepted execution identity") }
        return SidecardSendReceipt(executionID: id)
    }

    public func openExternal(_ text: JSONText) async throws {
        do { try openExternalURL(text) }
        catch {
            // Harness readers may discard the thrown result; the host still
            // owns visible feedback for a failed system handoff.
            workspace?.report(error)
            throw error
        }
    }

    private func openExternalURL(_ text: JSONText) throws {
        let locale = workspace?.preferences.locale ?? .english
        guard JSONText(text.string) == text, let url = URL(string: text.string) else { throw PluginContractError(locale.text("无效的链接", "Invalid link")) }
        if url.isFileURL {
            guard NSWorkspace.shared.open(url) else { throw PluginContractError(locale.text("无法打开文件", "Could not open the file")) }
            return
        }
        if url.scheme?.lowercased() == "mailto" {
            guard NSWorkspace.shared.open(url) else { throw PluginContractError(locale.text("无法打开邮件链接，请检查默认邮件应用。", "Could not open the email link. Check your default mail app.")) }
            return
        }
        guard let parsed = WebURL(text.string), ["http", "https"].contains(parsed.scheme),
              let external = URL(string: parsed.serialized()) else { throw PluginContractError(locale.text("仅允许打开 HTTP(S)、邮件链接和主机文件", "Only HTTP(S), email links and host files can be opened")) }
        guard NSWorkspace.shared.open(external) else { throw PluginContractError(locale.text("无法打开链接", "Could not open the link")) }
    }

    public func knownDirectories() async throws -> [NativeComposerDirectory] {
        let workspace = try requireWorkspace()
        let response = try await workspace.client.invoke("workspace:list-known-directories")
        guard let values = response.arrayValue else { throw PluginContractError("Invalid known directory response") }
        return try values.map { value in
            guard case let .string(name) = value["name"], case let .string(path) = value["path"] else {
                throw PluginContractError("Invalid known directory entry")
            }
            return NativeComposerDirectory(name: name, path: path)
        }
    }

    private func requireWorkspace() throws -> NativeWorkspaceModel {
        guard let workspace, !workspace.stopping else { throw CancellationError() }
        return workspace
    }
}
