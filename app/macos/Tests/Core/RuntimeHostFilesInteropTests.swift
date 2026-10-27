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
        let connection = try XCTUnwrap(profile.readConnection())
        let directory = profile.dataDirectory.appendingPathComponent("selected-files", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let client = RuntimeClient(profile: profile)
        do {
            try await client.start()
            let regular = directory.appendingPathComponent("regular.bin")
            let expected = Data(String(repeating: "file boundary fixture\n", count: 10_000).utf8)
            try expected.write(to: regular)
            let symlink = directory.appendingPathComponent("symlink.bin")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: regular)
            for file in [regular, symlink] {
                let uploaded = try await client.uploadAttachment(file: file, name: file.lastPathComponent)
                XCTAssertEqual(uploaded["name"]?.stringValue, file.lastPathComponent)
                XCTAssertEqual(uploaded["size"]?.intValue, expected.count)
                XCTAssertEqual(uploaded["id"]?.stringValue, "fixture-" + file.lastPathComponent)
            }

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
        } catch {
            await client.close()
            throw error
        }
        await client.close()
        print("PASS native host file boundaries")
    }
}
