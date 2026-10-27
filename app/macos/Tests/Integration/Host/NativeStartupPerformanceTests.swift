import AppKit
import Foundation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
import MokuseiPluginAPI
@testable import MokuseiUI

@MainActor @Suite(.serializedNative, .serialized)
struct NativeStartupPerformanceTests {
    private func snapshot(moku: Bool) throws -> JSONValue {
        let thread = try HarnessThread(id: "moku", harnessID: "codex", revision: 0,
            sessionState: .object([:]), observation: .init(), cwd: "/tmp", settings: .object([:]),
            createdAt: 0, updatedAt: 0, title: "Moku", tags: [], moku: true, transcript: .array([]))
        return .object(["revision": .integer(1), "settingsRevision": .integer(1),
            "defaultCwd": .text("/tmp"), "settings": .object([:]),
            "threads": .array(moku ? [thread.json] : []), "applicationThreads": .array([]), "executions": .array([])])
    }

    private func records(_ url: URL) throws -> [[String: Any]] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap {
            let value = try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
            return (value["metric"] as? String)?.hasPrefix("startup.") == true ? value : nil
        }
    }

    @Test(.requiresDisplay) func loadingWaitsForMokuAndMountRecordsOnceIncludingPreRecorderTime() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { NativePerformance.finish(); try? FileManager.default.removeItem(at: directory) }
        let startup = NativeStartupPerformance(startedAt: NativePerformance.now() - 100_000_000)
        let log = try #require(NativePerformance.configure(directory: directory, mode: .detailed))
        startup.attachToRecording()
        let client = RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory))
        let workspace = NativeWorkspaceModel(client: client, preferences: DesktopPreferences(directory: directory),
            plugins: try .init(harnesses: [], sidecards: [], applications: []), startupPerformance: startup)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var appearances = 0
        func mount() {
            window.contentView = NSHostingView(rootView: NativeRuntimeSurface(model: workspace) {
                Text("Ready").onAppear { appearances += 1 }
            })
            window.makeKeyAndOrderFront(nil)
        }
        mount()
        startup.shellReady()
        let incomplete = try snapshot(moku: false)
        await workspace.installPrepared(incomplete, event: .snapshot(incomplete, authority: UUID()))
        try await Task.sleep(for: .milliseconds(80))
        #expect(!workspace.hasInitialContent && appearances == 0)
        let complete = try snapshot(moku: true)
        await workspace.installPrepared(complete, event: .snapshot(complete, authority: UUID()))
        for _ in 0..<100 where appearances == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(workspace.hasInitialContent && appearances == 1)
        mount() // Reload/remount must not produce another startup sample.
        for _ in 0..<100 where appearances < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(appearances == 2)
        await workspace.installPrepared(complete, event: .snapshot(complete, authority: UUID()))
        startup.cancel()
        NativePerformance.finish()
        let events = try records(log)
        #expect(events.compactMap { $0["metric"] as? String } == [
            "startup.shellReady", "startup.dataReady", "startup.timeToReady"])
        let durations = events.compactMap { $0["durationMs"] as? Double }
        #expect(durations.count == 3 && durations == durations.sorted())
        #expect((durations.first ?? 0) >= 100)
        let values = try #require(events.last?["values"] as? [String: Double])
        #expect(abs((values["afterDataMs"] ?? -1) - (durations[2] - durations[1])) < 0.001)
        await client.close()
    }

    @Test func failedCatalogDoesNotBecomeSuccessfulAfterRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { NativePerformance.finish(); try? FileManager.default.removeItem(at: directory) }
        let startup = NativeStartupPerformance()
        let log = try #require(NativePerformance.configure(directory: directory, mode: .detailed))
        startup.attachToRecording()
        let client = RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory))
        let workspace = NativeWorkspaceModel(client: client, preferences: DesktopPreferences(directory: directory),
            plugins: try .init(harnesses: [], sidecards: [], applications: []), startupPerformance: startup)
        await workspace.installPrepared(.null, event: .snapshot(.null, authority: UUID()))
        #expect(workspace.connectionError != nil)
        let complete = try snapshot(moku: true)
        await workspace.installPrepared(complete, event: .snapshot(complete, authority: UUID()))
        startup.contentAppeared()
        startup.cancel()
        NativePerformance.finish()
        #expect(try records(log).compactMap { $0["metric"] as? String } == ["startup.failed"])
        await client.close()
    }

    @Test func cancelledAndCrossSessionLaunchesNeverReportReady() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { NativePerformance.finish(); try? FileManager.default.removeItem(at: directory) }
        let first = try #require(NativePerformance.configure(directory: directory, mode: .detailed))
        let cancelled = NativeStartupPerformance()
        cancelled.attachToRecording()
        cancelled.cancel(); cancelled.cancel(); cancelled.dataReady(); cancelled.contentAppeared()
        let switched = NativeStartupPerformance()
        switched.attachToRecording()
        switched.dataReady()
        let second = try #require(NativePerformance.configure(directory: directory, mode: .detailed))
        switched.attachToRecording(); switched.contentAppeared()
        NativePerformance.finish()
        #expect(try records(first).compactMap { $0["metric"] as? String } == ["startup.cancelled", "startup.dataReady"])
        #expect(try records(second).isEmpty)
        NativePerformance.configure(directory: directory, mode: .off)
        let disabled = NativeStartupPerformance()
        disabled.attachToRecording()
        let third = try #require(NativePerformance.configure(directory: directory, mode: .detailed))
        disabled.dataReady(); disabled.contentAppeared()
        NativePerformance.finish()
        #expect(try records(third).isEmpty)
    }
}
