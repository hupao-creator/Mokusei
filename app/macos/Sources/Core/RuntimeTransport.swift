import Foundation

/// Authenticated loopback transport with no redirects, cookies, proxies or shared cache.
public struct RuntimeTransport: Sendable {
    public init() {}

    public func request(connection: RuntimeConnection, path: String, method: String = "GET", body: Data? = nil,
                        timeout: TimeInterval = 30) async throws -> JSONValue {
        let channel = try RuntimeHTTPChannel(connection: connection, path: path, method: method, body: body, timeout: timeout)
        return try await response(channel)
    }

    func response(_ channel: RuntimeHTTPChannel) async throws -> JSONValue {
        return try await withTaskCancellationHandler {
            defer { channel.cancel() }
            var response: HTTPURLResponse?
            var bytes = Data()
            for try await part in channel.parts {
                try Task.checkCancellation()
                switch part {
                case .response(let value): response = value
                case .bytes(let chunk):
                    channel.consumed(chunk.count)
                    guard bytes.count <= RuntimeProtocol.maxResponseBytes - chunk.count else {
                        throw RuntimeError("RESPONSE_TOO_LARGE", "Runtime response exceeds the 32 MiB limit")
                    }
                    bytes.append(chunk)
                }
            }
            guard let response else { throw RuntimeError("INVALID_RESPONSE", "Runtime did not return HTTP headers") }
            return try decodeResponse(bytes, response: response)
        } onCancel: { channel.cancel() }
    }

    /// Framing happens on bytes, so a UTF-8 scalar split across HTTP chunks remains intact.
    /// Both a frame and the producer queue have independent 32 MiB bounds.
    public func events(connection: RuntimeConnection,
                       receive: @escaping @Sendable (JSONValue) async throws -> Void) async throws {
        let channel = try RuntimeHTTPChannel(connection: connection, path: "/events", method: "GET", body: nil, timeout: 86400)
        try await withTaskCancellationHandler {
            defer { channel.cancel() }
            var response: HTTPURLResponse?
            var pending = Data()
            for try await part in channel.parts {
                try Task.checkCancellation()
                switch part {
                case .response(let value): response = value
                case .bytes(let chunk):
                    channel.consumed(chunk.count)
                    guard let response else { throw RuntimeError("INVALID_RESPONSE", "Runtime sent bytes before headers") }
                    if response.statusCode != 200 {
                        guard pending.count <= RuntimeProtocol.maxResponseBytes - chunk.count else {
                            throw RuntimeError("RESPONSE_TOO_LARGE", "Runtime error response exceeds the transport limit")
                        }
                        pending.append(chunk)
                        continue
                    }
                    var start = chunk.startIndex
                    while start < chunk.endIndex {
                        let end = chunk[start...].firstIndex(of: 10) ?? chunk.endIndex
                        let length = chunk.distance(from: start, to: end)
                        guard pending.count <= RuntimeProtocol.maxEventBytes - length else {
                            throw RuntimeError("EVENT_TOO_LARGE", "Runtime event exceeds the 32 MiB limit")
                        }
                        pending.append(contentsOf: chunk[start..<end])
                        if end != chunk.endIndex {
                            if !pending.isEmpty {
                                let event = try JSONValue.parse(data: pending)
                                pending.removeAll(keepingCapacity: false)
                                try await receive(event)
                            }
                            start = chunk.index(after: end)
                        } else { start = end }
                    }
                }
            }
            if let response, response.statusCode != 200 { _ = try decodeResponse(pending, response: response) }
            throw RuntimeError("STREAM_CLOSED", pending.isEmpty ? "Runtime event stream closed" : "Runtime event stream ended inside a frame")
        } onCancel: { channel.cancel() }
    }

    func decodeResponse(_ data: Data, response: HTTPURLResponse) throws -> JSONValue {
        let value: JSONValue
        do { value = try JSONValue.parse(data: data) }
        catch { throw RuntimeError("INVALID_RESPONSE", "Runtime returned invalid JSON") }
        guard response.statusCode == 200 else {
            throw RuntimeError(value["error"]?["code"]?.stringValue ?? "TRANSPORT_REJECTED",
                               value["error"]?["message"]?.stringValue ?? "Runtime rejected the request",
                               kind: .requestRejected)
        }
        return value
    }
}

enum RuntimeHTTPPart: Sendable { case response(HTTPURLResponse), bytes(Data) }

/// URLSession callbacks can outrun actor hydration. Bound the queue before copying more bytes.
final class RuntimeHTTPChannel: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let parts: AsyncThrowingStream<RuntimeHTTPPart, Error>
    private let continuation: AsyncThrowingStream<RuntimeHTTPPart, Error>.Continuation
    private let lock = NSLock()
    private var queuedBytes = 0
    private var finished = false
    private var session: URLSession?
    private var task: URLSessionTask?
    private let maximumResponseBytes: Int64
    init(connection: RuntimeConnection, path: String, method: String, body: Data?, timeout: TimeInterval,
         uploadFile: URL? = nil, headers: [String: String] = [:],
         maximumResponseBytes: Int64 = Int64(RuntimeProtocol.maxResponseBytes)) throws {
        let port = connection.port, token = connection.token, epoch = connection.epoch
        self.maximumResponseBytes = maximumResponseBytes
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        guard path.hasPrefix("/"), !path.contains("?"), !path.contains("#"), !path.contains("\r"), !path.contains("\n"),
              (1...65535).contains(port), let base = components.url,
              let url = URL(string: base.absoluteString + path),
              url.host == base.host, url.port == port,
              url.user == nil, url.password == nil else {
            throw RuntimeError("INVALID_REQUEST", "Runtime request must use its authenticated endpoint")
        }
        guard body == nil || body!.count <= RuntimeProtocol.maxRequestBytes else {
            throw RuntimeError("REQUEST_TOO_LARGE", "Runtime request exceeds the 144 MiB limit")
        }
        let stream = AsyncThrowingStream<RuntimeHTTPPart, Error>.makeStream(bufferingPolicy: .bufferingOldest(512))
        parts = stream.stream; continuation = stream.continuation
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.connectionProxyDictionary = [:]
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = method; request.httpBody = body
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.setValue(String(RuntimeProtocol.version), forHTTPHeaderField: "X-Mokusei-Protocol")
        request.setValue(epoch, forHTTPHeaderField: "X-Mokusei-Epoch")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        }
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        let task: URLSessionTask
        if let uploadFile { task = session.uploadTask(with: request, fromFile: uploadFile) }
        else { task = session.dataTask(with: request) }
        self.task = task
        task.resume()
    }

    func consumed(_ count: Int) { lock.withLock { queuedBytes = max(0, queuedBytes - count) } }
    func cancel() {
        let shouldFinish = lock.withLock { let was = finished; finished = true; return !was }
        task?.cancel(); session?.invalidateAndCancel()
        if shouldFinish { continuation.finish(throwing: CancellationError()) }
    }
    private func finish(_ error: Error?) {
        let shouldFinish = lock.withLock { let was = finished; finished = true; return !was }
        guard shouldFinish else { return }
        continuation.finish(throwing: error)
        session?.finishTasksAndInvalidate()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            finish(RuntimeError("INVALID_RESPONSE", "Runtime did not return HTTP")); completionHandler(.cancel); return
        }
        if response.expectedContentLength > maximumResponseBytes {
            finish(RuntimeError("RESPONSE_TOO_LARGE", "Runtime response exceeds the 32 MiB limit")); completionHandler(.cancel); return
        }
        continuation.yield(.response(http)); completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let accepted = lock.withLock {
            guard !finished, queuedBytes <= RuntimeProtocol.maxResponseBytes - data.count else { return false }
            queuedBytes += data.count; return true
        }
        guard accepted else {
            finish(RuntimeError("EVENT_BUFFER_OVERFLOW", "Runtime consumer exceeded the bounded transport queue")); dataTask.cancel(); return
        }
        if case .dropped = continuation.yield(.bytes(data)) {
            finish(RuntimeError("EVENT_BUFFER_OVERFLOW", "Runtime consumer exceeded the bounded transport queue")); dataTask.cancel()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { finish(error) }
}
