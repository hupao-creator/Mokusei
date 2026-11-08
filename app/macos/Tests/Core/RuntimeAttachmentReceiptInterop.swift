import Foundation
import XCTest
import MokuseiCore

private let attachmentReceiptFixture = "verification-attachment-receipt.json"

/// Extends the authenticated file replay with a receipt that has no Thread owner.
func holdUncertainAttachment(client: RuntimeClient, profile: RuntimeProfile, file: JSONValue) async throws {
    let id = try XCTUnwrap(file["id"]?.stringValue)
    let path = try XCTUnwrap(file["path"]?.stringValue)
    let other = RuntimeClient(profile: profile)
    do {
        // This actor restores before the first client creates its receipt, so
        // rewriting its cached journal would silently discard that new owner.
        try await other.start()
        let attachmentReceiptID = "\(Int64(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.lowercased())"
        let input: JSONValue = .object(["parts": .array([
            .object(["kind": .text("local-file"), "file": .object(["id": .text(id)])])
        ])])
        do {
            _ = try await client.invoke("moku:submit", args: [.object(["input": input])],
                receiptID: attachmentReceiptID, retainingReceipt: true)
            XCTFail("The fixture must return uncertainty before retaining Thread input")
        } catch let error as RuntimeError {
            XCTAssertEqual(error.code, "COMMAND_OUTCOME_UNCERTAIN")
            XCTAssertTrue(error.kind == .uncertain)
            XCTAssertEqual(error.receiptID, attachmentReceiptID)
        }
        let outcomes = await client.commandOutcomes()
        XCTAssertTrue(outcomes.contains { $0.commandID == attachmentReceiptID })
        _ = try await client.invoke("attachment:discard", args: [.array([.text(id)])])
        _ = try await other.invoke("application:command", args: [.text("attachments:collect")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                      "An uncertain receipt must retain its file after another client writes the shared journal")
        let journal = try JSONValue(data: Data(contentsOf: profile.dataDirectory.appendingPathComponent("client-command-journal.json")))
        let record = try XCTUnwrap(journal["records"]?.arrayValue?.first { $0["id"]?.stringValue == attachmentReceiptID })
        XCTAssertEqual(record["attachmentIDs"], .array([.text(id)]))
        let metadata = try JSONValue.object(["attachment": file, "receiptID": .text(attachmentReceiptID)]).encodedData()
        try metadata.write(to: profile.dataDirectory.appendingPathComponent(attachmentReceiptFixture), options: .atomic)
    } catch {
        await other.close()
        throw error
    }
    await other.close()
    print("PASS native uncertain attachment receipt retained")
}

func releaseUncertainAttachment(client: RuntimeClient, profile: RuntimeProfile) async throws {
    let metadataURL = profile.dataDirectory.appendingPathComponent(attachmentReceiptFixture)
    let metadata = try JSONValue(data: Data(contentsOf: metadataURL))
    let attachmentReceiptID = try XCTUnwrap(metadata["receiptID"]?.stringValue)
    let path = try XCTUnwrap(metadata["attachment"]?["path"]?.stringValue)
    let outcomes = await client.commandOutcomes()
    XCTAssertTrue(outcomes.contains { $0.commandID == attachmentReceiptID },
                  "The receipt must survive the original native process")
    _ = try await client.invoke("application:command", args: [.text("attachments:collect")])
    XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                  "Restoring and looking up a receipt must not release its attachment")
    let other = RuntimeClient(profile: profile)
    do {
        try await other.start()
        try await other.acknowledgeCommandOutcome(attachmentReceiptID)
        // The first actor still cached this receipt before the other client
        // consumed it. A later lookup must not recreate its retired owner.
        do {
            _ = try await client.resolveCommandReceipt(attachmentReceiptID)
            XCTFail("The fixture receipt must remain uncertain")
        } catch let error as RuntimeError { XCTAssertTrue(error.kind == .uncertain) }
        let remaining = await client.commandOutcomes()
        XCTAssertFalse(remaining.contains { $0.commandID == attachmentReceiptID })
        _ = try await other.invoke("application:command", args: [.text("attachments:collect")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                       "Acknowledgement releases ownership even after a stale client looks up the receipt")
        let journal = try JSONValue(data: Data(contentsOf: profile.dataDirectory.appendingPathComponent("client-command-journal.json")))
        XCTAssertEqual(journal["records"], .array([]), "The empty ownership journal must encode an array, not null")
    } catch {
        await other.close()
        throw error
    }
    await other.close()
    try FileManager.default.removeItem(at: metadataURL)
    print("PASS native uncertain attachment receipt released")
}
