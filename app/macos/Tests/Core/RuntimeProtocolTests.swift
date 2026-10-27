import Foundation
import XCTest
import MokuseiCore

final class RuntimeProtocolTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue { try JSONValue(data: Data(text.utf8)) }

    func testJSONRetainsJavaScriptStringIdentityAndIsolatedSurrogates() throws {
        let value = try json(#"{"\u00e9":1,"e\u0301":2,"text":"A\ud83d\ude00B\ud800"}"#)
        XCTAssertEqual(value.objectValue?.count, 3)
        XCTAssertEqual(value.objectValue?[JSONText(codeUnits: [0xE9])], .number(1))
        XCTAssertEqual(value.objectValue?[JSONText(codeUnits: [0x65, 0x301])], .number(2))
        XCTAssertEqual(value["text"], .string(JSONText(codeUnits: [0x41, 0xD83D, 0xDE00, 0x42, 0xD800])))
        let encoded = try value.encodedData()
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("\\ud800"))
        XCTAssertEqual(try JSONValue(data: encoded), value)
    }

    func testDeltaUsesUTF16OffsetsAndKeepsEditsWhenArrayElementsMove() throws {
        let original = try json(#"{"rows":[{"text":"A😀B"},{"text":"second"}],"note":"keep"}"#)
        let patch = try json(#"""
        [
        {"op":"text","path":["rows",0,"text"],"index":2,"deleteCount":1,"text":"\ude01"},
        {"op":"splice","path":["rows"],"index":0,"deleteCount":0,"values":[{"text":"inserted"}]},
        {"op":"replace","path":["rows",2,"text"],"value":"last"},
        {"op":"add","path":["temporary"],"value":true},
        {"op":"remove","path":["temporary"]}
        ]
        """#)
        XCTAssertEqual(try JSONDelta.apply(patch, to: original),
            try json(#"{"rows":[{"text":"inserted"},{"text":"A😁B"},{"text":"last"}],"note":"keep"}"#))
        XCTAssertEqual(original["rows"]?.arrayValue?.first?["text"], .text("A😀B"))
    }

    func testFailedDeltaDiscardsEarlierOperationsAndAllowsCleanRetry() throws {
        let original = try json(#"{"text":"abc","items":[1,2]}"#)
        let invalid = try json(#"""
        [
        {"op":"text","path":["text"],"index":3,"deleteCount":0,"text":"!"},
        {"op":"splice","path":["items"],"index":1,"deleteCount":2,"values":[]}
        ]
        """#)
        XCTAssertThrowsError(try JSONDelta.apply(invalid, to: original)) { error in
            XCTAssertEqual((error as? JSONDeltaError)?.operationIndex, 1)
        }
        XCTAssertEqual(original, try json(#"{"text":"abc","items":[1,2]}"#))
        let retry = try json(#"[{"op":"text","path":["text"],"index":3,"deleteCount":0,"text":"?"}]"#)
        XCTAssertEqual(try JSONDelta.apply(retry, to: original)["text"], .text("abc?"))
        XCTAssertThrowsError(try JSONDelta.apply(
            json(#"[{"op":"replace","path":["items","0"],"value":9}]"#), to: original))
    }

    private func snapshot() throws -> JSONValue {
        try json(#"""
        {
        "revision":10,"settingsRevision":0,"defaultCwd":"/project","settings":{},"executions":[],
        "threads":[{"id":"a","revision":2,"title":"fresh","sessionState":{"opaque":[null,"😀"]}},
        {"id":"b","revision":1,"title":"other"}],
        "applicationThreads":[{"id":"shared","revision":4,"ref":{"typeId":"report"},"title":"old"}]
        }
        """#)
    }

    func testRuntimeRevisionsPreserveNewerThreadsAndReplaceChangedApplicationIdentity() throws {
        let original = try snapshot()
        let mutation = try json(#"""
        {
        "type":"state-patched","baseRevision":10,"revision":11,
        "threads":{"removedIds":["b"],"upserts":[{"id":"a","revision":1,"title":"stale"},{"id":"c","revision":0}],"order":["c","a"]},
        "applicationThreads":{"removedIds":[],"upserts":[{"id":"shared","revision":4,"ref":{"typeId":"git"},"title":"new"}]}
        }
        """#)
        let result = try RuntimeState.applying(mutation, to: original)
        XCTAssertEqual(result["threads"]?.arrayValue?.map { $0["id"] }, [.text("c"), .text("a")])
        XCTAssertEqual(result["threads"]?.arrayValue?.last, original["threads"]?.arrayValue?.first)
        XCTAssertEqual(result["applicationThreads"]?.arrayValue?.first?["title"], .text("new"))
        XCTAssertEqual(result["revision"], .number(11))
        XCTAssertEqual(try RuntimeState.applying(mutation, to: result), result)
        XCTAssertThrowsError(try RuntimeState.applying(
            json(#"{"type":"state-patched","baseRevision":12,"revision":13}"#), to: result))
        XCTAssertEqual(original["revision"], .number(10))
    }

    func testInvalidCollectionOrderCannotPublishPartialState() throws {
        let original = try snapshot()
        let duplicate = try json(#"""
        {
        "type":"state-patched","baseRevision":10,"revision":11,
        "threads":{"removedIds":["b"],"upserts":[{"id":"a","revision":3,"title":"changed"}]},
        "applicationThreads":{"removedIds":[],"upserts":[],"order":["shared","shared"]}
        }
        """#)
        XCTAssertThrowsError(try RuntimeState.applying(duplicate, to: original))
        let omitted = try json(#"""
        {
        "type":"state-patched","baseRevision":10,"revision":11,
        "threads":{"removedIds":[],"upserts":[],"order":["a"]}
        }
        """#)
        XCTAssertThrowsError(try RuntimeState.applying(omitted, to: original))
        XCTAssertEqual(original, try snapshot())
    }
}
