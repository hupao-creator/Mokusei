import Foundation
import MokuseiCore

/// Exercises the same client library as the application through the real service.
/// The explicit profile argument prevents a probe from attaching to production by default.
@main
struct MokuseiProbe {
    struct Options {
        var directory: URL
        var runtime: URL?
        var duration: Double = 1
        var threadID: String?
        var stopService = false
        var applicationQuery: JSONValue?

        init(arguments: [String]) throws {
            var values: [String: String] = [:]
            var index = 0
            while index < arguments.count {
                let key = arguments[index]
                if key == "--stop-service" { stopService = true; index += 1; continue }
                guard ["--data-dir", "--runtime", "--duration", "--thread-id", "--query-plugin", "--query-operation", "--query-input"].contains(key),
                      index + 1 < arguments.count, values[key] == nil else {
                    throw ProbeError("Invalid or repeated argument: \(key)")
                }
                values[key] = arguments[index + 1]
                index += 2
            }
            guard let path = values["--data-dir"], path.hasPrefix("/") else {
                throw ProbeError("--data-dir must be an explicit absolute, isolated profile path")
            }
            directory = URL(fileURLWithPath: path, isDirectory: true)
            if let path = values["--runtime"] { runtime = URL(fileURLWithPath: path) }
            if let text = values["--duration"] {
                guard let value = Double(text), value.isFinite, value >= 0, value <= 300 else {
                    throw ProbeError("--duration must be between 0 and 300 seconds")
                }
                duration = value
            }
            threadID = values["--thread-id"]
            if values["--query-plugin"] != nil || values["--query-operation"] != nil || values["--query-input"] != nil {
                guard let plugin = values["--query-plugin"], !plugin.isEmpty,
                      let operation = values["--query-operation"], !operation.isEmpty else {
                    throw ProbeError("Application queries require --query-plugin and --query-operation")
                }
                let input = values["--query-input"] ?? "{}"
                guard input.utf8.count <= 1_000_000 else { throw ProbeError("Application query input is too large") }
                applicationQuery = .object([
                    "pluginId": .text(plugin), "operationId": .text(operation),
                    "input": try JSONValue.parse(data: Data(input.utf8))
                ])
            }
        }
    }

    struct ProbeError: Error, LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    actor Evidence {
        var connections: [String] = []
        var snapshotCount = 0
        var mutationCount = 0
        var contentReady = 0
        var failures: [String] = []

        func record(_ event: RuntimeClientEvent) {
            switch event {
            case .connection(let status): connections.append(status.rawValue)
            case .synchronizing: break
            case .snapshot: snapshotCount += 1
            case .mutation: mutationCount += 1
            case .threadContent(_, let state):
                if case .ready = state { contentReady += 1 }
                if case .error(let message) = state { failures.append(message) }
            case .failure(let error): failures.append(error.message)
            case .overviewFilter: break
            }
        }

        func report(snapshot: JSONValue, queryResult: JSONValue?, milliseconds: Double, stopped: Bool) -> JSONValue {
            .object([
                "ok": .bool(failures.isEmpty),
                "protocolVersion": .integer(RuntimeProtocol.version),
                "loadMilliseconds": .number(milliseconds),
                "connections": .array(connections.map(JSONValue.text)),
                "snapshotEvents": .integer(snapshotCount),
                "mutationEvents": .integer(mutationCount),
                "contentSnapshots": .integer(contentReady),
                "revision": snapshot["revision"] ?? .null,
                "threads": .integer(snapshot["threads"]?.arrayValue?.count ?? 0),
                "applications": .integer(snapshot["applicationThreads"]?.arrayValue?.count ?? 0),
                "queryResult": queryResult ?? .null,
                "stoppedService": .bool(stopped),
                "failures": .array(failures.map(JSONValue.text))
            ])
        }
    }

    static func main() async {
        var client: RuntimeClient?
        var consumer: Task<Void, Never>?
        var stopOnExit = false
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            stopOnExit = options.stopService
            let lease = try RuntimeProfileClientLease(dataDirectory: options.directory)
            lease.retainForProcess()
            let profile = lease.profile
            let launch: RuntimeLaunchConfiguration?
            if let runtime = options.runtime {
                launch = RuntimeLaunchConfiguration(executable: runtime,
                    workingDirectory: options.directory)
            } else { launch = nil }
            let runtime = RuntimeClient(profile: profile, launch: launch)
            client = runtime
            let evidence = Evidence()
            let stream = await runtime.events()
            consumer = Task {
                for await event in stream { await evidence.record(event) }
            }
            let clock = ContinuousClock()
            let started = clock.now
            try await runtime.start()
            let snapshot = try await runtime.loadState()
            let elapsed = started.duration(to: clock.now)
            let milliseconds = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
            let queryResult: JSONValue?
            if let query = options.applicationQuery {
                queryResult = try await runtime.invoke("application:query", args: [query])
            } else { queryResult = nil }
            var subscription: String?
            if let threadID = options.threadID {
                subscription = try await runtime.subscribeThreadContent(threadId: JSONText(threadID), scope: .thread)
            }
            try await Task.sleep(for: .seconds(options.duration))
            if let subscription { await runtime.releaseThreadContent(subscription) }
            if options.stopService { try await runtime.stopService() }
            await runtime.close()
            // close finishes the bounded observer. Drain its final events so a
            // late failure cannot disappear from the report during cancellation.
            await consumer?.value
            let report = await evidence.report(snapshot: snapshot, queryResult: queryResult, milliseconds: milliseconds, stopped: options.stopService)
            FileHandle.standardOutput.write(try report.encodedData() + Data([10]))
            if report["ok"]?.boolValue != true { exit(1) }
        } catch {
            if let client {
                if stopOnExit {
                    do { try await client.stopService() }
                    catch { FileHandle.standardError.write(Data("Probe cleanup failed: \(error.localizedDescription)\n".utf8)) }
                }
                await client.close()
            }
            await consumer?.value
            let report: JSONValue = .object(["ok": .bool(false), "error": .text(error.localizedDescription)])
            if let data = try? report.encodedData() { FileHandle.standardOutput.write(data + Data([10])) }
            exit(1)
        }
    }
}
