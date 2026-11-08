import Foundation

extension RuntimeClient {
    /// Read ahead without mounting a reader. Cancellation releases only this
    /// speculative handle; a foreground reader always owns a separate handle.
    public func prefetchThreadContent(threadId: JSONText, scope: RuntimeContentScope,
                                      performanceContext: UInt64? = nil) async {
        guard !Task.isCancelled, status == .connected else { return }
        if contentResources.values.contains(where: { $0.threadID == threadId && $0.scope == scope }) { return }
        let id = UUID().uuidString.lowercased()
        await withTaskCancellationHandler {
            let stream = events()
            do {
                try Task.checkCancellation()
                try await subscribeThreadContent(threadId: threadId, scope: scope, subscriptionId: id,
                    performanceContext: performanceContext)
                for await event in stream {
                    try Task.checkCancellation()
                    if case .threadContent(let received, let state) = event, received == id {
                        if case .loading = state { continue }
                        break
                    }
                }
            } catch { }
            if Task.isCancelled { await discardPrefetch(id) }
            else { await releaseThreadContent(id) }
        } onCancel: {
            Task { await self.discardPrefetch(id) }
        }
    }

    private func discardPrefetch(_ id: String) async {
        // Removal precedes the wire await. A late acknowledgement sees the
        // missing owner and releases its accepted add through beginContent.
        guard let resource = takeIdleContent(id) ?? contentResources.removeValue(forKey: id) else { return }
        resource.timer?.cancel(); resource.measurement?.end(.cancelled)
        if let wire = resource.wireID { await releaseWireContent(wire) }
    }

    func takeIdleContent(_ id: String) -> ContentResource? {
        guard idleContentCosts[id] != nil else { return nil }
        // An idle patch may still be inside the disk-cache debounce. Persist
        // it before retiring its local id, just as a visible release does.
        if readingContentDirty.contains(id) { flushReadingCache() }
        idleContentCosts.removeValue(forKey: id)
        idleContent.removeAll { $0 == id }
        idleContentExpiry.removeValue(forKey: id)?.cancel()
        readingContentDirty.remove(id)
        return contentResources.removeValue(forKey: id)
    }

    func trimIdleContent() async {
        var retired: [ContentResource] = []
        // Restore the local budget before yielding to any wire release.
        while idleContent.count > 4 || idleContentCosts.values.reduce(0, +) > 8 * 1024 * 1024 {
            guard let oldest = idleContent.first, let resource = takeIdleContent(oldest) else { break }
            retired.append(resource)
        }
        for resource in retired {
            if let wire = resource.wireID { await releaseWireContent(wire) }
        }
    }

    func evictIdleContent(_ id: String? = nil) async {
        let ids = id.map { [$0] } ?? idleContent
        // Remove the whole eviction set before yielding to transport. A new
        // owner cannot claim one of these wires during another release await.
        let retired = ids.compactMap { takeIdleContent($0) }
        for resource in retired {
            if let wire = resource.wireID { await releaseWireContent(wire) }
        }
    }
}

extension JSONValue {
    /// Conservative accounting units for retained JSON, including container and
    /// UTF-16 storage overhead; this is a cache budget, not process RSS.
    public var readingRetentionCost: Int {
        switch self {
        case .null, .bool, .number: 32
        case .integer(let integer): 32 + integer.literal.utf8.count
        case .string(let text): 32 + text.codeUnits.count * 2
        case .array(let values): 64 + values.reduce(0) { $0 + 32 + $1.readingRetentionCost }
        case .catalog(let values): 64 + values.reduce(0) { $0 + 32 + $1.readingRetentionCost }
        case .object(let values): 64 + values.reduce(0) { $0 + 64 + $1.key.codeUnits.count * 2 + $1.value.readingRetentionCost }
        }
    }
}
