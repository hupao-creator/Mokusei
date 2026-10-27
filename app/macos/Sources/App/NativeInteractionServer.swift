import Darwin
import Foundation
import MokuseiCore
import MokuseiUI

/// Opt-in window automation, deliberately separate from the Runtime's authority.
/// All socket callbacks and actions run on the main queue; nonblocking I/O and
/// bounded frames keep a slow client from holding up the UI.
@MainActor
final class NativeInteractionServer {
    private final class Client {
        let fd: Int32
        let reader: DispatchSourceRead
        var writer: DispatchSourceWrite?
        var input = Data()
        var output = Data()
        var lastActivity = Date()
        init(fd: Int32, reader: DispatchSourceRead) { self.fd = fd; self.reader = reader }
    }
    private let path: String
    private let listener: DispatchSourceRead
    private let timer: DispatchSourceTimer
    private let presentation: () -> NativeWorkspacePresentation?
    private var clients: [Int32: Client] = [:]
    private var stopped = false
    private let session = UUID().uuidString
    private var sequence = 0
    private let socketIdentity: (dev_t, ino_t)
    private static let maximumFrame = 64 * 1024
    private static let maximumOutput = 2 * 1024 * 1024

    init(path: String, presentation: @escaping () -> NativeWorkspacePresentation?) throws {
        self.path = path; self.presentation = presentation
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [UInt8(0)]
        guard path.hasPrefix("/"), !path.utf8.contains(0), bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw NativeInteractionError("invalid_socket", "Automation socket path is invalid or too long")
        }
        // Require a private parent. Never chmod an existing user directory or
        // unlink an occupied path: another app may own it, even after a crash.
        var parent = stat()
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard lstat(directory, &parent) == 0, parent.st_mode & S_IFMT == S_IFDIR,
              parent.st_uid == getuid(), parent.st_mode & 0o077 == 0 else {
            throw NativeInteractionError("invalid_socket", "Automation socket requires an existing private directory (0700)")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var bound = false
        do {
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw POSIXError(.EIO) }
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            bound = true
            guard chmod(path, 0o600) == 0, listen(fd, 8) == 0 else { throw POSIXError(.EIO) }
            var info = stat()
            guard lstat(path, &info) == 0 else { throw POSIXError(.EIO) }
            socketIdentity = (info.st_dev, info.st_ino)
        } catch {
            Darwin.close(fd)
            if bound { unlink(path) }
            throw error
        }
        listener = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        timer = DispatchSource.makeTimerSource(queue: .main)
        listener.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.acceptClients(fd) } }
        listener.setCancelHandler { Darwin.close(fd) }
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated {
            guard let self else { return }
            for client in self.clients.values where Date().timeIntervalSince(client.lastActivity) > 30 { self.close(client.fd) }
        } }
        listener.resume(); timer.resume()
    }

    func stop() {
        guard !stopped else { return }; stopped = true
        timer.cancel(); listener.cancel()
        for fd in Array(clients.keys) { close(fd) }
        var info = stat()
        if lstat(path, &info) == 0, info.st_dev == socketIdentity.0, info.st_ino == socketIdentity.1 { unlink(path) }
    }

    private func acceptClients(_ fd: Int32) {
        guard !stopped else { return }
        for _ in 0..<8 {
            let clientFD = accept(fd, nil, nil)
            guard clientFD >= 0 else { return }
            var uid: uid_t = 0, gid: gid_t = 0
            var noSignal: Int32 = 1
            guard clients.count < 8, getpeereid(clientFD, &uid, &gid) == 0, uid == getuid(),
                  fcntl(clientFD, F_SETFL, O_NONBLOCK) == 0, fcntl(clientFD, F_SETFD, FD_CLOEXEC) == 0,
                  setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                Darwin.close(clientFD); continue
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: .main)
            clients[clientFD] = Client(fd: clientFD, reader: source)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.read(clientFD) } }
            source.setCancelHandler { Darwin.close(clientFD) }
            source.resume()
        }
    }

    private func close(_ fd: Int32) {
        guard let client = clients.removeValue(forKey: fd) else { return }
        client.writer?.cancel(); client.reader.cancel()
    }

    private func read(_ fd: Int32) {
        guard let client = clients[fd] else { return }
        var bytes = [UInt8](repeating: 0, count: 8192)
        let count = Darwin.read(fd, &bytes, bytes.count)
        if count == 0 { close(fd); return }
        guard count > 0 else {
            if errno != EAGAIN && errno != EINTR { close(fd) }; return
        }
        client.lastActivity = Date()
        client.input.append(contentsOf: bytes.prefix(count))
        drain(client)
    }

    private func drain(_ client: Client) {
        guard clients[client.fd] === client else { return }
        // Yield between batches so pipelined monkeys still exercise SwiftUI.
        for _ in 0..<16 {
            guard let end = client.input.firstIndex(of: 10) else {
                if client.input.count > Self.maximumFrame { close(client.fd) }
                return
            }
            let frame = Data(client.input[..<end])
            client.input.removeSubrange(...end)
            guard frame.count <= Self.maximumFrame else { close(client.fd); return }
            var response = respond(frame)
            response.append(10)
            guard client.output.count + response.count <= Self.maximumOutput else { close(client.fd); return }
            client.output.append(response)
            flush(client)
            guard clients[client.fd] === client else { return }
        }
        if !client.input.isEmpty {
            DispatchQueue.main.async { [weak self, weak client] in
                guard let client else { return }; self?.drain(client)
            }
        }
    }

    private func flush(_ client: Client) {
        while !client.output.isEmpty {
            let count = client.output.withUnsafeBytes { Darwin.write(client.fd, $0.baseAddress, $0.count) }
            guard count > 0 else {
                if errno == EINTR { continue }
                guard errno == EAGAIN else { close(client.fd); return }
                if client.writer == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: client.fd, queue: .main)
                    client.writer = source
                    source.setEventHandler { [weak self, weak client] in MainActor.assumeIsolated {
                        guard let self, let client, self.clients[client.fd] === client else { return }
                        self.flush(client)
                    } }
                    source.resume()
                }
                return
            }
            client.output.removeFirst(count)
        }
        client.writer?.cancel(); client.writer = nil
    }

    private func respond(_ data: Data) -> Data {
        var id = JSONValue.null
        var failure: NativeInteractionError?
        let current = presentation()
        do {
            let request = try JSONValue.parse(data: data, maxDepth: 16)
            guard case .string(let requestID) = request["id"], !requestID.codeUnits.isEmpty, requestID.codeUnits.count <= 128 else {
                throw NativeInteractionError("invalid_request", "Request requires a string id (1–128 UTF-16 units)")
            }
            id = .string(requestID)
            let fields = Set(request.objectValue?.keys.map { $0 } ?? [])
            guard request["protocol"] == .integer(1) else { throw NativeInteractionError("invalid_request", "Expected protocol 1") }
            switch request["op"] {
            case .text("snapshot"):
                guard fields == ["protocol", "id", "op"] else { throw NativeInteractionError("invalid_request", "Unexpected snapshot fields") }
            case .text("perform"):
                guard fields == ["protocol", "id", "op", "action"], let action = request["action"] else {
                    throw NativeInteractionError("invalid_request", "Perform requires an action")
                }
                let intent = try NativeWorkspaceAction(json: action)
                guard let current else { throw NativeInteractionError("unavailable", "Workspace is loading or reloading") }
                try current.performInteraction(intent)
            default: throw NativeInteractionError("invalid_request", "Unknown operation")
            }
        } catch let error as NativeInteractionError { failure = error }
        catch { failure = NativeInteractionError("invalid_request", "Malformed JSON request") }
        sequence += 1
        let reply = JSONValue.object([
            "protocol": .integer(1), "id": id, "session": .text(session), "sequence": .integer(sequence),
            "pid": .integer(ProcessInfo.processInfo.processIdentifier), "ok": .bool(failure == nil),
            "error": failure?.json ?? .null, "snapshot": current?.interactionSnapshot() ?? .null
        ])
        return (try? reply.encodedData()) ?? Data("{\"ok\":false,\"error\":{\"code\":\"encoding_failed\"}}".utf8)
    }
}
