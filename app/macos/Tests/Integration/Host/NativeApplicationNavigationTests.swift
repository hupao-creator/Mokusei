import AppKit
import Observation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
@testable import MokuseiUI

@MainActor @Observable private final class ApplicationNavigationFixture {
    var action: ThreadDetailBackAction?
    var mounted = true
    var revision = 0
    var backs = 0
    @ObservationIgnored var publications = 0
}

private struct ApplicationNavigationReplay: View {
    let host: NativeApplicationHost
    let thread: ApplicationThreadRef
    let fixture: ApplicationNavigationFixture

    var body: some View {
        VStack {
            // Reading the host's action reproduces the shell's redraw after a
            // page publishes navigation. The production page owns its identity.
            Text(fixture.action?.id.uuidString ?? "No navigation")
            Text("Revision \(fixture.revision)")
            if fixture.mounted {
                host.detail(thread: thread, environment: .init(suppressed: fixture.revision.isMultiple(of: 2),
                    onBack: { fixture.backs += 1 }, onSettings: {}, onNativeNavigationChange: { _ in },
                    onNavigationChange: { action in
                        fixture.publications += 1
                        fixture.action = action
                    }))
            }
        }
    }
}

@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeApplicationNavigationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOKUSEI_READING_PRESENTATION_NATIVE_REPLAY"] == "1", "Requires the isolated AppKit event loop: python3 tools/verification/reading-presentation/run.py --application-navigation"),
          arguments: ["report.document", "git.worktree"])
    func applicationBackActionSettlesAcrossRedrawLocaleAndRemount(type: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory))
        defer { Task { await client.close() } }
        let preferences = DesktopPreferences(directory: directory)
        try preferences.setLocale(.english)
        let workspace = NativeWorkspaceModel(client: client, preferences: preferences,
            plugins: try NativePluginComposition(harnesses: [], sidecards: [], applications: []))
        let host = NativeApplicationHost(workspace: workspace, navigationCallbacks: .init(
            openThread: { _, _ in }, openExecution: { _ in }, followUp: { _, _ in }, openExternal: { _ in }))
        defer { host.release() }
        let fixture = ApplicationNavigationFixture()
        // Missing records deliberately keep both real pages on their local
        // unavailable-content path; no runtime, repository or WebKit is needed.
        let window = SwiftUIReplay.window(ApplicationNavigationReplay(host: host,
            thread: .init(threadID: "fixture", typeID: JSONText(type)), fixture: fixture), offscreen: true)
        defer { window.close() }
        try await SwiftUIReplay.wait { fixture.action?.label == "Back to overview" }
        let first = try #require(fixture.action)
        let publications = fixture.publications
        for revision in 1...5 {
            fixture.revision = revision
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(fixture.action?.id == first.id)
        #expect(fixture.publications == publications, "Unrelated renders must not republish navigation")
        fixture.action?.onBack()
        #expect(fixture.backs == 1)

        try preferences.setLocale(.chinese)
        try await SwiftUIReplay.wait { fixture.action?.label == "返回俯瞰" }
        let localized = try #require(fixture.action)
        let localizedPublications = fixture.publications
        fixture.revision += 1
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.action?.id == localized.id && fixture.publications == localizedPublications)

        fixture.mounted = false
        try await SwiftUIReplay.wait { fixture.action == nil }
        fixture.mounted = true
        try await SwiftUIReplay.wait { fixture.action != nil }
        #expect(fixture.action?.id != localized.id)
        fixture.action?.onBack()
        #expect(fixture.backs == 2)
    }
}
