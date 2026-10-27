import Foundation
import CryptoKit

/// One client owns its subscriptions; only explicit start/retry can launch the shared service.
public actor RuntimeClient {
    public nonisolated let storageDirectory: URL
    let manager: any RuntimeConnectionSource
    let transport = RuntimeTransport()
    var connection: RuntimeConnection?
    var status: RuntimeConnectionStatus = .disconnected
    var closed = false
    var explicitlyStopped = false
    var generation = 0
    var streamID: UUID?
    var clientID: String?
    var streamTask: Task<Void, Never>?
    var reconnectTask: Task<Void, Never>?
    var handshakeTask: Task<Void, Never>?
    var starting: Task<Void, Error>?
    var ready: CheckedContinuation<Void, Error>?
    var observers: [UUID: AsyncStream<RuntimeClientEvent>.Continuation] = [:]
    var state: JSONValue?
    var stateAuthority = UUID()
    var hydration: Task<JSONValue, Error>?
    var hydrationID: UUID?
    var bufferedMutations: [JSONValue] = []
    var bufferedMutationBytes = 0
    var activeCommands: [String: Task<JSONValue, Error>] = [:]
    var activeSettingsReads = Set<String>()
    var waitingSettingsReads: [RuntimeSettingsReadWaiter] = []
    var unresolvedCommands: [String: String] = [:]
    var explicitReceipts: [String: String] = [:]
    var commandRecords: [String: RuntimeCommandRecord] = [:]
    var commandJournalFailure: RuntimeError?
    var offlineRestored = false
    var readingCacheTask: Task<Void, Never>?
    var receiptRecoveryTask: Task<Void, Never>?
    var readingStateDirty = false
    var readingContentDirty = Set<String>()
    var settingsDiagnosticsQueue: [JSONValue] = []
    var settingsDiagnosticsTask: Task<Void, Never>?
    var contentResources: [String: ContentResource] = [:]
    var overviewContext: JSONValue?
    var retiredContexts = Set<JSONText>()
    var overviewRequest: JSONValue?
    var sessionWrites: Task<Void, Never>?
    var sessionRequests: [UUID: Task<JSONValue, Error>] = [:]
    var sessionRequestBytes = 0

    public init(storageDirectory: URL, connectionSource: any RuntimeConnectionSource) {
        self.storageDirectory = storageDirectory
        manager = connectionSource
    }

    public init(profile: RuntimeProfile, launch: RuntimeLaunchConfiguration? = nil) {
        storageDirectory = profile.dataDirectory
        manager = RuntimeProcessManager(profile: profile, launch: launch)
    }

    public func events() -> AsyncStream<RuntimeClientEvent> {
        restoreOfflineState()
        let id = UUID()
        let pair = AsyncStream<RuntimeClientEvent>.makeStream(bufferingPolicy: .bufferingNewest(128))
        guard !closed else { pair.continuation.finish(); return pair.stream }
        observers[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        // Install the current catalog before restoring availability. In
        // particular, a settings draft must not resume against an obsolete
        // revision just because the observer missed a reconnect's snapshot.
        let isHydrating = hydration != nil
        if status != .connected { pair.continuation.yield(.connection(status)) }
        if isHydrating { pair.continuation.yield(.synchronizing(true)) }
        if let state { pair.continuation.yield(.snapshot(state, authority: stateAuthority)) }
        if status == .connected { pair.continuation.yield(.connection(status)) }
        if !isHydrating { pair.continuation.yield(.synchronizing(false)) }
        // A slow UI reattaches after bounded-queue overflow. Its existing
        // content handles survive that observer, so replay their authoritative
        // values too; otherwise a dropped final ready/error event stays loading
        // forever although the transport has already completed the request.
        for (subscriptionID, resource) in contentResources {
            let current: RuntimeContentState
            if let failure = resource.failure { current = .error(failure) }
            else if let value = resource.value { current = .ready(value) }
            else { current = .loading }
            pair.continuation.yield(.threadContent(subscriptionId: subscriptionID, state: current))
        }
        if let overviewRequest { pair.continuation.yield(.overviewFilter(overviewRequest)) }
        if let commandJournalFailure { pair.continuation.yield(.failure(commandJournalFailure)) }
        return pair.stream
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    func emit(_ event: RuntimeClientEvent) {
        for (id, continuation) in observers {
            if case .dropped = continuation.yield(event) {
                continuation.yield(.failure(RuntimeError("CONSUMER_OVERFLOW", "Client event consumer fell behind; subscribe again for the current snapshot")))
                continuation.finish(); observers.removeValue(forKey: id)
            }
        }
    }
    func setStatus(_ value: RuntimeConnectionStatus) {
        guard status != value else { return }; status = value; emit(.connection(value))
    }
    func assertOpen() throws { if closed { throw RuntimeError("CLIENT_CLOSED", "Runtime client is closed") } }
    public func connectionStatus() -> RuntimeConnectionStatus { status }
    public func snapshot() -> JSONValue? { restoreOfflineState(); return state }
    /// Read the value and its ownership identity together, without a possible
    /// hydration or reconnect between two separate actor calls.
    public func currentSnapshotEvent() -> RuntimeClientEvent? {
        restoreOfflineState()
        return state.map { .snapshot($0, authority: stateAuthority) }
    }
    public func uncertainReceipts() -> [String] {
        restoreOfflineState()
        return commandRecords.values.filter { $0.status != .accepted && $0.status != .rejected }.map(\.id).sorted()
    }

    public func start() async throws {
        try assertOpen()
        restoreOfflineState()
        if status == .connected { return }
        try await retryConnection()
    }
    public func retryConnection() async throws {
        try assertOpen()
        if let starting { return try await starting.value }
        generation += 1
        let expected = generation
        setStatus(.connecting)
        retireStream()
        reconnectTask?.cancel(); reconnectTask = nil
        connection = nil; explicitlyStopped = false
        let task = Task {
            do {
                try await self.startInitial(generation: expected)
                if self.generation == expected { self.starting = nil }
            } catch {
                if self.generation == expected {
                    self.starting = nil
                    if !self.closed && !self.explicitlyStopped {
                        self.setStatus(.disconnected)
                    }
                }
                throw error
            }
        }
        starting = task
        try await task.value
    }
    private func startInitial(generation expected: Int) async throws {
        setStatus(.connecting)
        let value = try await manager.start()
        try assertOpen()
        guard generation == expected else { throw CancellationError() }
        connection = value
        try await establish(value, generation: expected)
    }
    private func establish(_ connection: RuntimeConnection, generation expected: Int) async throws {
        setStatus(.connecting)
        retireStream()
        let id = UUID(); streamID = id
        try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            handshakeTask = Task {
                do { try await Task.sleep(for: .seconds(30)); self.failed(RuntimeError("TRANSPORT_TIMEOUT", "Runtime subscription handshake timed out"), stream: id, generation: expected) }
                catch { }
            }
            streamTask = Task {
                do {
                    try await transport.events(connection: connection) { [weak self] event in
                        guard let self else { throw CancellationError() }
                        try await self.receive(event, connection: connection, stream: id, generation: expected)
                    }
                } catch { self.failed(error, stream: id, generation: expected) }
            }
        }
    }
    func retireStream() {
        receiptRecoveryTask?.cancel(); receiptRecoveryTask = nil
        flushReadingCache()
        ready?.resume(throwing: CancellationError()); ready = nil
        handshakeTask?.cancel(); handshakeTask = nil
        streamTask?.cancel(); streamTask = nil
        streamID = nil; clientID = nil; overviewRequest = nil
        for request in sessionRequests.values { request.cancel() }
        sessionRequests.removeAll(); sessionRequestBytes = 0; sessionWrites = nil
        let wasHydrating = hydration != nil
        hydration?.cancel(); hydration = nil; hydrationID = nil
        if wasHydrating { emit(.synchronizing(false)) }
        bufferedMutations.removeAll(); bufferedMutationBytes = 0
        for id in contentResources.keys {
            contentResources[id]?.timer?.cancel()
            contentResources[id]?.wireID = nil
            contentResources[id]?.revision = nil
            contentResources[id]?.failure = nil
            contentResources[id]?.recoveries = 0
            contentResources[id]?.isRecovering = false
            if let value = contentResources[id]?.value { emit(.threadContent(subscriptionId: id, state: .ready(value))) }
            else { emit(.threadContent(subscriptionId: id, state: .loading)) }
        }
    }
    private func receive(_ event: JSONValue, connection owner: RuntimeConnection, stream id: UUID, generation expected: Int) async throws {
        try assertCurrent(id, generation: expected)
        guard event["epoch"]?.stringValue == owner.epoch else { throw RuntimeError("STALE_EPOCH", "Runtime event belongs to another service instance") }
        guard let type = event["type"]?.stringValue else { throw RuntimeError("INVALID_EVENT", "Runtime event has no type") }
        if type == "hello" {
            guard clientID == nil, event["protocolVersion"]?.intValue == RuntimeProtocol.version,
                  let client = event["clientId"]?.stringValue, !client.isEmpty else { throw RuntimeError("PROTOCOL_MISMATCH", "Invalid runtime subscription handshake") }
            clientID = client
            _ = try await loadState()
            try assertCurrent(id, generation: expected)
            try await publishOverviewContext(overviewContext)
            try assertCurrent(id, generation: expected)
            setStatus(.connected)
            handshakeTask?.cancel(); handshakeTask = nil
            ready?.resume(); ready = nil
            for resourceID in contentResources.keys {
                Task { try? await self.beginContent(resourceID) }
            }
            scheduleReceiptRecovery()
            return
        }
        guard clientID != nil else { throw RuntimeError("INVALID_EVENT", "Runtime sent events before its handshake") }
        switch type {
        case "mutation":
            guard let mutation = event["mutation"] else { throw RuntimeError("INVALID_EVENT", "Missing state mutation") }
            if hydration != nil {
                let bytes = try mutation.encodedData().count
                guard bufferedMutations.count < 2048, bufferedMutationBytes <= RuntimeProtocol.maxEventBytes - bytes else {
                    throw RuntimeError("HYDRATION_OVERFLOW", "Live state exceeded the bounded hydration buffer")
                }
                bufferedMutations.append(mutation); bufferedMutationBytes += bytes
            } else { try await acceptMutation(mutation) }
        case "thread-content":
            guard let payload = event["event"] else { throw RuntimeError("INVALID_EVENT", "Missing thread content event") }
            try await receiveContent(payload)
        case "overview-filter":
            guard let request = event["request"], request["clientId"]?.stringValue == clientID,
                  request["requestId"]?.stringValue != nil else { throw RuntimeError("INVALID_EVENT", "Overview request belongs to another subscription") }
            overviewRequest = request; emit(.overviewFilter(request))
        case "stopping":
            explicitlyStopped = true; setStatus(.stopped)
            retireStream(); scheduleReconnect(generation: expected)
        default: throw RuntimeError("INVALID_EVENT", "Runtime sent an unknown event")
        }
    }
    func assertCurrent(_ id: UUID, generation expected: Int) throws {
        try assertOpen(); try Task.checkCancellation()
        guard generation == expected, streamID == id else { throw RuntimeError("STALE_CONNECTION", "Runtime subscription changed") }
    }
    private func failed(_ error: Error, stream id: UUID, generation expected: Int) {
        guard generation == expected, streamID == id else { return }
        let wasReady = ready == nil
        ready?.resume(throwing: error); ready = nil
        if !closed && !explicitlyStopped { setStatus(.disconnected) }
        retireStream()
        guard !closed else { return }
        if !(error is CancellationError) { emit(.failure(error as? RuntimeError ?? RuntimeError("TRANSPORT_FAILED", error.localizedDescription))) }
        if wasReady && isRecoverableConnection(error) { scheduleReconnect(generation: expected) }
    }
    func invalidateSession(_ error: RuntimeError, stream id: UUID) {
        failed(error, stream: id, generation: generation)
    }
    private func isRecoverableConnection(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        guard let failure = error as? RuntimeError else { return true }
        return !["UNAUTHORIZED", "HOST_IDENTITY_CHANGED", "PROTOCOL_MISMATCH", "HOST_NOT_PAIRED", "KEYCHAIN_UNAVAILABLE", "INVALID_CREDENTIAL", "INVALID_IDENTITY"].contains(failure.code)
    }
    private func scheduleReconnect(generation expected: Int) {
        reconnectTask?.cancel()
        reconnectTask = Task { await self.reconnect(generation: expected) }
    }
    private func reconnect(generation expected: Int) async {
        var backoff = 250
        while !closed && generation == expected && !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(backoff))
                if !explicitlyStopped { setStatus(.connecting) }
                let next = try await manager.status()
                try Task.checkCancellation()
                guard generation == expected && !closed else { return }
                if let next, !explicitlyStopped || next.epoch != connection?.epoch {
                    connection = next; explicitlyStopped = false
                    try await establish(next, generation: expected)
                    return
                }
            } catch {
                if Task.isCancelled || closed || generation != expected { return }
                if let failure = error as? RuntimeError, !isRecoverableConnection(failure) {
                    setStatus(.disconnected); emit(.failure(failure)); return
                }
                if (error as? RuntimeError)?.code == "SERVICE_STOPPING" { explicitlyStopped = true; setStatus(.stopped) }
            }
            if !explicitlyStopped { setStatus(.disconnected) }
            backoff = min(10000, backoff * 2)
        }
    }

    public func loadState() async throws -> JSONValue {
        try assertOpen()
        if connection == nil { try await start() }
        let expected = generation; let epoch = connection?.epoch; let id = streamID
        let task: Task<JSONValue, Error>
        if let active = hydration {
            task = active
        } else {
            let token = UUID()
            task = Task { try await self.hydrateState(token: token, generation: expected, epoch: epoch, stream: id) }
            hydrationID = token; hydration = task
            emit(.synchronizing(true))
        }
        let snapshot = try await task.value
        // Every waiter crosses an actor suspension, including those coalesced
        // onto a completed operation. A retry can retire that operation before
        // this waiter resumes, even though its original commit was valid.
        try assertHydrationCurrent(generation: expected, epoch: epoch, stream: id)
        return snapshot
    }

    private func hydrateState(token: UUID, generation expected: Int, epoch: String?, stream id: UUID?) async throws -> JSONValue {
        defer {
            if hydrationID == token {
                hydration = nil; hydrationID = nil
                bufferedMutations.removeAll(); bufferedMutationBytes = 0
                emit(.synchronizing(false))
            }
        }
        do {
            // Keep the buffer in its single bounded store while refetching. Do not
            // call acceptMutation here: its gap recovery would await this same task.
            for attempt in 0...1 {
                let snapshot = try await invoke("state:load")
                try RuntimeState.validateSnapshot(snapshot)
                try assertHydrationCurrent(generation: expected, epoch: epoch, stream: id)
                guard let applied = try RuntimeState.replaying(bufferedMutations, over: snapshot) else {
                    if attempt == 0 { continue }
                    throw RuntimeError("REVISION_GAP", "Runtime snapshot could not close the buffered mutation gap")
                }
                let merged = applied.last?.state ?? snapshot
                // Install and drain without suspending. The shared task resolves only
                // after all waiters can observe this complete, current-epoch commit.
                state = merged
                readingStateDirty = true; scheduleReadingCache()
                stateAuthority = token
                bufferedMutations.removeAll(); bufferedMutationBytes = 0
                emit(.snapshot(snapshot, authority: stateAuthority))
                for entry in applied { emit(.mutation(entry.mutation, state: entry.state, authority: stateAuthority)) }
                return merged
            }
            throw RuntimeError("REVISION_GAP", "Runtime snapshot requires a new subscription")
        } catch {
            // Revoke transport availability before ending synchronization. A
            // settings draft can resume on the false event, so that event must
            // never precede the failed hydration's disconnect notification.
            if hydrationID == token, generation == expected, !closed {
                if let id, streamID == id { failed(error, stream: id, generation: expected) }
                else {
                    setStatus(.disconnected)
                    emit(.failure(error as? RuntimeError ?? RuntimeError("SNAPSHOT_FAILED", error.localizedDescription)))
                }
            }
            throw error
        }
    }

    private func assertHydrationCurrent(generation expected: Int, epoch: String?, stream id: UUID?) throws {
        try assertOpen(); try Task.checkCancellation()
        guard generation == expected, connection?.epoch == epoch, streamID == id else {
            throw RuntimeError("STALE_CONNECTION", "Runtime snapshot is obsolete")
        }
    }
    func acceptMutation(_ mutation: JSONValue) async throws {
        guard let current = state, let revision = mutation["revision"]?.intValue,
              let old = current["revision"]?.intValue else { throw RuntimeError("INVALID_EVENT", "State mutation arrived without a snapshot") }
        if revision <= old { return }
        if mutation["baseRevision"]?.intValue != old {
            let expected = generation; let epoch = connection?.epoch; let id = streamID
            _ = try await loadState()
            try assertHydrationCurrent(generation: expected, epoch: epoch, stream: id)
            // Another hydration may commit while this caller resumes. Apply to
            // the current actor state, never roll it back to an awaited value.
            guard let refreshed = state else { throw RuntimeError("INVALID_SNAPSHOT", "Runtime recovery did not install a snapshot") }
            if let newRevision = refreshed["revision"]?.intValue, revision <= newRevision { return }
            state = try RuntimeState.applying(mutation, to: refreshed)
        } else { state = try RuntimeState.applying(mutation, to: current) }
        emit(.mutation(mutation, state: state!, authority: stateAuthority))
        readingStateDirty = true; scheduleReadingCache()
    }

    public func close() {
        guard !closed else { return }
        closed = true; generation += 1
        settingsDiagnosticsTask?.cancel(); settingsDiagnosticsTask = nil; settingsDiagnosticsQueue.removeAll()
        setStatus(.disconnected)
        starting?.cancel(); reconnectTask?.cancel(); retireStream()
        for command in activeCommands.values { command.cancel() }
        connection = nil; contentResources.removeAll(); setStatus(.disconnected)
        for continuation in observers.values { continuation.finish() }; observers.removeAll()
    }
    public func stopService() async throws {
        try assertOpen()
        let expected = generation
        // Join explicit launch before stopping: ownership can exist before discovery.
        if let starting { _ = try? await starting.value }
        guard !closed, generation == expected else { return }
        let epoch = connection?.epoch
        try await manager.stop(expectedEpoch: epoch)
        guard !closed, generation == expected, connection?.epoch == epoch else { return }
        explicitlyStopped = true; setStatus(.stopped); retireStream()
        // Observe a different service epoch started by another explicit client;
        // this poll never launches a process. close() cancels it on app quit.
        scheduleReconnect(generation: expected)
    }
    public func setOutputLocale(_ locale: String) throws { try assertOpen(); try manager.setOutputLocale(locale) }
}
