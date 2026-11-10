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
        if let minutes = sample.minutesSinceOpen {
            try preferences.recordApplicationOpen(key: "report.document:\(sample.id)", at: now.addingTimeInterval(-60 * minutes))
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
            "createdAt": .number(entry.createdAt), "updatedAt": .number(entry.updatedAt),
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
    // Navigation freezes the old surface until Overview returns.
    model.setPresentation(.init(overviewVisible: false, selectedThread: first))
    model.recordApplicationOpen(first)
    rows.append(snapshot("production-opening-retains-backdrop", model: model))
    model.setPresentation(.init())
    rows.append(snapshot("production-return-releases-opened-member", model: model))
    model.recordApplicationOpen(fixtures["typography"]!.props.entry.ref)
    rows.append(snapshot("production-single-candidate-dissolves", model: model))
    let reopened = try makeModel(DesktopPreferences(directory: directory))
    try deliver(records, to: reopened, authority: UUID())
    rows.append(snapshot("production-restored-open-history", model: reopened))
    model.beginSearch(); model.updateSearch("的")
    rows.append(snapshot("production-search-uncollected", model: model))
    model.endSearch()
    // Put the first two visits back in the past via the actual open recorder.
    model.recordApplicationOpen(first, at: now.addingTimeInterval(-1200))
    model.recordApplicationOpen(fixtures["typography"]!.props.entry.ref, at: now.addingTimeInterval(-1200))
    var changed = records
    var fields = changed[0].objectValue!
    fields["title"] = .text("Updated collection member")
    fields["revision"] = .integer(2)
    changed[0] = .object(fields)
    try deliver(changed, to: model, authority: authority)
    rows.append(snapshot("production-member-content-update", model: model))
    model.recordApplicationOpen(first)
    model.recordApplicationOpen(fixtures["typography"]!.props.entry.ref)
    model.recordApplicationOpen(first, at: Date().addingTimeInterval(-599.9))
    rows.append(snapshot("production-before-expiry", model: model))
    try await Task.sleep(for: .milliseconds(300))
    rows.append(snapshot("production-deadline-regroups-without-catalog-event", model: model))
    try preferences.setLocale(.english)
    try preferences.selectThread("fixture-selection")
    rows.append(["scenario": "production-history-survives-preference-writes",
                 "preserved": DesktopPreferences(directory: directory).applicationLastOpened == preferences.applicationLastOpened])
    let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("production-projection.json")
    try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: output)
    await model.stop(); await reopened.stop()
}
