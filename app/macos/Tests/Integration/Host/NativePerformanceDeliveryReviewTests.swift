import Foundation
import Synchronization
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
@testable import MokuseiUI

@MainActor @Suite(.serializedNative, .serialized)
struct NativePerformanceDeliveryReviewTests {
    @Test func failedShutdownReleasesWorkspaceWithoutDiscardingPreparedCatalog() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory))
        let workspace = NativeWorkspaceModel(client: client, preferences: DesktopPreferences(directory: directory),
            plugins: try .init(harnesses: [], sidecards: [], applications: []))
        let authority = UUID()
        let snapshot: JSONValue = .object(["revision": .integer(2), "settingsRevision": .integer(2),
            "defaultCwd": .text("/tmp"), "settings": .object([:]), "threads": .array([]),
            "applicationThreads": .array([]), "executions": .array([])])
        let mutation: JSONValue = .object(["type": .text("state-patched"), "baseRevision": .integer(1), "revision": .integer(2)])
        var observed = false
        workspace.onCatalogChange = { event in
            if case .mutation(let raw, let state, let owner) = event {
                #expect(raw == mutation && state == snapshot && owner == authority)
                #expect(workspace.catalog.revision == 2 && workspace.state == snapshot)
                observed = true
            }
        }
        defer { workspace.onCatalogChange = nil }
        var released = false
        workspace.onStopped = { released = true }
        // Park only this isolated client actor. Shutdown sets its stopping
        // flag while its service request waits. Cancellation then makes
        // shutdown fail at the real RuntimeProcessManager cancellation check.
        let entered = Mutex(false), release = DispatchSemaphore(value: 0)
        let blocker = Task.detached { await client.holdForDeliveryReview({ entered.withLock { $0 = true } }, release) }
        defer { release.signal() }
        for _ in 0..<300 where !entered.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(entered.withLock { $0 })
        let stop = Task { try await workspace.stop() }
        for _ in 0..<300 where !workspace.stopping { await Task.yield() }
        #expect(workspace.stopping)
        await workspace.installPrepared(snapshot, event: .mutation(mutation, state: snapshot, authority: authority))
        stop.cancel(); release.signal(); await blocker.value
        do { try await stop.value; Issue.record("Cancelled shutdown succeeded") }
        catch is CancellationError { }
        #expect(workspace.stopping && released)
        #expect(await client.connectionStatus() == .disconnected)
        do { try await client.start(); Issue.record("Stopped client reopened") }
        catch let error as RuntimeError { #expect(error.code == "CLIENT_CLOSED") }
        #expect(workspace.catalog.revision == 2 && workspace.state == snapshot && observed)
        #expect(workspace.snapshotAuthority == authority)
        await client.close()
    }

    @Test func cancelledPreparationCannotPublishOrReplaceAuthority() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory))
        let workspace = NativeWorkspaceModel(client: client, preferences: DesktopPreferences(directory: directory),
            plugins: try .init(harnesses: [], sidecards: [], applications: []))
        let original: JSONValue = .object(["revision": .integer(1), "settingsRevision": .integer(1),
            "defaultCwd": .text("/tmp"), "settings": .object([:]), "threads": .array([]),
            "applicationThreads": .array([]), "executions": .array([])])
        let authority = UUID()
        await workspace.installPrepared(original, event: .snapshot(original, authority: authority))
        let recovery = workspace.recoveryRevision
        var next = try #require(original.objectValue)
        next["revision"] = .integer(2)
        let replacement = JSONValue.object(next)
        var published = false
        workspace.onCatalogChange = { _ in published = true }
        defer { workspace.onCatalogChange = nil }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await workspace.installPrepared(replacement, event: .snapshot(replacement, authority: UUID()))
        }
        await task.value
        #expect(!published && workspace.state == original && workspace.catalog.revision == 1)
        #expect(workspace.snapshotAuthority == authority && workspace.recoveryRevision == recovery)
        await client.close()
    }
}

extension RuntimeClient {
    fileprivate func holdForDeliveryReview(_ entered: @Sendable () -> Void, _ release: DispatchSemaphore) {
        entered()
        _ = release.wait(timeout: .now() + 10)
    }
}
