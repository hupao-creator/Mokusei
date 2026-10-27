import Foundation
import XCTest
import MokuseiCore

final class RuntimeShutdownInteropTests: XCTestCase {
    private struct ProfileIdentityManifest: Decodable {
        struct Case: Decodable {
            let selectedDirectory: String
            let homeDirectory: String
            let dataDirectory: String
            let workspaceRoot: String
        }
        let cases: [Case]
        let liveDirectory: String
        let precreationAlias: String
        let homeDirectory: String
    }

    func testCanonicalProfileIdentity() async throws {
        guard let path = ProcessInfo.processInfo.environment["MOKUSEI_PROFILE_IDENTITY_MANIFEST"] else {
            throw XCTSkip("Missing MOKUSEI_PROFILE_IDENTITY_MANIFEST (canonical path fixtures). Run ./scripts/go.sh run -race ./tools/verification/runtime-helpers --swift-shutdown")
        }
        let manifest = try JSONDecoder().decode(ProfileIdentityManifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertFalse(manifest.cases.isEmpty)
        for fixture in manifest.cases {
            let profile = try RuntimeProfile(dataDirectory: URL(fileURLWithPath: fixture.selectedDirectory),
                                             homeDirectory: URL(fileURLWithPath: fixture.homeDirectory))
            XCTAssertEqual(profile.dataDirectory.path, fixture.dataDirectory)
            XCTAssertEqual(profile.workspaceRoot.path, fixture.workspaceRoot)
        }
        let alias = URL(fileURLWithPath: manifest.precreationAlias)
        let home = URL(fileURLWithPath: manifest.homeDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: alias.path))
        // Hold the production profile before its final path resolves. The Go
        // fixture remains its sole owner while the alias appears afterward.
        let selected = try RuntimeProfile(dataDirectory: alias, homeDirectory: home)
        let live = try RuntimeProfile(dataDirectory: URL(fileURLWithPath: manifest.liveDirectory), homeDirectory: home)
        let expected = try XCTUnwrap(live.readConnection())
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: live.dataDirectory)
        defer { try? FileManager.default.removeItem(at: alias) }
        XCTAssertEqual(try selected.readConnection(), expected)
        let manager = RuntimeProcessManager(profile: selected)
        let status = try await manager.status()
        XCTAssertEqual(status, expected)
        let started = try await manager.start()
        XCTAssertEqual(started, expected)
        print("PASS canonical profile fixtures: \(manifest.cases.count)")
    }

    private struct StaleDiscoveryCase: Decodable {
        let path: String
        let recoverable: Bool
        let swiftCode: String
    }

    func testStaleDiscoveryRecovery() async throws {
        guard let path = ProcessInfo.processInfo.environment["MOKUSEI_STALE_DISCOVERY_CASES"] else {
            throw XCTSkip("Missing MOKUSEI_STALE_DISCOVERY_CASES (dead/live owner fixtures). Run ./scripts/go.sh run -race ./tools/verification/runtime-helpers --swift-shutdown")
        }
        let fixtures = try JSONDecoder().decode([StaleDiscoveryCase].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(fixtures.count, 10)
        for fixture in fixtures {
            let profile = try RuntimeProfile(dataDirectory: URL(fileURLWithPath: fixture.path))
            let manager = RuntimeProcessManager(profile: profile)
            if fixture.recoverable {
                let current = try await manager.status()
                XCTAssertNil(current, fixture.path)
                do {
                    _ = try await manager.start()
                    XCTFail("Dead owner was reused: \(fixture.path)")
                } catch let error as RuntimeError {
                    XCTAssertEqual(error.code, "LAUNCH_UNAVAILABLE", fixture.path)
                }
                try await manager.stop()
            } else {
                for operation in 0..<3 {
                    do {
                        switch operation {
                        case 0: _ = try await manager.status()
                        case 1: _ = try await manager.start()
                        default: try await manager.stop()
                        }
                        XCTFail("Live or invalid discovery was ignored: \(fixture.path)")
                    } catch let error as RuntimeError {
                        XCTAssertEqual(error.code, fixture.swiftCode, fixture.path)
                    }
                }
            }
            // Gate task entry so cancellation is established before the real
            // manager reads metadata, including the dead-owner fixtures.
            let gate = AsyncStream<Void>.makeStream()
            let canceled = Task {
                for await _ in gate.stream {}
                return try await manager.status()
            }
            canceled.cancel()
            gate.continuation.finish()
            do {
                _ = try await canceled.value
                XCTFail("Canceled status became an absent owner: \(fixture.path)")
            } catch is CancellationError {}
        }
        print("PASS stale discovery fixtures: \(fixtures.count)")
    }

    func testReopenAfterFailedShutdown() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["MOKUSEI_SHUTDOWN_PROFILE"],
              let executable = environment["MOKUSEI_SHUTDOWN_RUNTIME"],
              let gate = environment["MOKUSEI_SHUTDOWN_GATE"] else {
            throw XCTSkip("Missing MOKUSEI_SHUTDOWN_PROFILE / MOKUSEI_SHUTDOWN_RUNTIME / MOKUSEI_SHUTDOWN_GATE (owned runtime and shutdown gate). Run ./scripts/go.sh run -race ./tools/verification/runtime-helpers --swift-shutdown")
        }
        let profile = try RuntimeProfile(dataDirectory: URL(fileURLWithPath: path))
        let original = try XCTUnwrap(profile.readConnection())
        let manager = RuntimeProcessManager(profile: profile,
            launch: RuntimeLaunchConfiguration(executable: URL(fileURLWithPath: executable)))
        do { _ = try await manager.status(); XCTFail("Retiring runtime was available") }
        catch let error as RuntimeError { XCTAssertEqual(error.code, "SERVICE_STOPPING") }
        let reopening = Task { try await manager.start() }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(try profile.readConnection()?.epoch, original.epoch)
        try Data().write(to: URL(fileURLWithPath: gate + ".release"))
        let replacement = try await reopening.value
        XCTAssertNotEqual(replacement.epoch, original.epoch)
        let status = try await manager.status()
        XCTAssertEqual(status, replacement)
        // An exit helper from the old app cannot stop this new generation.
        for expectedEpoch in ["", original.epoch] {
            try await manager.stop(expectedEpoch: expectedEpoch)
            XCTAssertEqual(try profile.readConnection()?.epoch, replacement.epoch)
        }
        let reused = try await manager.start()
        XCTAssertEqual(reused, replacement)
    }
}
