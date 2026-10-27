import Foundation
import Network
import XCTest
@testable import MokuseiCore

private extension RuntimeClient {
    func useQueryFixture(_ value: RuntimeConnection) { connection = value }
}

/// Exercise RuntimeClient's actual unstructured command task and URLSession,
/// not a domain mock that merely observes PluginLifetime cancellation.
final class RuntimeQueryCancellationTests: XCTestCase {
    func testCancelledApplicationQueryClosesHTTPAndReleasesCommand() async throws {
        let received = expectation(description: "query reached loopback")
        let disconnected = expectation(description: "cancel closed loopback request")
        let ready = expectation(description: "loopback listener ready")
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                guard data?.isEmpty == false, error == nil else { connection.cancel(); return }
                received.fulfill()
                Self.awaitDisconnect(connection, disconnected)
            }
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        await fulfillment(of: [ready], timeout: 3)
        let port = try XCTUnwrap(listener.port)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let client = RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory))
        await client.useQueryFixture(RuntimeConnection(port: Int(port.rawValue), token: "fixture", epoch: "fixture", protocolVersion: RuntimeProtocol.version, pid: Int(getpid()), dataDir: directory.path))
        let task = Task {
            try await client.invoke("application:query", args: [.object([
                "pluginId": .text("git"), "operationId": .text("git.files"),
                "input": .object(["activityId": .text("fixture")])
            ])])
        }
        await fulfillment(of: [received], timeout: 3)
        task.cancel()
        await fulfillment(of: [disconnected], timeout: 3)
        do {
            _ = try await task.value
            XCTFail("Cancelled query completed successfully")
        } catch { XCTAssertTrue(error is CancellationError) }
        let active = await client.activeCommands.count
        let unresolved = await client.uncertainReceipts()
        XCTAssertEqual(active, 0)
        XCTAssertTrue(unresolved.isEmpty)
        await client.close()
    }

    private static func awaitDisconnect(_ connection: NWConnection, _ done: XCTestExpectation) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, complete, error in
            if complete || error != nil { done.fulfill(); connection.cancel() }
            else { awaitDisconnect(connection, done) }
        }
    }
}
