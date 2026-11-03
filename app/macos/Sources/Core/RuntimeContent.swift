import Foundation

struct ContentResource {
    let instanceID = UUID()
    let threadID: JSONText
    let scope: RuntimeContentScope
    var wireID: String?
    var acknowledged = false
    var retentionID: UUID?
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
    /// Handles remain independently owned. A released, current subscription can
    /// stay live briefly for another reader; no view/navigation state is retained.
    @discardableResult
    public func subscribeThreadContent(threadId: JSONText, scope: RuntimeContentScope,
                                       subscriptionId: String = UUID().uuidString.lowercased(),
                                       performanceContext: UInt64? = nil) async throws -> String {
        try assertOpen(); try Task.checkCancellation()
        try validateIdentity(threadId); try validateIdentity(JSONText(subscriptionId))
        switch scope {
        case .turn(let key), .execution(let key): try validateIdentity(key)
        case .thread: break
        }
        let previous = takeIdleContent(subscriptionId) ?? contentResources.removeValue(forKey: subscriptionId)
        previous?.timer?.cancel()
        previous?.measurement?.end(.cancelled)
        // Reuse only a continuously subscribed snapshot from this stream. Never
        // treat persisted reading bytes as a fresh connected response.
        if let id = idleContent.last(where: {
            guard let cached = contentResources[$0] else { return false }
            return status == .connected && cached.threadID == threadId && cached.scope == scope &&
                cached.revision != nil && cached.acknowledged && cached.wireID != nil && !cached.isRecovering
        }), var cached = takeIdleContent(id) {
            cached.retentionID = nil
            cached.performanceContext = performanceContext
            contentResources[subscriptionId] = cached
            emit(.threadContent(subscriptionId: subscriptionId, state: cached.value.map(RuntimeContentState.ready) ?? .loading))
            if let wire = previous?.wireID { await releaseWireContent(wire) }
            return subscriptionId
        }
        // Foreground demand takes priority over speculative/idle demand.
        if contentResources.count >= 28 { await evictIdleContent() }
        try assertOpen(); try Task.checkCancellation()
        guard contentResources.count < 32 else { throw RuntimeError("CONTENT_CAPACITY", "Too many open content subscriptions") }
        var resource = ContentResource(threadID: threadId, scope: scope)
        if clientID == nil { resource.value = offlineStore.content(thread: threadId, scope: scope) }
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
        guard var resource = contentResources[subscriptionId] else { return }
        if status == .connected, resource.revision != nil, resource.wireID != nil, resource.acknowledged,
           resource.failure == nil, !resource.isRecovering, let value = resource.value {
            // Only a ready resource moves between owners: its acknowledgement
            // and timeout have finished, so neither can revoke a later owner.
            let duplicate = idleContent.first {
                $0 != subscriptionId && contentResources[$0]?.threadID == resource.threadID && contentResources[$0]?.scope == resource.scope
            }
            let replaced = duplicate.flatMap { takeIdleContent($0) }
            // Retire the consumer ID synchronously. Cache ownership has a
            // separate identity, so an old retry/release cannot affect reuse.
            let retainedID = UUID().uuidString.lowercased()
            let retention = UUID()
            resource.retentionID = retention
            contentResources.removeValue(forKey: subscriptionId)
            contentResources[retainedID] = resource
            idleContent.append(retainedID)
            idleContentCosts[retainedID] = value.readingRetentionCost
            idleContentExpiry[retainedID] = Task {
                do {
                    try await Task.sleep(for: .seconds(30))
                    try Task.checkCancellation()
                    guard self.contentResources[retainedID]?.retentionID == retention else { return }
                    await self.evictIdleContent(retainedID)
                } catch { }
            }
            await trimIdleContent()
            if let wire = replaced?.wireID { await releaseWireContent(wire) }
            return
        }
        contentResources.removeValue(forKey: subscriptionId)
        resource.timer?.cancel()
        resource.measurement?.end(.cancelled)
        if let wireID = resource.wireID { await releaseWireContent(wireID) }
    }

    public func clearThreadContentSubscriptions() async {
        flushReadingCache()
        let released = Array(contentResources.values)
        for task in idleContentExpiry.values { task.cancel() }
        idleContent.removeAll(); idleContentCosts.removeAll(); idleContentExpiry.removeAll()
        contentResources.removeAll()
        for resource in released { resource.timer?.cancel(); resource.measurement?.end(.cancelled) }
        for resource in released { if let wire = resource.wireID { await releaseWireContent(wire) } }
    }

    public func retryThreadContent(_ subscriptionId: String) async throws {
        try assertOpen()
        guard contentResources[subscriptionId] != nil, idleContentCosts[subscriptionId] == nil else { throw RuntimeError("CONTENT_UNAVAILABLE", "Content surface has been released") }
        contentResources[subscriptionId]?.recoveries = 0
        try await beginContent(subscriptionId)
    }

    func beginContent(_ id: String) async throws {
        if idleContentCosts[id] != nil { await evictIdleContent(id); return }
        guard var resource = contentResources[id], clientID != nil else { return }
        resource.timer?.cancel()
        let oldWire = resource.wireID
        if oldWire != nil || resource.measurement == nil {
            resource.measurement?.end(.cancelled)
            resource.measurement = NativePerformance.begin(.contentReady, context: resource.performanceContext,
                values: ["row": { if case .thread = resource.scope { return 0.0 }; return 1.0 }()])
        }
        let wire = UUID().uuidString.lowercased()
        // A new stream/retry must deliver a fresh snapshot before connected
        // reading resumes; retained bytes are only an offline fallback.
        resource.wireID = wire; resource.revision = nil; resource.failure = nil; resource.acknowledged = false
        resource.value = nil
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
            if contentResources[id]?.wireID == wire { contentResources[id]?.acknowledged = true }
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
            // Revoke freshness before a wire-release await can admit another
            // reader or let a departing reader repopulate the idle cache.
            for id in contentResources.keys {
                contentResources[id]?.revision = nil
                contentResources[id]?.acknowledged = false
            }
            await evictIdleContent()
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
            if idleContentCosts[id] == nil { emit(.threadContent(subscriptionId: id, state: .ready(value))) }
            if idleContentCosts[id] != nil {
                idleContentCosts[id] = value.readingRetentionCost
                await trimIdleContent()
            }
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
                if idleContentCosts[id] == nil { emit(.threadContent(subscriptionId: id, state: .ready(result))) }
                if idleContentCosts[id] != nil {
                    idleContentCosts[id] = result.readingRetentionCost
                    await trimIdleContent()
                }
            } catch { await recoverContent(id) }
        default: throw RuntimeError("INVALID_EVENT", "Runtime sent an unknown content event")
        }
    }
    private func recoverContent(_ id: String) async {
        if idleContentCosts[id] != nil { await evictIdleContent(id); return }
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
        if idleContentCosts[id] != nil { await evictIdleContent(id); return }
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
    func releaseWireContent(_ wire: String) async {
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
