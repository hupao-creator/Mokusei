import MokuseiCore
import MokuseiPluginAPI
import XCTest

@testable import MokuseiHarnessOpenCode

final class OpenCodeAgentReadingTests: XCTestCase {
  func testFinalReplyIdentityUsesOrderedTextParts() throws {
    let message = try OpenCodeMessage(
      .object([
        "id": .text("final"),
        "executionId": .text("target"),
        "role": .text("assistant"),
        "status": .text("complete"),
        "text": .text(""),
        "parts": .array([
          .object(["type": .text("reasoning"), "ordinal": .number(0), "text": .text("hidden")]),
          .object([
            "type": .text("text"), "ordinal": .number(1), "text": .text("VISIBLE_FINAL_REPLY"),
          ]),
        ]),
      ]))
    XCTAssertEqual(message.readingText, "VISIBLE_FINAL_REPLY")
    let replies = ocFinalReplyIDs([message], sessionID: nil, splitTurns: false)
    XCTAssertTrue(replies.contains(message.id))
    for parts in [nil, []] as [[JSONValue]?] {
      var raw = message.raw.objectValue!
      raw["text"] = .text("AGGREGATE_ONLY_REPLY")
      raw["parts"] = parts.map { .array($0) }
      let aggregate = try OpenCodeMessage(.object(raw))
      XCTAssertEqual(aggregate.readingText, "AGGREGATE_ONLY_REPLY")
      XCTAssertTrue(ocFinalReplyIDs([aggregate], sessionID: nil, splitTurns: false).contains(aggregate.id))
    }

  }

  func testReadingTextKeepsInterleavedTextPartOrder() throws {
    let message = try OpenCodeMessage(
      .object([
        "id": .text("final"),
        "executionId": .text("target"),
        "role": .text("assistant"),
        "status": .text("complete"),
        "text": .text("stale aggregate must not win"),
        "parts": .array([
          .object(["type": .text("text"), "ordinal": .number(0), "text": .text("first ")]),
          .object(["type": .text("reasoning"), "ordinal": .number(1), "text": .text("hidden")]),
          .object(["type": .text("text"), "ordinal": .number(2), "text": .text("second")]),
        ]),
      ]))
    XCTAssertEqual(message.readingText, "first second")
  }
}
