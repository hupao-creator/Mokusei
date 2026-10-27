import Foundation

struct ContentResource {
    let instanceID = UUID()
    let threadID: JSONText
    let scope: RuntimeContentScope
    var wireID: String?
    var value: JSONValue?
    var revision: Int?
    var failure: String?
    var recoveries = 0
    var isRecovering = false
    var timer: Task<Void, Never>?
    var performanceContext: UInt64?
    var measurement: NativePerformanceSpan?
}

extension RuntimeClient {
    /// A visible surface owns one handle. Releasing it drops local bytes and server demand.
    @discardableResult
    public func subscribeThreadContent(threadId: JSONText, scope: RuntimeContentScope,
                                       subscriptionId: String = UUID().uuidString.lowercased(),
                                       performanceContext: UInt64? = nil) async throws -> String {
        try assertOpen()
        try validateIdentity(threadId); try validateIdentity(JSONText(subscriptionId))
        switch scope {
        case .turn(let key), .execution(let key): try validateIdentity(key)
        case .thread: break
        }
        let previous = contentResources.removeValue(forKey: subscriptionId)
        previous?.timer?.cancel()
        previous?.measurement?.end(.cancelled)
        guard contentResources.count < 32 else { throw RuntimeError("CONTENT_CAPACITY", "Too many open content subscriptions") }
        var resource = ContentResource(threadID: threadId, scope: scope)
        resource.value = offlineStore.content(thread: threadId, scope: scope)
        resource.performanceContext = performanceContext
        resource.measurement = NativePerformance.begin(.contentReady, context: performanceContext,
            values: ["row": { if case .thread = scope { return 0.0 }; return 1.0 }()])
        contentResources[subscriptionId] = resource
        emit(.threadContent(subscriptionId: subscriptionId, state: resource.value.map(RuntimeContentState.ready) ?? .loading))
        if let wire = previous?.wireID { await releaseWireContent(wire) }
        try assertOpen()
        guard contentResources[subscriptionId]?.instanceID == resource.instanceID else { throw CancellationError() }
        if clientID != nil { try await beginContent(subscriptionId) }
        try assertOpen()
        guard contentResources[subscriptionId]?.instanceID == resource.instanceID else { throw CancellationError() }
        return subscriptionId
    }

    public func releaseThreadContent(_ subscriptionId: String) async {
        flushReadingCache()
        guard let resource = contentResources.removeValue(forKey: subscriptionId) else { return }
        resource.timer?.cancel()
        resource.measurement?.end(.cancelled)
        if let wireID = resource.wireID { await releaseWireContent(wireID) }
    }

    public func clearThreadContentSubscriptions() async {
        flushReadingCache()
        let released = Array(contentResources.values)
        contentResources.removeAll()
        for resource in released { resource.timer?.cancel(); resource.measurement?.end(.cancelled) }
        for resource in released { if let wire = resource.wireID { await releaseWireContent(wire) } }
    }

    public func retryThreadContent(_ subscriptionId: String) async throws {
        try assertOpen()
        guard contentResources[subscriptionId] != nil else { throw RuntimeError("CONTENT_UNAVAILABLE", "Content surface has been released") }
        contentResources[subscriptionId]?.recoveries = 0
        try await beginContent(subscriptionId)
    }

    func beginContent(_ id: String) async throws {
        guard var resource = contentResources[id], clientID != nil else { return }
        resource.timer?.cancel()
        let oldWire = resource.wireID
        if oldWire != nil || resource.measurement == nil {
            resource.measurement?.end(.cancelled)
            resource.measurement = NativePerformance.begin(.contentReady, context: resource.performanceContext,
                values: ["row": { if case .thread = resource.scope { return 0.0 }; return 1.0 }()])
        }
        let wire = UUID().uuidString.lowercased()
        // Keep the last reading bytes while refreshing, but revoke their wire
        // revision so no new patch can apply until a fresh snapshot arrives.
        resource.wireID = wire; resource.revision = nil; resource.failure = nil
        resource.isRecovering = false
        resource.timer = Task {
            do {
                try await Task.sleep(for: .seconds(30))
                if self.contentResources[id]?.wireID == wire {
                    await self.failContent(id, message: "Reading thread content timed out")
                }
            } catch { }
        }
        contentResources[id] = resource
        emit(.threadContent(subscriptionId: id, state: resource.value.map(RuntimeContentState.ready) ?? .loading))
        if let oldWire { await releaseWireContent(oldWire) }
        guard contentResources[id]?.wireID == wire else { return }
        let acknowledgement = NativePerformance.begin(.contentAck, context: resource.measurement?.id)
        do {
            _ = try await sessionPost("/thread-content/subscription", fields: [
                "subscriptionId": .text(wire), "target": runtimeObject(["threadId": .string(resource.threadID), "scope": resource.scope.json])
            ])
            acknowledgement?.end()
            // A close/replacement can beat acknowledgement; revoke the accepted add again.
            if contentResources[id]?.wireID != wire { await releaseWireContent(wire) }
        } catch {
            acknowledgement?.end(error is CancellationError ? .cancelled : .failed)
            if error is CancellationError { resource.measurement?.end(.cancelled) }
            if contentResources[id]?.wireID == wire { await failContent(id, message: error.localizedDescription) }
            throw error
        }
    }

    func receiveContent(_ event: JSONValue) async throws {
        guard let type = event["type"]?.stringValue else { throw RuntimeError("INVALID_EVENT", "Content event has no type") }
        if type == "reset" {
            for id in Array(contentResources.keys) {
                contentResources[id]?.recoveries = 0
                Task { try? await self.beginContent(id) }
            }
            return
        }
        guard let wire = event["subscriptionId"]?.stringValue else { throw RuntimeError("INVALID_EVENT", "Content event has no identity") }
        guard let id = contentResources.first(where: { $0.value.wireID == wire })?.key,
              var resource = contentResources[id] else { return }
        switch type {
        case "error":
            guard let message = event["message"]?.stringValue else { throw RuntimeError("INVALID_EVENT", "Content error has no message") }
            await failContent(id, message: message)
        case "snapshot":
            guard let revision = event["revision"]?.intValue, (0...RuntimeProtocol.maximumSafeInteger).contains(revision), let value = event["value"] else {
                await recoverContent(id); return
            }
            resource.timer?.cancel(); resource.timer = nil
            resource.measurement?.end(); resource.measurement = nil
            resource.value = value; resource.revision = revision; resource.failure = nil
            contentResources[id] = resource
            readingContentDirty.insert(id); scheduleReadingCache()
            emit(.threadContent(subscriptionId: id, state: .ready(value)))
        case "patch":
            guard let value = resource.value, let current = resource.revision,
                  let revision = event["revision"]?.intValue, event["baseRevision"]?.intValue == current,
                  revision > current, revision <= RuntimeProtocol.maximumSafeInteger, let patch = event["patch"] else { await recoverContent(id); return }
            do {
                let measurement = NativePerformance.begin(.contentPatch, context: resource.performanceContext)
                defer { measurement?.end(.failed) }
                let result = try JSONDelta.apply(patch, to: value)
                measurement?.end()
                resource.value = result; resource.revision = revision; resource.recoveries = 0; resource.failure = nil
                contentResources[id] = resource
                readingContentDirty.insert(id); scheduleReadingCache()
                emit(.threadContent(subscriptionId: id, state: .ready(result)))
            } catch { await recoverContent(id) }
        default: throw RuntimeError("INVALID_EVENT", "Runtime sent an unknown content event")
        }
    }
    private func recoverContent(_ id: String) async {
        guard contentResources[id] != nil, contentResources[id]?.isRecovering == false else { return }
        contentResources[id]?.isRecovering = true
        contentResources[id]?.recoveries += 1
        if contentResources[id]!.recoveries > 3 { await failContent(id, message: "Thread content revisions are inconsistent; retry this surface") }
        else {
            // Do not block the event reader on hydration requests: snapshots share this stream.
            let wire = contentResources[id]?.wireID
            Task {
                guard self.contentResources[id]?.wireID == wire else { return }
                try? await self.beginContent(id)
            }
        }
    }
    private func failContent(_ id: String, message: String) async {
        guard var resource = contentResources[id] else { return }
        resource.measurement?.end(.failed); resource.measurement = nil
        let wire = resource.wireID
        resource.timer?.cancel(); resource.timer = nil; resource.wireID = nil
        resource.value = nil; resource.revision = nil; resource.failure = message
        resource.isRecovering = false
        contentResources[id] = resource
        emit(.threadContent(subscriptionId: id, state: .error(message)))
        if let wire { await releaseWireContent(wire) }
    }
    private func releaseWireContent(_ wire: String) async {
        let previousStream = streamID
        do {
            _ = try await sessionPost("/thread-content/subscription", fields: ["subscriptionId": .text(wire), "target": .null])
        } catch {
            // Never silently lose a release (including a full write queue).
            // Closing the owning stream releases every server-side resource;
            // the next stream replays only demand that still has a local owner.
            if let previousStream, streamID == previousStream {
                let reason = (error as? RuntimeError).map { "\($0.code): \($0.message)" } ?? error.localizedDescription
                invalidateSession(RuntimeError("CONTENT_RELEASE_FAILED", "Thread content release failed; resetting its owning subscription (\(reason))"), stream: previousStream)
            }
        }
    }
    private func validateIdentity(_ value: JSONText) throws {
        // The wire contract uses ECMAScript trim and UTF-16 length. Converting
        // an opaque row key to String would replace isolated surrogate units.
        let nonblank = value.codeUnits.contains { unit in
            switch unit {
            case 0x0009...0x000D, 0x0020, 0x00A0, 0x1680, 0x2000...0x200A,
                 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: false
            default: true
            }
        }
        guard nonblank, value.codeUnits.count <= 256 else {
            throw RuntimeError("INVALID_REQUEST", "Content identities must be nonempty and at most 256 UTF-16 units")
        }
    }

    /// Ephemeral session writes are serialized and never replayed onto another client identity.
    func sessionPost(_ endpoint: String, fields: [String: JSONValue]) async throws -> JSONValue {
        guard let owner = connection, let client = clientID, let stream = streamID else {
            throw RuntimeError("SESSION_UNAVAILABLE", "Runtime subscription is disconnected")
        }
        var body = fields; body["clientId"] = .text(client)
        let bytes = try runtimeObject(body).encodedData()
        guard bytes.count <= RuntimeProtocol.maxOverviewBytes else { throw RuntimeError("REQUEST_TOO_LARGE", "Session request exceeds the 2 MiB transport limit") }
        guard sessionRequests.count < 128, sessionRequestBytes <= RuntimeProtocol.maxResponseBytes - bytes.count else {
            throw RuntimeError("SESSION_QUEUE_FULL", "Pending presentation updates exceed the bounded session queue")
        }
        let previous = sessionWrites
        let expected = generation
        let operationID = UUID()
        let operation = Task { () throws -> JSONValue in
            defer {
                if self.sessionRequests.removeValue(forKey: operationID) != nil { self.sessionRequestBytes -= bytes.count }
            }
            await previous?.value
            try self.assertCurrent(stream, generation: expected)
            let value = try await self.transport.request(connection: owner, path: endpoint, method: "POST", body: bytes, timeout: 10)
            try self.assertCurrent(stream, generation: expected)
            return try runtimeResult(value)
        }
        sessionRequests[operationID] = operation; sessionRequestBytes += bytes.count
        sessionWrites = Task { _ = try? await operation.value }
        return try await operation.value
    }
}
