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
    // Navigation freezes the old surface until Overview returns.
    model.setPresentation(.init(overviewVisible: false, selectedThread: first))
    model.recordApplicationOpen(first)
    rows.append(snapshot("production-opening-retains-backdrop", model: model))
    let uptime = ProcessInfo.processInfo.systemUptime
    model.updateApplicationReading(visible: true, uptime: uptime)
    model.updateApplicationReading(visible: false, uptime: uptime + 120)
    rows.append(["scenario": "production-exactly-two-minutes", "eligibility": try JSONSerialization.jsonObject(with: model.collectionEligibility(first)!.encodedData())])
    model.recordApplicationClose(uptime: uptime + 120)
    model.setPresentation(.init())
    rows.append(snapshot("production-short-return-retains-member", model: model))
    model.recordApplicationOpen(first)
    model.updateApplicationReading(visible: true, uptime: uptime)
    model.updateApplicationReading(visible: false, uptime: uptime + 60)
    model.updateApplicationReading(visible: true, uptime: uptime + 600)
    model.recordApplicationOpen(first) // Same admitted route cannot reset dwell.
    model.updateApplicationReading(visible: false, uptime: uptime + 660.001)
    model.recordApplicationClose(uptime: uptime + 660.001)
    rows.append(snapshot("production-long-return-releases-member", model: model))
    model.recordApplicationOpen(fixtures["typography"]!.props.entry.ref)
    model.updateApplicationReading(visible: true, uptime: uptime)
    model.recordApplicationClose(uptime: uptime + 120.001)
    rows.append(snapshot("production-single-candidate-dissolves", model: model))
    let reopened = try makeModel(DesktopPreferences(directory: directory))
    try deliver(records, to: reopened, authority: UUID())
    rows.append(snapshot("production-restored-open-history", model: reopened))
    model.beginSearch(); model.updateSearch("的")
    rows.append(snapshot("production-search-uncollected", model: model))
    model.endSearch()
    // Exercise historical closes through the actual route recorder.
    model.recordApplicationOpen(first)
    model.recordApplicationClose(at: now.addingTimeInterval(-1200))
    model.recordApplicationOpen(fixtures["typography"]!.props.entry.ref)
    model.recordApplicationClose(at: now.addingTimeInterval(-1200))
    var changed = records
    var fields = changed[0].objectValue!
    fields["title"] = .text("Updated collection member")
    fields["revision"] = .integer(2)
    changed[0] = .object(fields)
    try deliver(changed, to: model, authority: authority)
    rows.append(snapshot("production-member-content-update", model: model))
    model.recordApplicationOpen(first)
    model.updateApplicationReading(visible: true, uptime: uptime)
    model.recordApplicationClose(at: Date().addingTimeInterval(-299.9), uptime: uptime + 121)
    rows.append(snapshot("production-before-expiry", model: model))
    try await Task.sleep(for: .milliseconds(300))
    rows.append(snapshot("production-deadline-regroups-without-catalog-event", model: model))
    try preferences.setLocale(.english)
    try preferences.selectThread("fixture-selection")
    rows.append(["scenario": "production-history-survives-preference-writes",
                 "preserved": DesktopPreferences(directory: directory).applicationCollectionReading == preferences.applicationCollectionReading])
    // Repeated short visits preserve eligibility across preference reloads.
    model.recordApplicationOpen(first)
    model.recordApplicationClose()
    model.recordApplicationOpen(first)
    model.recordApplicationClose()
    rows.append(["scenario": "production-repeated-short-visits", "persisted": DesktopPreferences(directory: directory).applicationCollectionReading["report.document:navigation"]?.retainsEligibility == true])
    let recent = fixtures["recent"]!.props.entry.ref
    model.recordApplicationOpen(recent, at: now)
    rows.append(["scenario": "production-open-time-never-ages", "eligibility": try JSONSerialization.jsonObject(with: model.collectionEligibility(recent, at: now.addingTimeInterval(3600))!.encodedData())])
    model.recordApplicationClose(at: now)
    model.recordApplicationOpen(recent, at: now.addingTimeInterval(240))
    let finalClose = now.addingTimeInterval(250)
    model.recordApplicationClose(at: finalClose)
    for (label, offset) in [("future-close", -1.0), ("reclose-exactly-five-minutes", 300.0), ("reclose-over-five-minutes", 300.001)] {
        rows.append(["scenario": "production-" + label, "eligibility": try JSONSerialization.jsonObject(with: model.collectionEligibility(recent, at: finalClose.addingTimeInterval(offset))!.encodedData())])
    }
    // Let the actual cancellable reading deadline fire without a two-minute wait.
    model.recordApplicationOpen(first)
    let liveUptime = ProcessInfo.processInfo.systemUptime
    model.updateApplicationReading(visible: true, uptime: liveUptime - 119.9)
    model.updateApplicationReading(visible: true, uptime: liveUptime)
    try await Task.sleep(for: .milliseconds(300))
    rows.append(["scenario": "production-reading-deadline-without-event", "eligibility": try JSONSerialization.jsonObject(with: model.collectionEligibility(first)!.encodedData())])
    model.recordApplicationClose()
    // Exercise the actual navigation entry, including an old preferences file
    // with only historical open evidence, before Overview has projected.
    let legacyDirectory = directory.appendingPathComponent("legacy-client")
    try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
    try Data(#"{"onboardingCompleted":true,"preferences":{"locale":"zh-CN","appearance":"system"},"applicationLastOpened":{"report.document:navigation":1}}"#.utf8)
        .write(to: legacyDirectory.appendingPathComponent("desktop-preferences.json"))
    let legacyPreferences = DesktopPreferences(directory: legacyDirectory)
    let navigationWorkspace = NativeWorkspaceModel(
        client: RuntimeClient(profile: try RuntimeProfile(dataDirectory: legacyDirectory)),
        preferences: legacyPreferences, plugins: try .init(harnesses: [AnyHarnessPlugin(CodexHarnessPlugin())],
            sidecards: [], applications: NativeApplicationModules.make()))
    let navigationSnapshot: JSONValue = .object(["revision": .integer(1), "settingsRevision": .integer(0),
        "defaultCwd": .text("/fixture/carousel"), "settings": .object([:]), "threads": .array([]),
        "executions": .array([]), "applicationThreads": .array(records)])
    try navigationWorkspace.catalog.install(navigationSnapshot)
    let navigation = NativeWorkspacePresentation(workspace: navigationWorkspace)
    rows.append(["scenario": "legacy-profile-does-not-invent-opens", "recordCount": legacyPreferences.applicationCollectionReading.count])
    rows.append(["scenario": "legacy-open-diagnostic",
                 "eligibility": try JSONSerialization.jsonObject(with: navigation.overview.collectionEligibility(first)!.encodedData())])
    navigation.open(first)
    rows.append(["scenario": "real-open-before-overview-projection", "selected": navigation.selected == first,
                 "persisted": DesktopPreferences(directory: legacyDirectory).applicationCollectionReading["report.document:navigation"] != nil])
    navigation.overview.receive(.snapshot(navigationSnapshot, authority: UUID()))
    navigation.open(fixtures["typography"]!.props.entry.ref)
    navigation.finishBack()
    rows.append(["scenario": "real-open-and-return-after-projection",
                 "persisted": DesktopPreferences(directory: legacyDirectory).applicationCollectionReading["report.document:typography"] != nil])
    rows.append(["scenario": "real-entry-close-diagnostic",
                 "eligibility": try JSONSerialization.jsonObject(with: navigation.overview.collectionEligibility(first)!.encodedData())])
    let missing = ApplicationThreadRef(threadID: "missing-report", typeID: "report.document")
    navigation.overview.recordApplicationOpen(missing)
    rows.append(["scenario": "missing-catalog-reference-not-recorded",
                 "persisted": DesktopPreferences(directory: legacyDirectory).applicationCollectionReading["report.document:missing-report"] != nil])
    navigation.applicationHost.release()
    await navigation.overview.stop()
    let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("production-projection.json")
    try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: output)
    await model.stop(); await reopened.stop()
}
