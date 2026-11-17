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

}
