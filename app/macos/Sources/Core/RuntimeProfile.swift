import CryptoKit
import Darwin
import Foundation

extension RuntimeConnection {
    public var isOwnerAlive: Bool { RuntimeProfile.isProcessAlive(pid) }
}

/// Shares the runtime's canonical profile identity and private metadata format.
public struct RuntimeProfile: Sendable, Equatable {
    public let dataDirectory: URL
    public let workspaceRoot: URL
    public let discoveryURL: URL
    public let lockURL: URL

    public init(
        dataDirectory: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        guard homeDirectory.isFileURL, dataDirectory?.isFileURL != false else {
            throw RuntimeError("INVALID_PROFILE", "Runtime profile paths must be local file URLs")
        }
        let selectedDirectory = dataDirectory
            ?? ProcessInfo.processInfo.environment["MOKUSEI_RUNTIME_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? homeDirectory.appendingPathComponent("Library/Application Support/Mokusei", isDirectory: true)
        let canonicalDirectory = Self.canonicalPath(selectedDirectory)
        self.dataDirectory = canonicalDirectory
        let identity = SHA256.hash(data: Data(canonicalDirectory.path.utf8)).map { String(format: "%02x", $0) }.joined()
        self.workspaceRoot = Self.canonicalPath(homeDirectory.appendingPathComponent(".Mokusei/profiles/\(identity)/runtime-workspace", isDirectory: true))
        let metadataDirectory = canonicalDirectory.appendingPathComponent("runtime", isDirectory: true)
        self.discoveryURL = metadataDirectory.appendingPathComponent("connection.json")
        self.lockURL = metadataDirectory.appendingPathComponent("owner.json")
    }

    /// Resolve the deepest existing ancestor first, including symlink aliases.
    /// `resolvingSymlinksInPath` alone does not canonicalize every missing suffix.
    private static func canonicalPath(_ url: URL) -> URL {
        let normalized = url.standardizedFileURL
        if let resolved = normalized.path.withCString({ Darwin.realpath($0, nil) }) {
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        }
        let parent = normalized.deletingLastPathComponent()
        guard parent.path != normalized.path else { return normalized }
        return canonicalPath(parent).appendingPathComponent(normalized.lastPathComponent, isDirectory: true)
    }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = discoveryURL.deletingLastPathComponent()
        // mkdir must not follow an existing runtime-directory symlink.
        if directory.path.withCString({ Darwin.mkdir($0, 0o700) }) != 0, errno != EEXIST {
            throw Self.profileIOError("create runtime metadata directory")
        }
        let descriptor = try openMetadataDirectory(requirePrivate: false)
        defer { Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, 0o700) == 0 else {
            throw Self.profileIOError("protect runtime metadata directory")
        }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0, Self.isPrivateDirectory(metadata) else {
            throw Self.unsafeMetadata()
        }
    }

    public func readConnection() throws -> RuntimeConnection? {
        guard let value = try readPrivateJSON(discoveryURL) else { return nil }
        // The profile may have been selected before another launcher created
        // its directory with the filesystem's canonical spelling.
        let canonicalDirectory = Self.canonicalPath(dataDirectory)
        guard let port = value["port"]?.intValue, (1...65_535).contains(port),
              let token = value["token"]?.stringValue, token.utf16.count >= 32,
              let epoch = value["epoch"]?.stringValue, !epoch.isEmpty,
              let protocolVersion = value["protocolVersion"]?.intValue,
              let pid = value["pid"]?.intValue, pid > 0, pid <= Int(Int32.max),
              let dataDir = value["dataDir"]?.stringValue, dataDir == canonicalDirectory.path else {
            throw RuntimeError("INVALID_DISCOVERY", "Runtime discovery metadata is invalid or belongs to another profile")
        }
        return RuntimeConnection(port: port, token: token, epoch: epoch, protocolVersion: protocolVersion, pid: pid, dataDir: dataDir)
    }

    public func hasLiveOwner() throws -> Bool {
        guard let owner = try readPrivateJSON(lockURL), let pid = owner["pid"]?.intValue else { return false }
        return Self.isProcessAlive(pid)
    }

    public func writeOutputLocale(_ locale: String) throws {
        guard locale == "zh-CN" || locale == "en-US" else {
            throw RuntimeError("INVALID_OUTPUT_LOCALE", "Output locale must be zh-CN or en-US")
        }
        try prepare()
        let directory = try openMetadataDirectory()
        defer { Darwin.close(directory) }
        let temporary = "output-locale.json.\(UUID().uuidString).tmp"
        let descriptor = temporary.withCString { Darwin.openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard descriptor >= 0 else { throw Self.profileIOError("create output locale metadata") }
        defer {
            Darwin.close(descriptor)
            _ = temporary.withCString { Darwin.unlinkat(directory, $0, 0) }
        }
        // Values are a fixed enum; serialization never interpolates arbitrary text.
        let data = Data("{\"locale\":\"\(locale)\"}".utf8)
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw Self.profileIOError("write output locale metadata") }
                offset += written
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw Self.profileIOError("flush output locale metadata") }
        let renamed = temporary.withCString { source in
            "output-locale.json".withCString { target in Darwin.renameat(directory, source, directory, target) }
        }
        guard renamed == 0 else { throw Self.profileIOError("publish output locale metadata") }
    }

    static func isProcessAlive(_ pid: Int) -> Bool {
        guard pid > 0, pid <= Int(Int32.max) else { return false }
        return Darwin.kill(pid_t(pid), 0) == 0 || errno != ESRCH
    }

    private static func isDirectory(_ metadata: stat) -> Bool {
        metadata.st_mode & S_IFMT == S_IFDIR && metadata.st_uid == getuid()
    }

    private static func isPrivateDirectory(_ metadata: stat) -> Bool {
        isDirectory(metadata) && metadata.st_mode & 0o777 == 0o700
    }

    private static func isPrivateFile(_ metadata: stat) -> Bool {
        metadata.st_mode & S_IFMT == S_IFREG && metadata.st_uid == getuid()
            && metadata.st_mode & 0o077 == 0 && metadata.st_size >= 0 && metadata.st_size <= 64 * 1024
    }

    private func openMetadataDirectory(requirePrivate: Bool = true) throws -> Int32 {
        let path = discoveryURL.deletingLastPathComponent().path
        var before = stat()
        guard path.withCString({ Darwin.lstat($0, &before) }) == 0 else {
            throw Self.profileIOError("inspect runtime metadata directory")
        }
        guard Self.isDirectory(before), !requirePrivate || Self.isPrivateDirectory(before) else { throw Self.unsafeMetadata() }
        let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw Self.profileIOError("open runtime metadata directory") }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0, Self.isDirectory(after),
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              !requirePrivate || Self.isPrivateDirectory(after) else {
            Darwin.close(descriptor)
            throw Self.unsafeMetadata()
        }
        return descriptor
    }

    private func readPrivateJSON(_ url: URL) throws -> JSONValue? {
        let directory: Int32
        do { directory = try openMetadataDirectory() }
        catch let error as RuntimeError where error.code == "PROFILE_NOT_FOUND" { return nil }
        defer { Darwin.close(directory) }
        let name = url.lastPathComponent
        var before = stat()
        guard name.withCString({ Darwin.fstatat(directory, $0, &before, AT_SYMLINK_NOFOLLOW) }) == 0 else {
            if errno == ENOENT { return nil }
            throw Self.profileIOError("inspect runtime metadata")
        }
        guard Self.isPrivateFile(before) else { throw Self.unsafeMetadata() }
        let descriptor = name.withCString { Darwin.openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw Self.profileIOError("open runtime metadata")
        }
        defer { Darwin.close(descriptor) }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0, Self.isPrivateFile(after),
              before.st_dev == after.st_dev, before.st_ino == after.st_ino else { throw Self.unsafeMetadata() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw Self.profileIOError("read runtime metadata") }
            if count == 0 { break }
            guard data.count + count <= 64 * 1024 else { throw Self.unsafeMetadata() }
            data.append(contentsOf: buffer.prefix(count))
        }
        do { return try JSONValue.parse(data: data) }
        catch { throw RuntimeError("INVALID_DISCOVERY", "Runtime metadata is not valid JSON") }
    }

    private static func unsafeMetadata() -> RuntimeError {
        RuntimeError("UNSAFE_PROFILE", "Runtime metadata must be private, owned by the current account, and contain no symbolic links")
    }

    private static func profileIOError(_ operation: String) -> RuntimeError {
        let code = errno
        return RuntimeError(code == ENOENT ? "PROFILE_NOT_FOUND" : "PROFILE_IO_ERROR", "Unable to \(operation) (errno \(code))")
    }
}
