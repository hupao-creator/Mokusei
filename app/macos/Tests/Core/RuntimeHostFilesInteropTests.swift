import CryptoKit
import Darwin
import Foundation
import XCTest
import MokuseiCore

/// Launched by transport -swift-files with a real authenticated Go file host.
final class RuntimeHostFilesInteropTests: XCTestCase {
    func testNativeUploadsAndDownloadsCrossTheGoTransportBoundary() async throws {
        guard let path = ProcessInfo.processInfo.environment["MOKUSEI_SWIFT_FILES_PROFILE"] else {
            throw XCTSkip("Missing MOKUSEI_SWIFT_FILES_PROFILE (authenticated Go file host). Run ./scripts/go.sh run -race ./tools/verification/transport -swift-files")
        }
        let profile = try RuntimeProfile(dataDirectory: URL(fileURLWithPath: path))
        if ProcessInfo.processInfo.environment["MOKUSEI_SWIFT_FILES_PHASE"] == "consume" {
            try await consumeRestartedDraft(profile)
            return
        }
        let connection = try XCTUnwrap(profile.readConnection())
        let directory = profile.dataDirectory.appendingPathComponent("selected-files", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let client = RuntimeClient(profile: profile)
        do {
            try await client.start()
            let listing = try await client.hostDirectory()
            XCTAssertEqual(listing.entries.map(\.name), ["target.txt", "alias-a", "alias-b"])
            XCTAssertEqual(Set(listing.entries.map(\.id)).count, 3, "Each named directory entry needs a stable UI identity")
            XCTAssertEqual(Set(listing.entries.map { $0.reference.path }).count, 1, "Aliases retain the same authenticated target")
            let reloaded = try await client.hostDirectory(listing.reference)
            XCTAssertEqual(reloaded.entries.map(\.id), listing.entries.map(\.id))
            let regular = directory.appendingPathComponent("regular.bin")
            let expected = Data(String(repeating: "file boundary fixture\n", count: 10_000).utf8)
            try expected.write(to: regular)
            let symlink = directory.appendingPathComponent("symlink.bin")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: regular)
            var uploadedFiles: [JSONValue] = []
            for file in [regular, symlink] {
                let uploaded = try await client.uploadAttachment(file: file, name: file.lastPathComponent)
                XCTAssertEqual(uploaded["name"]?.stringValue, file.lastPathComponent)
                XCTAssertEqual(uploaded["size"]?.intValue, expected.count)
                let id = try XCTUnwrap(uploaded["id"]?.stringValue)
                XCTAssertNotNil(UUID(uuidString: id))
                XCTAssertEqual(id, id.lowercased())
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(uploaded["path"]?.stringValue))), expected)
                uploadedFiles.append(uploaded)
            }
            let inline = try await client.invoke("moku:stage-attachments", args: [.array([.object([
                "source": .text("bytes"), "displayName": .text("inline.txt"),
                "bytes": .object(["$mokuseiArrayBuffer": .text(Data("inline fixture".utf8).base64EncodedString())])
            ])])])
            let inlineFile = try XCTUnwrap(inline.arrayValue?.first)
            let stagedFiles = uploadedFiles + [inlineFile]
            _ = try await client.invoke("application:command", args: [.text("attachments:collect")])
            for file in stagedFiles {
                XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(file["path"]?.stringValue)),
                              "An active process lease must protect Stage-to-draft handoff")
            }
            let saved = try XCTUnwrap(uploadedFiles.first)
            let savedID = try XCTUnwrap(saved["id"]?.stringValue)
            let drafts = RuntimeDraftStore(storageDirectory: profile.dataDirectory, scope: "native-attachment-ownership")
            try drafts.save(.object(["attachment": saved]), attachmentIDs: [JSONText(savedID)])
            _ = try await client.invoke("attachment:discard", args: [.array([.text(savedID)])])
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(saved["path"]?.stringValue)),
                          "Releasing staging must preserve the atomic draft reference")

            let fifo = directory.appendingPathComponent("blocked.fifo")
            XCTAssertEqual(fifo.path.withCString { mkfifo($0, 0o600) }, 0)
            let fifoLink = directory.appendingPathComponent("linked.fifo")
            try FileManager.default.createSymbolicLink(at: fifoLink, withDestinationURL: fifo)
            for file in [fifo, fifoLink] {
                // An old blocking-open implementation must fail this assertion
                // without leaving a suspended task behind in the test process.
                let unblock = Task.detached {
                    try await Task.sleep(for: .seconds(3))
                    let descriptor = fifo.path.withCString { Darwin.open($0, O_RDWR | O_NONBLOCK | O_CLOEXEC) }
                    guard descriptor >= 0 else { return }
                    defer { Darwin.close(descriptor) }
                    try await Task.sleep(for: .seconds(10))
                }
                defer { unblock.cancel() }
                let started = ContinuousClock.now
                do {
                    _ = try await client.uploadAttachment(file: file, name: file.lastPathComponent)
                    XCTFail("A FIFO must not be uploaded")
                } catch let error as RuntimeError {
                    XCTAssertEqual(error.code, "INVALID_FILE")
                }
                XCTAssertLessThan(started.duration(to: .now), .seconds(2), "A FIFO must be rejected before a writer opens it")
            }
            let transfers = profile.dataDirectory.appendingPathComponent("transfers", isDirectory: true)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: transfers.path), [])

            let downloadBytes = Data("download fixture\0includes binary bytes\n".utf8)
            let digest = SHA256.hash(data: downloadBytes).map { String(format: "%02x", $0) }.joined()
            for name in ["ordinary.bin", ".partial"] {
                let downloaded = try await client.downloadHostFile(.init(hostID: "local:" + connection.epoch, path: name))
                XCTAssertEqual(downloaded.name, name)
                XCTAssertEqual(downloaded.url.lastPathComponent, name)
                XCTAssertEqual(downloaded.size, downloadBytes.count)
                XCTAssertEqual(downloaded.sha256, digest)
                XCTAssertEqual(downloaded.mimeType, "application/octet-stream")
                XCTAssertEqual(try Data(contentsOf: downloaded.url), downloadBytes)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloaded.url.deletingLastPathComponent().path), [name])
            }
            try await holdUncertainAttachment(client: client, profile: profile, file: inlineFile)
            await client.close()
            let reopened = RuntimeClient(profile: profile)
            do {
                try await reopened.start()
                _ = try await reopened.invoke("application:command", args: [.text("attachments:reopen")])
                for file in stagedFiles {
                    XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(file["path"]?.stringValue)),
                                  "Client close and repository reopen must preserve drafts and live process leases")
                }
            } catch {
                await reopened.close()
                throw error
            }
            await reopened.close()
        } catch {
            await client.close()
            throw error
        }
        await client.close()
        print("PASS native host file boundaries")
    }

    private func consumeRestartedDraft(_ profile: RuntimeProfile) async throws {
        let drafts = RuntimeDraftStore(storageDirectory: profile.dataDirectory, scope: "native-attachment-ownership")
        let retained = try drafts.loadRetainingAttachments()
        let successor = try drafts.loadRetainingAttachments()
        defer { try? retained.owner.release(); try? successor.owner.release() }
        let saved = try XCTUnwrap(retained.value?["attachment"])
        let path = try XCTUnwrap(saved["path"]?.stringValue)
        let id = try XCTUnwrap(saved["id"]?.stringValue)
        let sending = try retained.owner.capture([JSONText(id)])
        defer { try? sending.release() }
        let client = RuntimeClient(profile: profile)
        do {
            try await client.start()
            _ = try await client.invoke("application:command", args: [.text("attachments:collect")])
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "Saved attachment must survive the original client process")
            try drafts.save(.object(["consumed": .bool(true)]))
            try retained.owner.release()
            _ = try await client.invoke("application:command", args: [.text("attachments:collect")])
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "A second restored draft owns its independent reference")
            try successor.owner.release()
            _ = try await client.invoke("application:command", args: [.text("attachments:collect")])
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "A pending submission survives both draft owners")
            try sending.release()
            _ = try await client.invoke("application:command", args: [.text("attachments:collect")])
            XCTAssertFalse(FileManager.default.fileExists(atPath: path), "Removing the final draft reference must permit collection")
            try await releaseUncertainAttachment(client: client, profile: profile)
        } catch {
            await client.close()
            throw error
        }
        await client.close()
        print("PASS native attachment draft restart")
    }
}
