import CryptoKit
import Darwin
import Dispatch
import Foundation
import CLiteRTLM

private struct Descriptor: Encodable {
    let space = Model.space
    let name = "EmbeddingGemma 2 Text 270M · INT4"
    let dimensions = Model.dimensions
    // A conservative passage budget, independent of the model's 8,192-token
    // context window. The engine remains authoritative for token overflow.
    let documentBytes = 1536
}

private struct Event: Encodable {
    var id: Int?
    var event: String
    var descriptor: Descriptor?
    var phase: String?
    var completedBytes: Int64?
    var totalBytes: Int64?
    var vectors: [[Float]]?
    var error: String?
}

private final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    init() {
        // Native library diagnostics must never become protocol messages.
        handle = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
        dup2(STDERR_FILENO, STDOUT_FILENO)
    }
    func send(_ event: Event) {
        lock.lock()
        defer { lock.unlock() }
        do {
            var data = try JSONEncoder().encode(event)
            data.append(10)
            try handle.write(contentsOf: data)
        } catch { exit(74) }
    }
}

// URLSession serializes delegate calls on this queue. The continuation is
// installed before resume and consumed exactly once by didCompleteWithError.
private final class Download: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let output: Output
    var continuation: CheckedContinuation<URL, any Error>?
    var result: Result<URL, any Error>?
    var lastProgress = Date.distantPast
    init(destination: URL, output: Output) { self.destination = destination; self.output = output }
    func run(_ url: URL) async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > Model.bytes { downloadTask.cancel(); return }
        guard Date().timeIntervalSince(lastProgress) >= 0.25 else { return }
        lastProgress = Date()
        output.send(Event(event: "status", phase: "downloading", completedBytes: totalBytesWritten,
                          totalBytes: Model.bytes))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        result = Result {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
                throw Failure.download
            }
            try FileManager.default.moveItem(at: location, to: destination)
            return destination
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let completion = continuation
        continuation = nil
        completion?.resume(with: error.map { .failure($0) } ?? result ?? .failure(Failure.download))
    }
}

private enum Failure: Error {
    case download, checksum, input, embedding
    var code: String {
        switch self {
        case .download: "download-failed"
        case .checksum: "model-checksum"
        case .input: "invalid-input"
        case .embedding: "invalid-vector"
        }
    }
}

private enum Model {
    static let dimensions = 768
    static let maxInputTokens = 8192
    static let queryPrefix = "task: search query | text: "
    static let documentPrefix = "task: search result | text: "
    static let bytes: Int64 = 164_626_432
    static let sha256 = "2d079ee2f6f066b1f368e8d7c819f55214eaef1d0513b312321901f30ab286fb"
    // Derive compatibility from the actual model protocol: changing weights,
    // prompts or dimensions cannot accidentally keep the previous vector space.
    static let space: String = {
        let identity = [sha256, "litert-lm-0.19.1", "trim-v1", queryPrefix, documentPrefix,
                        String(dimensions), "l2", "special-tokens-default"].joined(separator: "\u{0}")
        return "embeddinggemma-2-text-270m:" + SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }()
    static let url = URL(string: "https://huggingface.co/litert-community/embeddinggemma-2-text-270m-litert-lm/resolve/8c9f652b5233a80313d5c848f3656e492cf0397f/embeddinggemma-2-text-270m.litertlm")!
    static func verified(_ url: URL) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == bytes else { return false }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256()
        while let data = try file.read(upToCount: 1 << 20), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined() == sha256
    }
    static func prepare(directory: URL, output: Output) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        // This directory belongs to one leased Runtime profile. Interrupted
        // helpers can leave only their UUID-named staging files here.
        for entry in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where entry.pathExtension == "partial" && UUID(uuidString: entry.deletingPathExtension().lastPathComponent) != nil {
            try FileManager.default.removeItem(at: entry)
        }
        let model = directory.appendingPathComponent(sha256 + ".litertlm")
        output.send(Event(event: "status", phase: "verifying"))
        if FileManager.default.fileExists(atPath: model.path), try verified(model) { return model }
        let staging = directory.appendingPathComponent(UUID().uuidString + ".partial")
        defer { try? FileManager.default.removeItem(at: staging) }
        output.send(Event(event: "status", phase: "downloading", completedBytes: 0, totalBytes: bytes))
        _ = try await Download(destination: staging, output: output).run(url)
        output.send(Event(event: "status", phase: "verifying", completedBytes: bytes, totalBytes: bytes))
        guard try verified(staging) else { throw Failure.checksum }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
        let file = try FileHandle(forWritingTo: staging)
        try file.synchronize()
        try file.close()
        guard rename(staging.path, model.path) == 0 else { throw Failure.download }
        return model
    }
}

private struct Request: Decodable {
    let id: Int
    let operation: String
    let kind: String?
    let texts: [String]?
}

@main
struct EmbeddingMain {
    static func main() async {
        let output = Output()
        let descriptor = Descriptor()
        output.send(Event(event: "hello", descriptor: descriptor))
        if CommandLine.arguments.dropFirst() == ["--describe"] { return }
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--model-directory",
              CommandLine.arguments[2].hasPrefix("/") else { exit(64) }
        let parent = getppid()
        guard parent > 1 else { return }
        // A killed Runtime cannot cancel a synchronous C call. Observe its OS
        // lifetime independently so native inference cannot become an orphan.
        let parentExit = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .global(qos: .utility))
        parentExit.setEventHandler { _exit(0) }
        parentExit.resume()
        defer { parentExit.cancel() }
        guard getppid() == parent else { return }
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        var path: URL?
        var engine: LiteRTEmbedding?
        while let line = readLine() {
            guard line.utf8.count <= 262_144, let data = line.data(using: .utf8),
                  let request = try? JSONDecoder().decode(Request.self, from: data) else { exit(65) }
            var failure = "embedding-failed"
            do {
                switch request.operation {
                case "prepare":
                    failure = "download-failed"
                    path = try await Model.prepare(directory: directory, output: output)
                    output.send(Event(event: "status", phase: "idle"))
                    output.send(Event(id: request.id, event: "result"))
                case "embed":
                    guard let path, let texts = request.texts, !texts.isEmpty, texts.count <= 4,
                          let kind = request.kind, kind == "query" || kind == "document",
                          texts.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                              $0.utf8.count <= (kind == "query" ? 4096 : descriptor.documentBytes) }) else {
                        throw Failure.input
                    }
                    if engine == nil {
                        failure = "model-load-failed"
                        output.send(Event(event: "status", phase: "loading"))
                        let next = try LiteRTEmbedding(path: path.path, cache: directory.path,
                            dimensions: Model.dimensions, maxInputTokens: Model.maxInputTokens)
                        engine = next
                    }
                    failure = "embedding-failed"
                    output.send(Event(event: "status", phase: "ready"))
                    let prefix = kind == "query" ? Model.queryPrefix : Model.documentPrefix
                    var vectors: [[Float]] = []
                    for text in texts {
                        let vector = try engine!.compute(prefix + text.trimmingCharacters(in: .whitespacesAndNewlines))
                        let norm = vector.reduce(Float.zero) { $0 + $1 * $1 }
                        guard vector.count == descriptor.dimensions, vector.allSatisfy(\.isFinite),
                              abs(norm - 1) < 0.01 else { throw Failure.embedding }
                        vectors.append(vector)
                    }
                    output.send(Event(id: request.id, event: "result", vectors: vectors))
                case "close":
                    engine?.close()
                    output.send(Event(id: request.id, event: "result"))
                    return
                default: throw Failure.input
                }
            } catch {
                output.send(Event(id: request.id, event: "result", error: (error as? Failure)?.code ?? failure))
            }
        }
        engine?.close()
    }
}
