import Darwin
import Foundation
import Synchronization

/// Staged files belong to the importing process until a draft or Thread owns
/// them. Keep the lock through late command receipts and asynchronous shutdown.
final class RuntimeAttachmentLease: @unchecked Sendable {
    private static let processLeases = Mutex<[Data: RuntimeAttachmentLease]>([:])
    let id: String
    private let descriptor: Int32
    private let directory: URL
    private let referencesFile: URL
    private let owners = Mutex<[UUID: Set<JSONText>]>([:])

    static func retainForProcess(in directory: URL) throws -> String {
        try withSharedOwnership(in: directory) { try processLeaseWhileLocked(in: directory).id }
    }

    private static func processLeaseWhileLocked(in directory: URL) throws -> RuntimeAttachmentLease {
        let canonical = try RuntimeProfile(dataDirectory: directory).dataDirectory
        let identity = Data(canonical.path.utf8)
        return try processLeases.withLock { leases in
            if let lease = leases[identity] { return lease }
            let lease = try RuntimeAttachmentLease(directory: canonical)
            leases[identity] = lease
            return lease
        }
    }

    /// Pair short local reads/writes with the collector's exclusive gate. No
    /// network operation or suspension belongs inside this critical section.
    static func withSharedOwnership<T>(in directory: URL, _ operation: () throws -> T) throws -> T {
        try withOwnership(in: directory, mode: LOCK_SH, operation)
    }

    static func withExclusiveOwnership<T>(in directory: URL, _ operation: () throws -> T) throws -> T {
        try withOwnership(in: directory, mode: LOCK_EX, operation)
    }

    private static func withOwnership<T>(in directory: URL, mode: Int32, _ operation: () throws -> T) throws -> T {
        let opened = try openDirectory(in: directory)
        defer { Darwin.close(opened.descriptor) }
        let name = "ownership.lock"
        var before = stat()
        let inspected = name.withCString { Darwin.fstatat(opened.descriptor, $0, &before, AT_SYMLINK_NOFOLLOW) }
        if inspected == 0 {
            guard privateFile(before) else { throw unsafeLease() }
        } else if errno != ENOENT { throw ioFailure("inspect attachment ownership") }
        let gate = name.withCString {
            Darwin.openat(opened.descriptor, $0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        }
        guard gate >= 0 else { throw ioFailure("open attachment ownership") }
        defer { Darwin.close(gate) }
        let acquire: (Int32, Int32) -> Int32 = flock
        while acquire(gate, mode) != 0 {
            if errno == EINTR { continue }
            throw ioFailure("acquire attachment ownership")
        }
        var file = stat(), named = stat(), currentDirectory = stat()
        guard Darwin.fstat(gate, &file) == 0,
              name.withCString({ Darwin.fstatat(opened.descriptor, $0, &named, AT_SYMLINK_NOFOLLOW) }) == 0,
              opened.root.path.withCString({ Darwin.lstat($0, &currentDirectory) }) == 0,
              privateFile(file), privateFile(named), privateDirectory(currentDirectory),
              file.st_dev == named.st_dev, file.st_ino == named.st_ino,
              inspected != 0 || (before.st_dev == file.st_dev && before.st_ino == file.st_ino),
              opened.identity.st_dev == currentDirectory.st_dev,
              opened.identity.st_ino == currentDirectory.st_ino else { throw unsafeLease() }
        return try operation()
    }

    static func ownerWhileLocked(in directory: URL, attachmentIDs: [JSONText]) throws -> RuntimeAttachmentOwner {
        try processLeaseWhileLocked(in: directory).makeOwnerWhileLocked(attachmentIDs)
    }

    private func makeOwnerWhileLocked(_ attachmentIDs: [JSONText]) throws -> RuntimeAttachmentOwner {
        let token = UUID()
        try updateOwnerWhileLocked(token, attachmentIDs: attachmentIDs)
        return RuntimeAttachmentOwner(lease: self, token: token)
    }

    fileprivate func capture(_ attachmentIDs: [JSONText]) throws -> RuntimeAttachmentOwner {
        try Self.withSharedOwnership(in: directory) { try makeOwnerWhileLocked(attachmentIDs) }
    }

    fileprivate func replace(_ token: UUID, attachmentIDs: [JSONText]?) throws {
        try Self.withSharedOwnership(in: directory) { try updateOwnerWhileLocked(token, attachmentIDs: attachmentIDs) }
    }

    private func updateOwnerWhileLocked(_ token: UUID, attachmentIDs: [JSONText]?) throws {
        try owners.withLock { current in
            let replacement = attachmentIDs.map(Set.init)
            if current[token] == replacement { return }
            let previousIDs = Set(current.values.flatMap { $0 })
            var next = current
            next[token] = replacement
            let nextIDs = Set(next.values.flatMap { $0 })
            if previousIDs != nextIDs {
                let ids = nextIDs.sorted { $0.codeUnits.lexicographicallyPrecedes($1.codeUnits) }
                let document = runtimeObject(["version": .integer(1), "attachmentIDs": .array(ids.map(JSONValue.string))])
                try RuntimePrivateFile.write(document.encodedData(), to: referencesFile)
            }
            current = next
        }
    }

    private init(directory: URL) throws {
        let opened = try Self.openDirectory(in: directory)
        defer { Darwin.close(opened.descriptor) }
        let lease = try Self.createLease(root: opened.root, directory: opened.descriptor, identity: opened.identity)
        descriptor = lease.descriptor
        id = lease.id
        self.directory = directory
        referencesFile = opened.root.appendingPathComponent(lease.id + ".refs.json")
    }

    private static func openDirectory(in directory: URL) throws -> (root: URL, descriptor: Int32, identity: stat) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let root = directory.appendingPathComponent("client-attachment-leases", isDirectory: true)
        if root.path.withCString({ Darwin.mkdir($0, 0o700) }) != 0, errno != EEXIST {
            throw Self.ioFailure("create attachment leases")
        }
        var namedDirectory = stat()
        guard root.path.withCString({ Darwin.lstat($0, &namedDirectory) }) == 0,
              Self.privateDirectory(namedDirectory) else { throw Self.unsafeLease() }
        let directoryDescriptor = root.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryDescriptor >= 0 else { throw Self.ioFailure("open attachment leases") }
        var openedDirectory = stat()
        guard Darwin.fstat(directoryDescriptor, &openedDirectory) == 0,
              Self.privateDirectory(openedDirectory),
              namedDirectory.st_dev == openedDirectory.st_dev,
              namedDirectory.st_ino == openedDirectory.st_ino else {
            Darwin.close(directoryDescriptor)
            throw Self.unsafeLease()
        }
        return (root, directoryDescriptor, openedDirectory)
    }

    deinit { Darwin.close(descriptor) }

    private static func createLease(root: URL, directory: Int32, identity: stat) throws -> (id: String, descriptor: Int32) {
        // A collector may claim the new file before flock. Retry a fresh name
        // after that race; a lock on an unlinked inode cannot protect staging.
        for _ in 0..<8 {
            let id = UUID().uuidString.lowercased()
            let name = id + ".lock"
            let file = name.withCString {
                Darwin.openat(directory, $0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
            }
            if file < 0 {
                if errno == EEXIST { continue }
                throw ioFailure("create an attachment lease")
            }
            var retained = false
            defer { if !retained { Darwin.close(file) } }
            let acquire: (Int32, Int32) -> Int32 = flock
            var locked = false
            while !locked {
                if acquire(file, LOCK_EX | LOCK_NB) == 0 { locked = true; break }
                if errno == EINTR { continue }
                if errno == EWOULDBLOCK || errno == EAGAIN { break }
                throw ioFailure("hold the attachment lease")
            }
            if !locked { continue }
            var opened = stat(), named = stat(), currentDirectory = stat()
            guard Darwin.fstat(file, &opened) == 0 else { throw ioFailure("inspect the attachment lease") }
            if name.withCString({ Darwin.fstatat(directory, $0, &named, AT_SYMLINK_NOFOLLOW) }) != 0 {
                if errno == ENOENT { continue }
                throw ioFailure("verify the attachment lease")
            }
            guard root.path.withCString({ Darwin.lstat($0, &currentDirectory) }) == 0,
                  privateFile(opened), privateFile(named), privateDirectory(currentDirectory),
                  opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
                  identity.st_dev == currentDirectory.st_dev, identity.st_ino == currentDirectory.st_ino else { throw unsafeLease() }
            // The manifest can reference this name after a service restart.
            guard Darwin.fsync(file) == 0, Darwin.fsync(directory) == 0 else { throw ioFailure("persist the attachment lease") }
            retained = true
            return (id, file)
        }
        throw RuntimeError("ATTACHMENT_LEASE_BUSY", "Attachment cleanup is changing ownership; try importing again")
    }

    private static func privateDirectory(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFDIR && value.st_uid == getuid() && value.st_mode & 0o7777 == 0o700
    }

    private static func privateFile(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFREG && value.st_uid == getuid() && value.st_mode & 0o077 == 0 && value.st_nlink == 1
    }

    private static func unsafeLease() -> RuntimeError {
        RuntimeError("UNSAFE_ATTACHMENT_LEASE", "Attachment lease files must remain private and at their original path")
    }

    private static func ioFailure(_ operation: String) -> RuntimeError {
        RuntimeError("ATTACHMENT_LEASE_IO", "Unable to \(operation) (errno \(errno))")
    }
}

/// One in-memory draft or pending submission owns one token. Releasing another
/// token cannot discard these references, even when both read the same draft.
public final class RuntimeAttachmentOwner: @unchecked Sendable {
    private let lease: RuntimeAttachmentLease
    private let token: UUID
    private let released = Mutex(false)

    fileprivate init(lease: RuntimeAttachmentLease, token: UUID) {
        self.lease = lease
        self.token = token
    }

    public func replace(_ attachmentIDs: [JSONText]) throws {
        try released.withLock { retired in
            guard !retired else { throw RuntimeError("ATTACHMENT_OWNER_RETIRED", "The attachment owner has been released") }
            try lease.replace(token, attachmentIDs: attachmentIDs)
        }
    }

    public func capture(_ attachmentIDs: [JSONText]) throws -> RuntimeAttachmentOwner {
        try released.withLock { retired in
            guard !retired else { throw RuntimeError("ATTACHMENT_OWNER_RETIRED", "The attachment owner has been released") }
            return try lease.capture(attachmentIDs)
        }
    }

    public func release() throws {
        try released.withLock { retired in
            guard !retired else { return }
            try lease.replace(token, attachmentIDs: nil)
            retired = true
        }
    }

    /// If final persistence failed, no later destructor may turn those unsaved
    /// references into garbage. The kernel lease bounds this fallback to exit.
    public func preserveUntilProcessExit() { released.withLock { $0 = true } }

    deinit { try? release() }
}

extension RuntimeClient {
    func connectionWithAttachmentLease(_ source: RuntimeConnection) throws -> RuntimeConnection {
        var result = source
        result.attachmentLease = nil
        let storage = try RuntimeProfile(dataDirectory: storageDirectory).dataDirectory
        let host = try RuntimeProfile(dataDirectory: URL(fileURLWithPath: source.dataDir)).dataDirectory
        // Fixture/read-only clients may use separate local storage, but staging
        // cannot place durable draft references outside the host's authority.
        if Data(storage.path.utf8) == Data(host.path.utf8) {
            result.attachmentLease = try RuntimeAttachmentLease.retainForProcess(in: storage)
        }
        return result
    }
}

extension RuntimeConnection {
    func requireAttachmentLease() throws {
        guard attachmentLease != nil else {
            throw RuntimeError("ATTACHMENT_PROFILE_MISMATCH", "Attachment imports require drafts and the runtime to share the same local profile")
        }
    }
}
