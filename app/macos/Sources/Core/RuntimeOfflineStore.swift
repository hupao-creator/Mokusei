import CryptoKit
import Foundation

/// Device-owned reading bytes. This directory is separate from drafts and the
/// command journal: evicting old reading content can never remove unsent work.
struct RuntimeOfflineStore: Sendable {
    static let maximumBytes = 64 * 1024 * 1024
    static let maximumEntries = 128
    let directory: URL
    let hostID: String

    init(storageDirectory: URL, hostID: String?) {
        directory = storageDirectory.appendingPathComponent("client-reading-cache", isDirectory: true)
        self.hostID = hostID ?? "local"
    }

    func state() -> JSONValue? {
        guard let value = read("state"), (try? RuntimeState.validateSnapshot(value)) != nil else { return nil }
        return value
    }

    func content(thread: JSONText, scope: RuntimeContentScope) -> JSONValue? {
        read(contentKey(thread: thread, scope: scope))
    }

    func saveState(_ value: JSONValue) throws { try write(value, key: "state") }
    func saveContent(_ value: JSONValue, thread: JSONText, scope: RuntimeContentScope) throws {
        try write(value, key: contentKey(thread: thread, scope: scope))
    }

    private func contentKey(thread: JSONText, scope: RuntimeContentScope) -> String {
        let key = runtimeObject(["thread": .string(thread), "scope": scope.json])
        return "content-" + RuntimePrivateFile.key((try? key.encodedData()) ?? Data())
    }

    private func read(_ key: String) -> JSONValue? {
        let file = directory.appendingPathComponent(key + ".json")
        guard let data = try? RuntimePrivateFile.read(file, maximumBytes: RuntimeProtocol.maxResponseBytes + 1024),
              let document = try? JSONValue(data: data), document["version"]?.intValue == 1,
              document["hostID"]?.stringValue == hostID, let value = document["value"] else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return value
    }

    private func write(_ value: JSONValue, key: String) throws {
        let data = try runtimeObject(["version": .integer(1), "hostID": .text(hostID), "value": value]).encodedData()
        guard data.count <= RuntimeProtocol.maxResponseBytes + 1024 else { return }
        let file = directory.appendingPathComponent(key + ".json")
        try RuntimePrivateFile.write(data, to: file)
        try trim(keeping: file)
    }

    private func trim(keeping protected: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
        var entries: [(URL, Int, Date)] = []
        for file in files where file.pathExtension == "json" {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            entries.append((file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast))
        }
        var bytes = entries.reduce(0) { $0 + $1.1 }
        var count = entries.count
        for entry in entries.sorted(by: { $0.2 < $1.2 }) where entry.0 != protected {
            guard bytes > Self.maximumBytes || count > Self.maximumEntries else { break }
            try FileManager.default.removeItem(at: entry.0)
            bytes -= entry.1; count -= 1
        }
    }
}

/// A draft is durable user input, never part of the evictable reading cache.
/// The caller supplies a host-specific directory and an opaque surface identity.
public struct RuntimeDraftStore: Sendable {
    private let file: URL
    private let scope: JSONText

    public init(storageDirectory: URL, scope: JSONText) {
        self.scope = scope
        let encoded = (try? JSONValue.string(scope).encodedData()) ?? Data()
        file = storageDirectory.appendingPathComponent("client-drafts", isDirectory: true)
            .appendingPathComponent(RuntimePrivateFile.key(encoded) + ".json")
    }

    public func load() throws -> JSONValue? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try RuntimePrivateFile.read(file, maximumBytes: RuntimeProtocol.maxRequestBytes)
        let document = try JSONValue(data: data)
        guard document["version"]?.intValue == 1, document["scope"] == .string(scope), let value = document["value"] else {
            throw RuntimeError("DRAFT_STORAGE_INVALID", "The saved draft could not be read")
        }
        return value
    }

    public func save(_ value: JSONValue) throws {
        let data = try runtimeObject(["version": .integer(1), "scope": .string(scope), "value": value]).encodedData()
        guard data.count <= RuntimeProtocol.maxRequestBytes else { throw RuntimeError("DRAFT_TOO_LARGE", "The draft exceeds the local storage limit") }
        try RuntimePrivateFile.write(data, to: file)
    }
}

enum RuntimePrivateFile {
    static func key(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func read(_ file: URL, maximumBytes: Int) throws -> Data {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= maximumBytes else {
            throw RuntimeError("CLIENT_STORAGE_INVALID", "Client storage is invalid or exceeds its size limit")
        }
        let data = try Data(contentsOf: file)
        guard data.count <= maximumBytes else { throw RuntimeError("CLIENT_STORAGE_INVALID", "Client storage exceeds its size limit") }
        return data
    }

    static func write(_ data: Data, to file: URL) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw RuntimeError("CLIENT_STORAGE_INVALID", "Client storage must be a private directory")
        }
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: attributes) else {
            throw RuntimeError("CLIENT_STORAGE_INVALID", "Could not create a private client record")
        }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(temporary.path, file.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
