import Foundation
import XCTest
import MokuseiCore

final class GoDeltaInteropTests: XCTestCase {
    func testGoGeneratedDeltasReconstructNativeContent() throws {
        guard let path = ProcessInfo.processInfo.environment["MOKUSEI_GO_DELTA_FIXTURES"] else {
            throw XCTSkip("Missing MOKUSEI_GO_DELTA_FIXTURES (Go-produced deltas). Run ./scripts/go.sh run -race ./tools/verification/transport -swift-deltas")
        }
        let wire = try JSONValue(data: Data(contentsOf: URL(fileURLWithPath: path)))
        let fixtures = try XCTUnwrap(wire.arrayValue)
        XCTAssertFalse(fixtures.isEmpty, "the Go producer must supply content transitions")
        for fixture in fixtures {
            let name = try XCTUnwrap(fixture["name"]?.stringValue)
            let before = try XCTUnwrap(fixture["before"], name)
            let after = try XCTUnwrap(fixture["after"], name)
            let patch = try XCTUnwrap(fixture["patch"], name)
            do {
                let actual = try JSONDelta.apply(patch, to: before)
                XCTAssertEqual(actual, after, name)
            } catch {
                XCTFail("\(name): \(error)")
            }
        }
        print("PASS Go delta fixtures: \(fixtures.count)")
    }
}
