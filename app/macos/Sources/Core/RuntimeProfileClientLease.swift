import CryptoKit
import Darwin
import Foundation
import Synchronization

/// Admit a native profile before reading retained state, and keep this lease
/// alive until all of that client's reads, writes and cleanup have finished.
/// The application retains its lease for the process lifetime.
public final class RuntimeProfileClientLease: @unchecked Sendable {
    private static let processLeases = Mutex<[Data: RuntimeProfileClientLease]>([:])
    public let profile: RuntimeProfile
    private let descriptor: Int32

    public init(dataDirectory: URL, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        guard dataDirectory.isFileURL, homeDirectory.isFileURL else {
            throw RuntimeError("INVALID_PROFILE", "Client profiles must use local file URLs")
        }
        let directory = try Self.openLeaseDirectory()
        defer { Darwin.close(directory.descriptor) }
        let admission = try Self.lockFile(directory: directory.descriptor, name: "admission.lock", mode: LOCK_EX)
        defer { Darwin.close(admission) }
        try Self.validateDirectory(directory)

        // Creation and canonicalization share the admission lock with fresh.
        // Two pre-creation case aliases must not select separate lease files.
        let selected = try RuntimeProfile(dataDirectory: dataDirectory, homeDirectory: homeDirectory)
        try FileManager.default.createDirectory(at: selected.dataDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let current = try RuntimeProfile(dataDirectory: selected.dataDirectory, homeDirectory: homeDirectory)
        let identity = SHA256.hash(data: Data(current.dataDirectory.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let shared = try Self.lockFile(directory: directory.descriptor, name: identity + ".lock", mode: LOCK_SH)
        do { try Self.validateDirectory(directory) }
        catch { Darwin.close(shared); throw error }
        descriptor = shared
        profile = current
    }

    deinit { Darwin.close(descriptor) }

    /// Application entry points outlive individual windows and may retain
    /// asynchronous writers after close. Never retire their lease early.
    public func retainForProcess() {
        let identity = Data(profile.dataDirectory.path.utf8)
        Self.processLeases.withLock { leases in
            if leases[identity] == nil { leases[identity] = self }
        }
    }

    private struct LeaseDirectory { let descriptor: Int32; let path: String }

    private static func openLeaseDirectory() throws -> LeaseDirectory {
        let count = Darwin.confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard count > 1, count <= 16 * 1024 else { throw ioFailure("locate the profile lease directory") }
        var path = [CChar](repeating: 0, count: count)
        guard Darwin.confstr(_CS_DARWIN_USER_TEMP_DIR, &path, path.count) == count else {
            throw ioFailure("locate the profile lease directory")
        }
        let temporary = path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        let root = URL(fileURLWithPath: temporary, isDirectory: true)
            .resolvingSymlinksInPath().appendingPathComponent("mokusei-profile-leases-v1", isDirectory: true)
        if root.path.withCString({ Darwin.mkdir($0, 0o700) }) != 0, errno != EEXIST {
            throw ioFailure("create the profile lease directory")
        }
        var before = stat()
        guard root.path.withCString({ Darwin.lstat($0, &before) }) == 0 else { throw ioFailure("inspect profile leases") }
        guard privateDirectory(before) else { throw unsafeLease() }
        let fd = root.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw ioFailure("open profile leases") }
        do {
            var after = stat()
            guard Darwin.fstat(fd, &after) == 0 else { throw ioFailure("inspect the opened profile lease directory") }
            guard privateDirectory(after), before.st_dev == after.st_dev, before.st_ino == after.st_ino else { throw unsafeLease() }
            return LeaseDirectory(descriptor: fd, path: root.path)
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private static func validateDirectory(_ directory: LeaseDirectory) throws {
        var opened = stat(), named = stat()
        guard Darwin.fstat(directory.descriptor, &opened) == 0,
              directory.path.withCString({ Darwin.lstat($0, &named) }) == 0 else { throw ioFailure("verify profile leases") }
        guard privateDirectory(opened), privateDirectory(named), opened.st_dev == named.st_dev,
              opened.st_ino == named.st_ino else { throw unsafeLease() }
    }

    private static func lockFile(directory: Int32, name: String, mode: Int32) throws -> Int32 {
        // Do not open an existing device/FIFO. Recheck after open and flock to
        // reject a path replaced during admission or a detached old lock inode.
        var before = stat()
        let inspected = name.withCString { Darwin.fstatat(directory, $0, &before, AT_SYMLINK_NOFOLLOW) }
        if inspected == 0 {
            guard privateFile(before) else { throw unsafeLease() }
        } else if errno != ENOENT { throw ioFailure("inspect a profile lease") }
        let fd = name.withCString {
            Darwin.openat(directory, $0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        }
        guard fd >= 0 else { throw ioFailure("open a profile lease") }
        do {
            let opened = try validateFile(fd, directory: directory, name: name)
            if inspected == 0 {
                guard opened.st_dev == before.st_dev, opened.st_ino == before.st_ino else { throw unsafeLease() }
            }
            // Darwin also exports a same-named struct; select the libc function.
            let acquire: (Int32, Int32) -> Int32 = flock
            while acquire(fd, mode | LOCK_NB) != 0 {
                if errno == EINTR { continue }
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    throw RuntimeError("PROFILE_MAINTENANCE", "This profile is being maintained. Try opening it again when maintenance finishes.")
                }
                throw ioFailure("acquire the profile lease")
            }
            _ = try validateFile(fd, directory: directory, name: name)
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private static func validateFile(_ fd: Int32, directory: Int32, name: String) throws -> stat {
        var opened = stat(), named = stat()
        guard Darwin.fstat(fd, &opened) == 0,
              name.withCString({ Darwin.fstatat(directory, $0, &named, AT_SYMLINK_NOFOLLOW) }) == 0 else {
            throw ioFailure("verify a profile lease")
        }
        guard privateFile(opened), privateFile(named), opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else {
            throw unsafeLease()
        }
        return opened
    }

    private static func privateDirectory(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFDIR && value.st_uid == getuid() && value.st_mode & 0o7777 == 0o700
    }
    private static func privateFile(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFREG && value.st_uid == getuid() && value.st_mode & 0o077 == 0 && value.st_nlink == 1
    }
    private static func unsafeLease() -> RuntimeError {
        RuntimeError("UNSAFE_PROFILE_LOCK", "Profile lease files must be private, owned by this account and remain at their original path.")
    }
    private static func ioFailure(_ operation: String) -> RuntimeError {
        RuntimeError("PROFILE_LOCK_IO", "Unable to \(operation) (errno \(errno))")
    }
}
