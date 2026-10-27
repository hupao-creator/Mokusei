import Foundation
import XCTest
import MokuseiCore

final class IntegerWireTests: XCTestCase {
    private func decode(_ token: String) throws -> JSONValue {
        try JSONValue(data: Data(token.utf8))
    }

    func testIntegerEncodingRetainsExactValuesAndRejectsNarrowingOverflow() throws {
        let values: [Int] = [0, 1, -1, 9_007_199_254_740_991, 9_007_199_254_740_993, Int.max, Int.min]
        for integer in values {
            let value = JSONValue.integer(integer)
            let data = try value.encodedData()
            XCTAssertEqual(String(decoding: data, as: UTF8.self), String(integer))
            XCTAssertEqual(try JSONValue(data: data).intValue, integer)
            XCTAssertEqual(try JSONValue(data: data), value)
        }
        let unsigned = JSONValue.integer(UInt64.max)
        XCTAssertEqual(String(decoding: try unsigned.encodedData(), as: UTF8.self), "18446744073709551615")
        XCTAssertNil(try decode("18446744073709551615").intValue)
        XCTAssertEqual(try decode("18446744073709551615"), unsigned)
        XCTAssertNil(try decode("9223372036854775808").intValue)
        XCTAssertNil(try decode("-9223372036854775809").intValue)
        // A rounded Double must not be clamped or cast to a different integer.
        XCTAssertEqual(String(decoding: try JSONValue.number(Double(Int.max)).encodedData(), as: UTF8.self),
                       "9223372036854775808")
    }

    func testWholeDoublesUseIntegerTokensAndFractionsRemainNumbers() throws {
        for (value, expected) in [(0.0, "0"), (1.0, "1"), (-1.0, "-1"), (1e20, "100000000000000000000"),
                                  (1e23, "99999999999999991611392")] {
            XCTAssertEqual(String(decoding: try JSONValue.number(value).encodedData(), as: UTF8.self), expected)
        }
        for token in ["0.125", "-3.75", "1e-7", "1.25e2", "-0", "-0.0"] {
            let value = try decode(token)
            let next = try JSONValue(data: value.encodedData())
            XCTAssertEqual(value, next, token)
            XCTAssertEqual(value.numberValue?.sign, next.numberValue?.sign, token)
        }
        let huge = JSONValue.number(1e100)
        XCTAssertEqual(try JSONValue(data: huge.encodedData()), huge)
        XCTAssertEqual(try decode("1"), .number(1))
        XCTAssertEqual(Set([try decode("1"), .number(1)]).count, 1)
        XCTAssertNotEqual(try decode("9007199254740993"), .number(9_007_199_254_740_992))
        for invalid in ["01", "1.", "1e", "+1", "1e999", "NaN", "Infinity"] {
            XCTAssertThrowsError(try decode(invalid), invalid)
        }
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try JSONValue.number(value).encodedData())
        }
    }

    func testOpaqueIntegerPayloadsSurviveStateDeltaAndReencoding() throws {
        let original = try decode(#"{"opaque":[9007199254740993,9223372036854775807,18446744073709551615],"text":"old"}"#)
        let patch = try decode(#"[{"op":"replace","path":["text"],"value":"new"}]"#)
        let updated = try JSONDelta.apply(patch, to: original)
        XCTAssertEqual(updated["opaque"], original["opaque"])
        XCTAssertEqual(String(decoding: try XCTUnwrap(updated["opaque"]).encodedData(), as: UTF8.self),
                       "[9007199254740993,9223372036854775807,18446744073709551615]")
    }

    // Go launches this test and consumes the bytes, rather than recreating the
    // payload with encoding/json (which hid this bug in older Go-only replays).
    func testExportActualSwiftRequestsToGo() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["MOKUSEI_SWIFT_INTEGER_REQUESTS"],
              let threadID = environment["MOKUSEI_SWIFT_VOICE_THREAD"] else {
            throw XCTSkip("Missing MOKUSEI_SWIFT_INTEGER_REQUESTS / MOKUSEI_SWIFT_VOICE_THREAD (Go request-export fixture). Run ./scripts/go.sh run -race ./tools/verification/runtime -swift-voice")
        }
        let sessionID = "11111111-1111-4111-8111-111111111111"
        func voice(_ name: String, _ fields: [JSONText: JSONValue]) -> JSONValue {
            .object(["name": .text(name), "channel": .text(fields["action"] == .text("poll") || fields["action"] == .text("history") ? "thread:voice-events" : "thread:voice"),
                     "args": .array([.object(["threadId": .text(threadID), "request": .object(fields)])])])
        }
        let commands: [JSONValue] = [
            voice("history", ["action": .text("history")]),
            voice("prepare", ["action": .text("prepare"), "requestId": .text(sessionID)]),
            // Keep a legacy Double construction too: the shared encoder must
            // fix all existing whole-valued number callers, not only one field.
            voice("initial poll", ["action": .text("poll"), "sessionId": .text(sessionID), "ownershipId": .text(sessionID), "after": .number(0)]),
            voice("start", ["action": .text("start"), "sessionId": .text(sessionID), "ownershipId": .text(sessionID), "sdp": .text("fixture-offer")]),
            voice("events", ["action": .text("poll"), "sessionId": .text(sessionID), "ownershipId": .text(sessionID), "after": .integer(0)]),
            voice("advanced poll", ["action": .text("poll"), "sessionId": .text(sessionID), "ownershipId": .text(sessionID), "after": .integer(1)]),
            voice("max cursor", ["action": .text("poll"), "sessionId": .text(sessionID), "ownershipId": .text(sessionID), "after": .integer(RuntimeProtocol.maximumSafeInteger)]),
            voice("stop", ["action": .text("stop"), "sessionId": .text(sessionID), "ownershipId": .text(sessionID)]),
            voice("retired poll", ["action": .text("poll"), "sessionId": .text(sessionID), "ownershipId": .text(sessionID), "after": .integer(2)])
        ]
        let integerFields = ["after", "draftRevision", "expectedSettingsRevision", "revision", "metadataRevision"]
        let contracts: [JSONValue] = [0, 1, 9_007_199_254_740_993, Int.max, Int.min].map { integer in
            .object(Dictionary(uniqueKeysWithValues: integerFields.map { (JSONText($0), .integer(integer)) }))
        }
        let wire = JSONValue.object(["commands": .array(commands), "contracts": .array(contracts)])
        try wire.encodedData().write(to: URL(fileURLWithPath: output))
        print("PASS Swift integer requests exported")
    }
}
