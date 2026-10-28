import Foundation
import CryptoKit
import Darwin

public struct RuntimeAttachmentPolicy: Codable, Equatable, Sendable {
    public let imageBytes: Int
    public let pdfBytes: Int
    public let fileBytes: Int
    public let messageBytes: Int
    public let messageCount: Int
    public init(imageBytes: Int, pdfBytes: Int, fileBytes: Int, messageBytes: Int, messageCount: Int) {
        self.imageBytes = imageBytes; self.pdfBytes = pdfBytes; self.fileBytes = fileBytes
        self.messageBytes = messageBytes; self.messageCount = messageCount
    }
    public func maximumBytes(mimeType: String) -> Int {
        if mimeType.hasPrefix("image/") { return imageBytes }
        return mimeType == "application/pdf" ? pdfBytes : fileBytes
    }
}

/// A path belongs to one authenticated host. It is never a device file URL.
public struct RuntimeHostFileReference: Codable, Equatable, Hashable, Sendable {
    public let hostID: String
    public let path: String
    public let revision: String?
    public init(hostID: String, path: String, revision: String? = nil) {
        self.hostID = hostID; self.path = path; self.revision = revision
    }
}

public struct RuntimeHostFileEntry: Codable, Equatable, Sendable, Identifiable {
    public let reference: RuntimeHostFileReference
    public let name: String
    public let isDirectory: Bool
    public let size: Int
    public let mimeType: String
    // A directory entry keeps its own identity even when aliases resolve to
    // the same authenticated file reference.
    public var id: String { "\(reference.hostID.utf8.count):\(reference.hostID)\(reference.path.utf8.count):\(reference.path)\(name)" }
}

public struct RuntimeHostDirectory: Codable, Equatable, Sendable {
    public let reference: RuntimeHostFileReference
    public let parent: RuntimeHostFileReference?
    public let entries: [RuntimeHostFileEntry]
}

public struct RuntimeDownloadedFile: Sendable {
    public let url: URL
    public let name: String
    public let mimeType: String
    public let size: Int
    public let sha256: String
}

extension RuntimeClient {
    /// File operations require a live connection. They never queue offline or
    /// retry under another host. Stream retirement cancels every active transfer.
    private func fileOperation(_ operation: @escaping @Sendable (RuntimeConnection, RuntimeTransport) async throws -> JSONValue) async throws -> JSONValue {
        try assertOpen()
        guard status == .connected, !explicitlyStopped, let connection else {
            throw RuntimeError("SERVICE_NOT_RUNNING", "Connect to the host before transferring files")
        }
        guard sessionRequests.count < 16 else { throw RuntimeError("CAPACITY_EXHAUSTED", "Too many active host requests") }
        let expected = generation, id = UUID()
        let task = Task { try await operation(connection, transport) }
        sessionRequests[id] = task
        defer { sessionRequests.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            let value = try await task.value
            try Task.checkCancellation()
            guard !closed, generation == expected, self.connection == connection, status == .connected else {
                throw RuntimeError("STALE_CONNECTION", "The host connection changed during transfer")
            }
            return value
        } onCancel: { task.cancel() }
    }

    public func attachmentPolicy() async throws -> RuntimeAttachmentPolicy {
        let value = try await fileOperation { connection, transport in
            try runtimeResult(await transport.request(connection: connection, path: "/files/policy"))
        }
        let policy = try JSONDecoder().decode(RuntimeAttachmentPolicy.self, from: value.encodedData())
        guard policy.imageBytes > 0, policy.pdfBytes > 0, policy.fileBytes > 0, policy.messageBytes > 0,
              (1...1000).contains(policy.messageCount) else { throw RuntimeError("INVALID_RESPONSE", "Invalid host attachment policy") }
        return policy
    }

    public func hostDirectory(_ reference: RuntimeHostFileReference? = nil) async throws -> RuntimeHostDirectory {
        struct Request: Encodable { let reference: RuntimeHostFileReference? }
        let body = try JSONEncoder().encode(Request(reference: reference))
        let value = try await fileOperation { connection, transport in
            try runtimeResult(await transport.request(connection: connection, path: "/files/browse", method: "POST", body: body))
        }
        return try JSONDecoder().decode(RuntimeHostDirectory.self, from: value.encodedData())
    }

    public func stageHostFiles(_ references: [RuntimeHostFileReference]) async throws -> [JSONValue] {
        struct Request: Encodable { let references: [RuntimeHostFileReference] }
        let body = try JSONEncoder().encode(Request(references: references))
        let value = try await fileOperation { connection, transport in
            try runtimeResult(await transport.request(connection: connection, path: "/files/stage-host", method: "POST", body: body, timeout: 600))
        }
        guard let records = value.arrayValue, records.count == references.count else { throw RuntimeError("INVALID_RESPONSE", "Incomplete host attachment import") }
        return records
    }

    public func uploadAttachment(file: URL, name: String) async throws -> JSONValue {
        let policy = try await attachmentPolicy()
        let directory = storageDirectory.appendingPathComponent("transfers/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let frozen = directory.appendingPathComponent("upload")
        let prepare = Task.detached(priority: .userInitiated) {
            try RuntimeFileCopy.snapshot(source: file, destination: frozen, maximumBytes: policy.fileBytes)
        }
        let metadata = try await withTaskCancellationHandler { try await prepare.value } onCancel: { prepare.cancel() }
        return try await fileOperation { connection, transport in
            let channel = try RuntimeHTTPChannel(connection: connection, path: "/files/upload", method: "POST", body: nil,
                timeout: 600, uploadFile: frozen, headers: [
                    "Content-Type": "application/octet-stream", "Content-Length": String(metadata.size),
                    "X-Mokusei-File-Name": Data(name.utf8).base64URLEncodedString(), "X-Mokusei-SHA256": metadata.digest
                ])
            return try runtimeResult(await transport.response(channel))
        }
    }

    public func downloadHostFile(_ reference: RuntimeHostFileReference) async throws -> RuntimeDownloadedFile {
        struct Request: Encodable { let reference: RuntimeHostFileReference }
        let body = try JSONEncoder().encode(Request(reference: reference))
        let directory = storageDirectory.appendingPathComponent("downloads/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: directory) } }
        let partial = directory.appendingPathComponent(".partial")
        let value = try await fileOperation { connection, transport in
            try await transport.download(connection: connection, body: body, destination: partial)
        }
        guard let name = value["name"]?.stringValue, let mime = value["mimeType"]?.stringValue,
              let size = value["size"]?.intValue, let digest = value["sha256"]?.stringValue else {
            throw RuntimeError("INVALID_RESPONSE", "Invalid download metadata")
        }
        // Use the host's basename only; it cannot address any client directory.
        let safeName = URL(fileURLWithPath: name).lastPathComponent
        guard !safeName.isEmpty, safeName != ".", safeName != "..", !safeName.contains("\0") else { throw RuntimeError("INVALID_RESPONSE", "Invalid downloaded filename") }
        let destination = directory.appendingPathComponent(safeName)
        if partial != destination { try FileManager.default.moveItem(at: partial, to: destination) }
        completed = true
        return RuntimeDownloadedFile(url: destination, name: safeName, mimeType: mime, size: size, sha256: digest)
    }
}

private enum RuntimeFileCopy {
    struct Metadata: Sendable { let size: Int; let digest: String }
    static func snapshot(source: URL, destination: URL, maximumBytes: Int) throws -> Metadata {
        guard source.isFileURL else { throw RuntimeError("INVALID_FILE", "Only device files can be uploaded") }
        try Task.checkCancellation()
        // Opening a FIFO must not block before cancellation can be observed.
        // Validate the opened descriptor, retaining support for user-selected
        // symlinks to regular files without a stat/open replacement race.
        let descriptor = source.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { throw RuntimeError("INVALID_FILE", "Attachment could not be opened") }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= maximumBytes else { throw RuntimeError("INVALID_FILE", "Attachment is not a bounded regular file") }
        let size = Int(before.st_size)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw RuntimeError("FILE_WRITE_FAILED", "Could not create a private upload snapshot")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var total = 0, hash = SHA256()
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            guard chunk.count <= maximumBytes-total else { throw RuntimeError("FILE_CHANGED", "Attachment grew while importing") }
            total += chunk.count; hash.update(data: chunk); try output.write(contentsOf: chunk)
        }
        var after = stat(), current = stat()
        let currentStatus = source.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.fstatat(AT_FDCWD, $0, &current, 0) } ?? -1
        }
        guard fstat(descriptor, &after) == 0, currentStatus == 0,
              current.st_dev == before.st_dev, current.st_ino == before.st_ino,
              total == size, after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else {
            throw RuntimeError("FILE_CHANGED", "Attachment changed while importing; select it again")
        }
        try output.synchronize(); try Task.checkCancellation()
        return Metadata(size: total, digest: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

private extension Data {
    func base64URLEncodedString() -> String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(base64URLString: String) {
        var value = base64URLString.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4-value.count % 4) % 4)
        self.init(base64Encoded: value)
    }
}

extension RuntimeTransport {
    func download(connection: RuntimeConnection, body: Data, destination: URL) async throws -> JSONValue {
        let channel = try RuntimeHTTPChannel(connection: connection, path: "/files/download", method: "POST", body: body,
            timeout: 600, maximumResponseBytes: Int64.max)
        return try await withTaskCancellationHandler {
            defer { channel.cancel() }
            guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw RuntimeError("FILE_WRITE_FAILED", "Could not create a private download")
            }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            var response: HTTPURLResponse?, total = 0, errorBytes = Data(), hash = SHA256()
            for try await part in channel.parts {
                try Task.checkCancellation()
                switch part {
                case .response(let headers): response = headers
                case .bytes(let chunk):
                    // Consume after the disk write to keep the producer queue bounded.
                    defer { channel.consumed(chunk.count) }
                    guard let response else { throw RuntimeError("INVALID_RESPONSE", "Host sent file bytes before headers") }
                    if response.statusCode != 200 {
                        guard errorBytes.count <= 1024*1024-chunk.count else { throw RuntimeError("INVALID_RESPONSE", "Host file error exceeds limit") }
                        errorBytes.append(chunk); continue
                    }
                    guard response.expectedContentLength >= 0, total <= Int.max-chunk.count,
                          Int64(total+chunk.count) <= response.expectedContentLength else { throw RuntimeError("FILE_CHANGED", "Downloaded length differs from host metadata") }
                    try output.write(contentsOf: chunk); total += chunk.count; hash.update(data: chunk)
                }
            }
            guard let response else { throw RuntimeError("INVALID_RESPONSE", "Host file response has no headers") }
            if response.statusCode != 200 { return try decodeResponse(errorBytes, response: response) }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard Int64(total) == response.expectedContentLength, digest == response.value(forHTTPHeaderField: "X-Mokusei-SHA256"),
                  let encoded = response.value(forHTTPHeaderField: "X-Mokusei-File-Name"), let nameData = Data(base64URLString: encoded),
                  let name = String(data: nameData, encoding: .utf8) else { throw RuntimeError("FILE_CHANGED", "Downloaded file failed length or checksum validation") }
            try output.synchronize(); try Task.checkCancellation()
            return .object(["name": .text(name), "mimeType": .text(response.mimeType ?? "application/octet-stream"), "size": .number(Double(total)), "sha256": .text(digest)])
        } onCancel: { channel.cancel() }
    }
}
