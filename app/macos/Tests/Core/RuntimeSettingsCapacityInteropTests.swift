import Foundation
import XCTest
import MokuseiCore

/// Run by transport -swift-settings-capacity against real Go HTTP admission.
final class RuntimeSettingsCapacityInteropTests: XCTestCase {
    func testColdSettingsBurstAndCancellation() async throws {
        guard let path = ProcessInfo.processInfo.environment["MOKUSEI_SWIFT_SETTINGS_PROFILE"] else {
            throw XCTSkip("Missing MOKUSEI_SWIFT_SETTINGS_PROFILE (Go HTTP admission fixture). Run ./scripts/go.sh run -race ./tools/verification/transport -swift-settings-capacity")
        }
        let profile = try RuntimeProfile(dataDirectory: URL(fileURLWithPath: path))
        let client = RuntimeClient(profile: profile)
        do {
            try await client.start()
            // The workspace starts four scopes and installation detection per
            // Harness. Keep discovery slow past the reported 5–8 second visit.
            try await withThrowingTaskGroup(of: Void.self) { group in
                for harness in ["pi", "codex", "claude", "opencode"] {
                    for owner in ["global", "moku", "report.settings", "tag.settings"] {
                        group.addTask {
                            let result = try await client.invoke("harness:settings-presentation", args: [.object([
                                "harnessId": .text(harness), "owner": .text(owner), "phase": .text("cold")
                            ])])
                            XCTAssertEqual(result["harnessId"], .text(harness))
                        }
                    }
                    group.addTask {
                        _ = try await client.invoke("harness:detect-installation", args: [.text(harness)])
                    }
                }
                // Discovery must leave ordinary commands responsive while its
                // own backlog waits; this is also the first Settings visit.
                try await Task.sleep(for: .seconds(5))
                let stateStarted = ContinuousClock.now
                let state = try await client.invoke("state:load")
                XCTAssertEqual(state["revision"], .integer(1))
                XCTAssertLessThan(stateStarted.duration(to: .now), .seconds(1))
                try await group.waitForAll()
            }

            // Fill the discovery window with cancellable installation reads,
            // then retire a queued source before it can reach the host.
            let blocking = (0..<4).map { index in
                Task { try await client.invoke("harness:detect-installation", args: [.text("blocked-\(index)")]) }
            }
            try await waitFor(client, key: "blocked", count: 4)
            let obsolete = Task { try await client.invoke("harness:settings-presentation", args: [.object(["phase": .text("obsolete")])]) }
            try await Task.sleep(for: .milliseconds(100))
            obsolete.cancel()
            do { _ = try await obsolete.value; XCTFail("Queued obsolete read succeeded") }
            catch { XCTAssertTrue(error is CancellationError) }
            for task in blocking { task.cancel() }
            for task in blocking {
                do { _ = try await task.value; XCTFail("Cancelled installation read succeeded") }
                catch { XCTAssertTrue(error is CancellationError) }
            }
            try await waitFor(client, key: "cancelled", count: 4)
            let recovered = try await client.invoke("harness:settings-presentation", args: [.object(["phase": .text("recovered")])])
            XCTAssertEqual(recovered["phase"], .text("recovered"))
            let stats = try await client.invoke("application:query")
            XCTAssertEqual(stats["coldCompleted"], .integer(20))
            XCTAssertEqual(stats["obsolete"], .integer(0))
            XCTAssertEqual(stats["maximum"], .integer(4))
            XCTAssertEqual(stats["maximumPerHarness"], .integer(1))
            let unresolved = await client.uncertainReceipts()
            XCTAssertTrue(unresolved.isEmpty)

            // Full teardown must also wake queued continuations and terminate
            // active native reads, rather than retaining the closed client.
            let closing = (4..<8).map { index in
                Task { try await client.invoke("harness:detect-installation", args: [.text("blocked-\(index)")]) }
            }
            try await waitFor(client, key: "blocked", count: 8)
            let queuedAtClose = Task { try await client.invoke("harness:settings-presentation", args: [.object(["phase": .text("obsolete")])]) }
            try await Task.sleep(for: .milliseconds(100))
            await client.close()
            for task in closing + [queuedAtClose] {
                do { _ = try await task.value; XCTFail("Read survived client teardown") }
                catch { XCTAssertTrue(error is CancellationError) }
            }
        } catch {
            await client.close()
            throw error
        }
        await client.close()
        print("PASS native cold settings capacity and cancellation")
    }

    private func waitFor(_ client: RuntimeClient, key: String, count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try await client.invoke("application:query")[key]?.intValue != count {
            guard ContinuousClock.now < deadline else { throw RuntimeError("REPLAY_TIMEOUT", "Waiting for \(key)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
