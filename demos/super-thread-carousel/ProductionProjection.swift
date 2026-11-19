import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiHarnessCodex
@testable import MokuseiApplications
@testable import MokuseiUI

/// Windowless fixture export through the actual catalog, preferences and Overview
/// model. No Runtime connection, XCTest copy of the rules, or live profile access.
@MainActor func exportProductionProjection(fixtures: [String: ReportFixture]) async throws {
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("collection-profile-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()
    let preferences = DesktopPreferences(directory: directory)
    for sample in ReportSample.samples {
        if let minutes = sample.minutesSinceClose {
            try preferences.recordApplicationReading(key: "report.document:\(sample.id)", value: .init(lastClosedAt: now.addingTimeInterval(-60 * minutes).timeIntervalSince1970))
        }
    }
    func makeModel(_ preferences: DesktopPreferences) throws -> NativeOverviewWorkspaceModel {
        let workspace = NativeWorkspaceModel(client: RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory)),
            preferences: preferences, plugins: try .init(harnesses: [AnyHarnessPlugin(CodexHarnessPlugin())],
                sidecards: [], applications: NativeApplicationModules.make()))
        return .init(workspace: workspace, applications: .init(projectionCapabilities: { plugin, entry in
            try .init(scope: .init(pluginID: plugin.ownerPluginID, thread: entry.ref), requires: plugin.requires, registrations: [])
        }, rendererContext: { _, _, _ in throw CancellationError() }))
    }
    let records: [JSONValue] = ReportSample.samples.map { sample in
        let entry = fixtures[sample.id]!.props.entry
        return .object([
            "id": .string(entry.ref.threadID), "ref": entry.ref.json, "revision": .integer(entry.revision),
            "createdAt": .number(now.timeIntervalSince1970 * 1000), "updatedAt": .number(now.timeIntervalSince1970 * 1000),
            "title": .string(entry.title), "archived": .bool(false), "scope": .text("/fixture/carousel"),
            "tags": .object(["tags": .array(sample.tags.map(JSONValue.text)),
                "semanticTags": .array(sample.tags.map(JSONValue.text)), "directoryTags": .array([.text("Demo")]),
                "tagEmojis": .object(Dictionary(uniqueKeysWithValues: sample.tags.map { (JSONText($0), JSONValue.text("📌")) }))]),
            "presentations": .array([]), "view": entry.view.json])
    }
    func deliver(_ records: [JSONValue], to model: NativeOverviewWorkspaceModel, authority: UUID) throws {
        let snapshot: JSONValue = .object(["revision": .integer(model.workspace.catalog.revision + 1),
            "settingsRevision": .integer(0), "defaultCwd": .text("/fixture/carousel"), "settings": .object([:]),
            "threads": .array([]), "executions": .array([]), "applicationThreads": .array(records)])
        let initial = model.workspace.catalog.revision < 0
        try model.workspace.catalog.install(snapshot)
        model.receive(initial ? .snapshot(snapshot, authority: authority) : .mutation(.object([:]), state: snapshot, authority: authority))
    }
    let model = try makeModel(preferences), authority = UUID()
    try deliver(records, to: model, authority: authority)
    func snapshot(_ name: String, model: NativeOverviewWorkspaceModel) -> [String: Any] {
        var collections = [[String]](), singles = [String](), titles = [String]()
        for item in model.items {
            switch model.snapshot(for: item) {
            case .collection(_, let members):
                collections.append(members.map { $0.entry.ref.threadID.string })
                titles.append(contentsOf: members.map { $0.entry.title.string })
            case .application(_, let value): singles.append(value.entry.ref.threadID.string)
            default: break
            }
        }
        return ["scenario": name, "collections": collections, "individual": singles,
                "surfaceOwners": Dictionary(uniqueKeysWithValues: model.items.map { ($0.id, $0.providesCardSurface) }),
                "memberTitles": titles, "error": model.error ?? ""]
    }
    var rows = [snapshot("production-initial", model: model)]
    let filters = model.filters + model.filters.flatMap(\.children)
    rows.append(["scenario": "production-filter-inventory", "filters": filters.map(\.tag)])
    for tag in ["产品", "原生", "工程", "未读"] {
        if let filter = filters.first(where: { $0.tag == tag }) {
            model.selectTag(filter); rows.append(snapshot("production-tag-\(tag)", model: model))
        }
    }
    model.selectTag(nil)
    let first = fixtures["navigation"]!.props.entry.ref
    rows.append(["scenario": "production-opening-source", "isCollection": model.sourceCardID(for: first) != nil])
    model.recordApplicationOpen(first, at: now, uptime: 0)
    model.updateApplicationReading(visible: true, uptime: 0)
    model.recordApplicationClose(at: now.addingTimeInterval(50), uptime: 50)
    rows.append(snapshot("production-qualified-reader-return", model: model))
    let reopened = try makeModel(DesktopPreferences(directory: directory))
    try deliver(records, to: reopened, authority: UUID())
    rows.append(snapshot("production-reopened-profile", model: reopened))
    for elapsed in [86_399, 86_400] {
        let state = reopened.collectionEligibility(first, at: now.addingTimeInterval(Double(elapsed + 50)))!
        rows.append(["scenario": "idle-after-\(elapsed)", "state": try JSONSerialization.jsonObject(with: state.encodedData())])
    }
    let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("production-projection.json")
    try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: output)
    await model.stop(); await reopened.stop()
}
