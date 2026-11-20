import Foundation
import MokuseiApplications
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI
import Testing
@testable import MokuseiUI

private struct RegroupingCase: Codable {
    struct Visit: Codable {
        let seat: Int
        let seconds: Int
    }
    let seed: UInt64
    let reports: Int
    var panels: [[Visit]]

    init(seed: UInt64) {
        var random = SplitMix64(seed: seed)
        self.seed = seed
        reports = random.integer(9...12)
        panels = (0..<random.integer(1...2)).map { _ in
            (0..<random.integer(1...3)).map { _ in
                Visit(seat: random.integer(0...4), seconds: random.integer(1...7))
            }
        }
    }

    @MainActor func violation() throws -> String? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = DesktopPreferences(directory: directory)
        try preferences.setOnboardingCompleted(true)
        let workspace = NativeWorkspaceModel(client: RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory)),
            preferences: preferences, plugins: try .init(harnesses: [], sidecards: [], applications: NativeApplicationModules.make()))
        let host = NativeWorkspacePresentation(workspace: workspace)
        let model = host.overview
        let now = Date()
        let refs = (0..<reports).map { ApplicationThreadRef(threadID: JSONText("report-\($0)"), typeID: "report.document") }
        let records: [JSONValue] = refs.enumerated().map { index, ref in
            let time = now.addingTimeInterval(Double(index) - 60).timeIntervalSince1970 * 1000
            return .object(["id": .string(ref.threadID), "ref": ref.json, "revision": .integer(1),
                "createdAt": .number(time), "updatedAt": .number(time), "title": .string(ref.threadID),
                "archived": .bool(false), "scope": .text("/collection"), "presentations": .array([]),
                "tags": .object(["tags": .array([]), "semanticTags": .array([]), "directoryTags": .array([]), "tagEmojis": .object([:])]),
                "view": .object(["coverRevision": .text("cover"), "emoji": .text("📕"), "shortDescription": .text("Report"),
                    "previewText": .text("Report"), "readingSeconds": .integer(20), "contentRevision": .text("body"),
                    "relatedExecutions": .array([])])])
        }
        let snapshot = JSONValue.object(["revision": .integer(1), "settingsRevision": .integer(0),
            "defaultCwd": .text("/collection"), "settings": .object([:]), "threads": .array([]),
            "executions": .array([]), "applicationThreads": .array(records)])
        try workspace.catalog.install(snapshot)
        model.receive(.snapshot(snapshot, authority: UUID()))

        func members() -> [ApplicationThreadRef] {
            model.items.compactMap { item -> [ApplicationThreadRef]? in
                guard case .collection(_, let entries) = model.snapshot(for: item) else { return nil }
                return entries.map(\.entry.ref)
            }.flatMap { $0 }
        }
        // Nine to twelve 2-cell reports leave seven singles beside the group.
        // At most six visits qualify, so fresh alternatives are always available.
        let seats = reports - 7
        var seen = Set<ApplicationThreadRef>(), qualified = Set<ApplicationThreadRef>()
        var clock = 0.0
        for visits in panels {
            let initial = members()
            guard initial == Array(refs.filter { !qualified.contains($0) }.prefix(seats)) else { return "initial projection" }
            let panel = host.collectionPanel, owner = UUID()
            panel.present(owner: owner, source: .init(), content: AnyView(EmptyView()), onDismiss: { _ in })
            for visit in visits {
                let ref = initial[visit.seat % seats]
                panel.openMember(ref, source: .init()) { host.open(ref) }
                guard panel.readingMember == ref, host.selected == ref else { return "member origin" }

                // Drive only the foreground clock. Projection and panel lifecycle
                // use the production catalog, route admission, Back and dismissal.
                model.recordApplicationOpen(ref, at: now.addingTimeInterval(clock), uptime: clock)
                model.updateApplicationReading(visible: true, uptime: clock)
                clock += Double(visit.seconds)
                model.updateApplicationReading(visible: false, uptime: clock)
                guard members() == initial else { return "regrouped during reading" }
                model.recordApplicationClose(at: now.addingTimeInterval(clock), uptime: clock)
                host.finishBack()
                if visit.seconds >= 5 || seen.contains(ref) { qualified.insert(ref) }
                seen.insert(ref)
                let stored = preferences.applicationCollectionReading["report.document:" + ref.threadID.string]
                guard stored?.lastClosedAt != nil, (stored?.lastQualifiedAt != nil) == qualified.contains(ref) else {
                    return "reading evidence"
                }
                guard panel.owner == owner, host.browsingCollection, members() == initial else { return "regrouped on Back" }
                clock += 1
            }
            // Native travel completes the accepted close by retiring this visit.
            panel.close(owner: owner)
            guard members() == initial else { return "regrouped before dismissal completed" }
            panel.retire()
            let expected = refs.filter { !qualified.contains($0) }.prefix(seats)
            guard members() == Array(expected) else { return "projection after dismissal" }
        }
        return nil
    }

    @MainActor func reduced(_ failure: String, within seconds: Int) throws -> Self {
        var best = self
        let deadline = ContinuousClock.now + .seconds(seconds)
        for panel in panels.indices.reversed() {
            for visit in panels[panel].indices.reversed() {
                if ContinuousClock.now >= deadline { return best }
                var next = best
                next.panels[panel].remove(at: visit)
                if try next.violation() == failure { best = next }
            }
            var next = best
            next.panels.remove(at: panel)
            if try next.violation() == failure { best = next }
        }
        return best
    }
}

@Suite(.serialized) struct NativeCollectionRegroupingProperties {
    @Test @MainActor func regroupAfterPanelDismissal() throws {
        let budget = try PropertyBudget(defaultCases: 64)
        let replay = try propertyReplay(RegroupingCase.self)
        let cases = replay.map { [$0] } ?? (0..<budget.cases).map { RegroupingCase(seed: budget.seed &+ UInt64($0)) }
        for input in cases {
            if let failure = try input.violation() {
                try propertyEvidence(input, name: "original.json")
                let reduced = try input.reduced(failure, within: budget.shrinkSeconds)
                try propertyEvidence(reduced, name: "reduced.json")
                Issue.record(Comment(rawValue: "PBT-COLLECTION-REGROUP seed=\(input.seed) \(failure) reduced=\(reduced)"))
                return
            }
        }
        print("PBT PASS PBT-COLLECTION-REGROUP seed=\(budget.seed) cases=\(cases.count) replay=\(replay != nil)")
    }
}
