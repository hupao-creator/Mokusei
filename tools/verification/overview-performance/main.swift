import AppKit
import Darwin
import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiHarnessCodex
@testable import MokuseiUI

private struct Failure: Error { let message: String }

private func cpuSeconds() -> Double {
    var value = rusage()
    getrusage(RUSAGE_SELF, &value)
    return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
        + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1e6
}

@MainActor private final class Fixture {
    let workspace: NativeWorkspaceModel
    let model: NativeOverviewWorkspaceModel
    let authority = UUID()
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("overview-cpu-\(UUID())")
        workspace = NativeWorkspaceModel(client: RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory)),
            preferences: DesktopPreferences(directory: directory),
            plugins: try .init(harnesses: [AnyHarnessPlugin(CodexHarnessPlugin())], sidecards: [], applications: []))
        model = NativeOverviewWorkspaceModel(workspace: workspace, applications: .init(
            projectionCapabilities: { _, _ in throw Failure(message: "No fixture applications") },
            rendererContext: { _, _, _ in throw Failure(message: "No fixture applications") }))
    }

    func install(_ snapshot: JSONValue) throws {
        let initial = workspace.catalog.revision < 0
        try workspace.catalog.install(snapshot)
        model.receive(initial ? .snapshot(snapshot, authority: authority)
            : .mutation(.object([:]), state: snapshot, authority: authority))
        guard model.error == nil else { throw Failure(message: model.error!) }
    }

    func close() async {
        await model.stop()
        await workspace.client.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

private func snapshot(count: Int, variant: Int = 0) throws -> JSONValue {
    let threads = try (0..<count).map { index -> JSONValue in
        let scope = index % 10, tag = (index / 10) % 5
        let name = "主题 \(tag)"
        return try HarnessThread(id: JSONText("card-\(index)"), harnessID: "codex", revision: index == 0 ? variant : 0,
            sessionState: .null, observation: .init(latestExecution: try PublicExecution(
                executionID: JSONText("execution-\(index)"), status: index == 0 && variant == 1 ? .running : .completed,
                startedAt: 1, finishedAt: index == 0 && variant == 1 ? nil : 2)),
            cwd: JSONText("/fixture/目录-\(scope)"), settings: .object([:]), createdAt: Double(index), updatedAt: Double(index + 2 + (index == 0 ? variant : 0)),
            title: JSONText("Card \(index) — 界面设计 Café \(index == 0 ? variant : 0)"), tags: [JSONText(name)],
            tagEmojis: [JSONText(name): "🔧"], directoryTag: JSONText("目录-\(scope)"),
            directoryScope: JSONText("/fixture/目录-\(scope)")).json
    }
    return .object(["revision": .integer(variant), "settingsRevision": .integer(0),
        "defaultCwd": .text("/fixture"), "settings": .object([:]), "threads": .array(threads),
        "applicationThreads": .array([]), "executions": .array([])])
}

@MainActor private func measure(_ name: String, count: Int, iterations: Int,
                                action: (Int) throws -> Void) rethrows -> [String: Any] {
    for iteration in 0..<3 { try action(iteration) }
    var elapsed: [Double] = []
    let cpu = cpuSeconds()
    for iteration in 0..<iterations {
        let start = DispatchTime.now().uptimeNanoseconds
        try action(iteration)
        elapsed.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
    }
    return ["scenario": name, "count": count, "iterations": iterations,
        "elapsedMs": elapsed, "processCPUSeconds": cpuSeconds() - cpu]
}

@main struct OverviewPerformanceMain {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw Failure(message: "Expected output JSON path") }
        let startedAt = ISO8601DateFormatter().string(from: Date())
        let initialThermalState = ProcessInfo.processInfo.thermalState.rawValue
        var records: [[String: Any]] = []
        for count in [0, 5, 30, 100, 500] {
            let variants = try [snapshot(count: count), snapshot(count: count, variant: 1)]
            var fresh: [Double] = []
            for _ in 0..<5 {
                let fixture = try Fixture()
                let start = DispatchTime.now().uptimeNanoseconds
                try fixture.install(variants[0])
                fresh.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                guard fixture.model.items.count == count else { throw Failure(message: "Initial membership mismatch") }
                await fixture.close()
            }
            records.append(["scenario": "fresh-model", "count": count, "iterations": 5, "elapsedMs": fresh])
            let fixture = try Fixture()
            try fixture.install(variants[0])
            let n = count < 100 ? 50 : 20
            records.append(try measure("catalog-admission", count: count, iterations: n) { i in
                try fixture.workspace.catalog.install(variants[i % 2])
            })
            records.append(try measure("status-update", count: count, iterations: n) { i in
                try fixture.install(variants[i % 2])
            })
            records.append(try measure("unchanged-delivery", count: count, iterations: n) { _ in
                try fixture.install(variants[0])
            })
            records.append(measure("warm-reconcile", count: count, iterations: n) { _ in
                fixture.model.refreshCardExtensions()
            })
            let filters = fixture.model.filters + fixture.model.filters.flatMap(\.children)
            records.append(measure("filter-switch", count: count, iterations: n) { i in
                fixture.model.selectTag(i.isMultiple(of: 3) || filters.isEmpty ? nil : filters[i % filters.count])
            })
            fixture.model.selectTag(nil)
            records.append(measure("leave-return", count: count, iterations: n) { _ in
                fixture.model.setPresentation(.init(overviewVisible: false))
                fixture.model.setPresentation(.init(overviewVisible: true))
            })
            fixture.model.beginSearch()
            records.append(measure("keyword-search", count: count, iterations: n) { i in
                fixture.model.updateSearch(i.isMultiple(of: 2) ? "Café" : "no-match")
            })
            fixture.model.endSearch()
            guard fixture.model.items.count == count, fixture.model.error == nil else { throw Failure(message: "Final membership mismatch") }
            records.append(["scenario": "counters", "count": count, "membershipBuilds": fixture.model.membershipBuildCount])
            await fixture.close()
        }
        for count in [5, 6, 12, 30] {
            let members = (0..<count).map { NativeOverviewMember(id: "layout-\($0)", columns: count <= 6 && $0 == 0 ? 2 : 1, rows: 1) }
            var previous: [NativeOverviewPlacement] = []
            records.append(try measure("layout-initial", count: count, iterations: 5) { _ in
                previous = try NativeOverviewLayout.plan(previous: [], next: members, fittingSize: CGSize(width: 1440, height: 780)).placements
            })
            records.append(try measure("layout-resize", count: count, iterations: 5) { i in
                let result = try NativeOverviewLayout.plan(previous: previous, next: members,
                    fittingSize: CGSize(width: i.isMultiple(of: 2) ? 900 : 1440, height: 780))
                guard result.placements.count == count else { throw Failure(message: "Layout membership mismatch") }
            })
        }
        let output: [String: Any] = ["schema": 1, "startedAt": startedAt,
            "endedAt": ISO8601DateFormatter().string(from: Date()), "initialThermalState": initialThermalState,
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "cpuCount": ProcessInfo.processInfo.processorCount,
            "physicalMemory": ProcessInfo.processInfo.physicalMemory, "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
            "pid": ProcessInfo.processInfo.processIdentifier, "configuration": "Release -O, -enable-testing, recorder off",
            "boundary": "Synchronous production CPU paths; no GUI, Runtime, GPU, frame/presentation or provider measurement",
            "records": records]
        try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
