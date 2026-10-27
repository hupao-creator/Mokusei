import Foundation
import XCTest
import MokuseiCore
import MokuseiPluginAPI
@testable import MokuseiHarnessPi

final class PiTokenUsageTests: XCTestCase {
    @MainActor func testGoUsageProjectionsReachNativeCardAndExecutionUsage() async throws {
        guard let path = ProcessInfo.processInfo.environment["MOKUSEI_PI_USAGE_FIXTURES"] else {
            throw XCTSkip("Missing MOKUSEI_PI_USAGE_FIXTURES (60 Go usage projections). Run ./scripts/go.sh run -race ./tools/verification/pi -swift-usage -timeout 10m")
        }
        let wire = try JSONValue(data: Data(contentsOf: URL(fileURLWithPath: path)))
        let fixtures = try XCTUnwrap(wire.arrayValue)
        XCTAssertEqual(fixtures.count, 60)
        let plugin = PiHarnessPlugin()
        for fixture in fixtures {
            let name = try XCTUnwrap(fixture["name"]?.stringValue)
            let raw = try XCTUnwrap(fixture["state"], name)
            let id = JSONText(try XCTUnwrap(fixture["executionId"]?.stringValue, name))
            let expected = fixture["expected"]?.numberValue
            let state = try PiState(raw)
            let observation = ThreadPublicObservation(latestExecution:
                state.executions.first { $0.executionID == state.latestExecutionID })
            let thread = try HarnessThread(id: "usage", harnessID: "pi", revision: 1, sessionState: raw,
                observation: observation, cwd: "/fixture", settings: .object([:]),
                createdAt: 1, updatedAt: 1, title: "Usage replay", tags: [])
            let usage = try plugin.executionTokenUsage(thread: thread, executionID: id)
            XCTAssertEqual(usage?.count, expected, name)
            // PiTurn's footer consumes this same execution total, including cache.
            XCTAssertEqual(state.executionUsage[id]?.total, expected, name)
            if id == state.latestExecutionID {
                let card = try plugin.projectOverview(input: .init(thread: thread), availableColumns: 3)
                let part = card.view.presentation.projection.identity?.usage?.parts.first
                XCTAssertEqual(part?.numericValue, expected, name)
                XCTAssertEqual(part?.value, expected.map(piCompactTokens), name)
            }
        }
        print("PASS Pi usage fixtures: \(fixtures.count)")
    }
}
