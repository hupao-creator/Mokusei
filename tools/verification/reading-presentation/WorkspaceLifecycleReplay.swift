import AppKit
import SwiftUI
import Testing
import MokuseiCore
import MokuseiPluginAPI
@testable import MokuseiUI

/// Supply a non-cooperative wire release while the production resource, Host,
/// presentation and application session retain their real cancellation logic.
@MainActor private final class WorkspaceLifecycleGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    private(set) var calls = 0
    var entered: Bool { calls > 0 }

    func wait() async {
        calls += 1
        if !opened { await withCheckedContinuation { continuation = $0 } }
    }
    func open() {
        opened = true
        continuation?.resume(); continuation = nil
    }
}

private struct WorkspaceLifecycleSurface: View {
    let session: WorkspaceSession
    var body: some View {
        if let model = session.model, let presentation = session.presentation {
            NativeWorkspaceView(model: model, presentation: presentation).id(session.generation)
        }
    }
}

@MainActor private final class WorkspaceLifecycleFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let client: RuntimeClient
    let workspace: NativeWorkspaceModel
    let session: WorkspaceSession
    private var window: NSWindow?
    private var gates: [WorkspaceLifecycleGate] = []
    private var operations: [Task<Void, Never>] = []

    init() throws {
        client = RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory))
        workspace = NativeWorkspaceModel(client: client, preferences: DesktopPreferences(directory: directory),
            plugins: try NativePluginComposition(harnesses: [], sidecards: [], applications: []))
        session = WorkspaceSession(model: workspace)
    }
    func mount() async throws {
        window = SwiftUIReplay.window(WorkspaceLifecycleSurface(session: session))
        try await waitForMountedOwner()
    }
    func waitForMountedOwner() async throws {
        try await SwiftUIReplay.wait { self.workspace.onStopped != nil }
    }
    func gate() -> WorkspaceLifecycleGate {
        let gate = WorkspaceLifecycleGate()
        gates.append(gate)
        return gate
    }
    func resource(_ gate: WorkspaceLifecycleGate) -> HarnessContentResource {
        let resource = HarnessContentResource(retry: {}, release: { await gate.wait() })
        workspace.harnessHost.register(resource, id: UUID().uuidString)
        return resource
    }
    func operation() throws -> Task<Void, Never> {
        let task = try #require(session.reloadTask)
        operations.append(task)
        return task
    }
    func finish() async {
        for gate in gates { gate.open() }
        for operation in operations { await operation.value }
        // A pending Settings rejection may install its recovery after the
        // interrupted reload drains. Join that owner before closing the view.
        try? await SwiftUIReplay.wait(timeout: .seconds(5)) { !self.session.busy }
        await session.reloadTask?.value
        window?.contentView = nil; window?.close(); window = nil
        await session.presentation?.release()
        await workspace.voice.stopAll()
        await workspace.harnessHost.releaseAll()
        workspace.settingsModel.discardForReload()
        await client.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeWorkspaceLifecycleReplay {
    private func withFixture(_ body: (WorkspaceLifecycleFixture) async throws -> Void) async throws {
        let fixture = try WorkspaceLifecycleFixture()
        do {
            try await fixture.mount()
            try await body(fixture)
            await fixture.finish()
        } catch {
            await fixture.finish()
            throw error
        }
    }

    @Test func reloadWaitsForScopedCleanupBeforeReplacingPresentation() async throws {
        try await withFixture { fixture in
            let session = fixture.session
            let original = try #require(session.presentation), generation = session.generation
            let release = fixture.gate(), resource = fixture.resource(release)
            session.reload()
            let reload = try fixture.operation()
            try await SwiftUIReplay.wait { release.entered }
            #expect(resource.isReleased && session.busy)
            #expect(session.presentation === original && session.generation == generation)
            #expect(fixture.workspace.onStopped == nil)

            release.open()
            await reload.value
            #expect(!session.busy && session.reloadTask == nil)
            #expect(session.presentation !== original && session.generation != generation)
            #expect(release.calls == 1)
            try await fixture.waitForMountedOwner()
            print("WORKSPACE_RELOAD_RESOURCE_DRAIN_CONFIRMED")
        }
    }

    @Test func quitRevokesReloadUntilRejectedSaveRestoresWorkspace() async throws {
        try await withFixture { fixture in
            let session = fixture.session
            let original = try #require(session.presentation), generation = session.generation
            let release = fixture.gate(), resource = fixture.resource(release)
            session.reload()
            let reload = try fixture.operation()
            try await SwiftUIReplay.wait { release.entered }

            let save = fixture.gate()
            let initial: JSONValue = .object(["moku": .object(["routingGuidance": .null])])
            let edited: JSONValue = .object(["moku": .object(["routingGuidance": .text("keep this unsaved edit")])])
            let settings = NativeSettingsModel(settings: initial, revision: 1, save: { _, _ in
                await save.wait()
                throw RuntimeError("FIXTURE_SAVE_REJECTED", "Settings save rejected by the fixture")
            }, clearHistory: {}, loadInstallations: { .array([]) }, installHarness: { _ in })
            settings.draft.runtimeAvailable = true
            fixture.workspace.settingsModel = settings
            settings.draft.change(edited, textEdit: true)
            session.quit()
            try await SwiftUIReplay.wait { save.entered }
            #expect(reload.isCancelled)

            release.open()
            await reload.value
            #expect(resource.isReleased && release.calls == 1)
            #expect(session.presentation === original && session.generation == generation)
            #expect(session.busy && !session.quitSettingsBlocked)
            #expect(fixture.workspace.onStopped == nil)

            save.open()
            try await SwiftUIReplay.wait { session.quitSettingsBlocked }
            // Recovery can already have completed before this observation.
            if session.reloadTask != nil { await (try fixture.operation()).value }
            #expect(!session.busy && session.reloadTask == nil)
            #expect(session.presentation !== original && session.generation != generation)
            #expect(fixture.workspace.settingsModel === settings)
            #expect(settings.draft.value == edited && settings.draft.saved == initial)
            #expect(session.error != nil && !fixture.workspace.stopping)
            try await fixture.waitForMountedOwner()
            print("WORKSPACE_QUIT_REVOKES_RELOAD_PUBLICATION_CONFIRMED")
        }
    }

    @Test func rejectedQuitCannotLetAnOldReloadClearItsSuccessor() async throws {
        try await withFixture { fixture in
            let session = fixture.session
            let original = try #require(session.presentation), generation = session.generation
            let release = fixture.gate()
            _ = fixture.resource(release)
            session.reload()
            let reload = try fixture.operation()
            try await SwiftUIReplay.wait { release.entered }
            let settings = fixture.workspace.settingsModel
            settings.draft.runtimeAvailable = true
            settings.draft.composing = true
            let edited: JSONValue = .object(["moku": .object(["routingGuidance": .text("composition survives rejected Quit")])])
            settings.draft.change(edited, textEdit: true)

            session.quit()
            try await SwiftUIReplay.wait { session.quitSettingsBlocked }
            let recovery = try fixture.operation()
            #expect(reload.isCancelled && !recovery.isCancelled && session.busy)
            session.quitSettingsBlocked = false; session.error = nil
            session.quit()
            try await SwiftUIReplay.wait { session.quitSettingsBlocked }
            let successor = try fixture.operation()
            #expect(recovery.isCancelled && !successor.isCancelled)
            #expect(session.busy && session.presentation === original && session.generation == generation)

            release.open()
            await reload.value
            await recovery.value
            await successor.value
            #expect(!session.busy && session.reloadTask == nil)
            #expect(session.presentation !== original && session.generation != generation)
            #expect(fixture.workspace.settingsModel === settings)
            #expect(settings.draft.composing && settings.draft.value == edited)
            #expect(release.calls == 1 && !fixture.workspace.stopping)
            try await fixture.waitForMountedOwner()
            print("WORKSPACE_RELOAD_SUCCESSOR_IDENTITY_CONFIRMED")
        }
    }
}
