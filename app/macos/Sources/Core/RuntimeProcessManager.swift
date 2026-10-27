import Foundation

/// Explicit launch paths let development and signed application bundles share
/// the same process manager without invoking a shell or searching an unsafe PATH.
public struct RuntimeLaunchConfiguration: Sendable, Equatable {
    public let executable: URL
    public let workingDirectory: URL?
    public let environment: [String: String]

    public init(executable: URL, workingDirectory: URL? = nil, environment: [String: String] = [:]) {
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

/// Starts/reuses the shared service through the Go ownership manager.
/// Stopping is always authenticated and cooperative; no PID is forcibly killed.
public struct RuntimeProcessManager: RuntimeConnectionSource {
    public let profile: RuntimeProfile
    public let launch: RuntimeLaunchConfiguration?

    public init(profile: RuntimeProfile, launch: RuntimeLaunchConfiguration? = nil) {
        self.profile = profile
        self.launch = launch
    }

    public func setOutputLocale(_ locale: String) throws { try profile.writeOutputLocale(locale) }

    public func status() async throws -> RuntimeConnection? {
        try Task.checkCancellation()
        guard let connection = try profile.readConnection() else { return nil }
        guard connection.protocolVersion == RuntimeProtocol.version else {
            if !connection.isOwnerAlive { return nil }
            throw RuntimeError("PROTOCOL_MISMATCH", "A live runtime uses a different protocol; stop it with its matching client first")
        }
        do {
            let health = try await RuntimeTransport().request(connection: connection, path: "/health", timeout: 2)
            guard health["epoch"]?.stringValue == connection.epoch,
                  health["dataDir"]?.stringValue == connection.dataDir,
                  health["pid"]?.intValue == connection.pid,
                  health["protocolVersion"]?.intValue == RuntimeProtocol.version else {
                throw RuntimeError("IDENTITY_MISMATCH", "Runtime identity does not match this profile")
            }
            if health["status"]?.stringValue == "stopping" {
                throw RuntimeError("SERVICE_STOPPING", "Runtime is stopping")
            }
            guard health["status"]?.stringValue == "running" else {
                throw RuntimeError("INVALID_HEALTH", "Runtime returned an invalid health status")
            }
            return connection
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            // The service can retire discovery while this health probe is in
            // flight, before its old process finishes flushing the stop reply.
            if try profile.readConnection()?.epoch != connection.epoch { return nil }
            // A dead owner's port may now answer for an unrelated service.
            // Preserve metadata errors above, but allow stale discovery recovery.
            guard connection.isOwnerAlive else { return nil }
            if let error = error as? RuntimeError { throw error }
            throw RuntimeError("RUNTIME_UNREACHABLE", "The profile owner is alive but its runtime API is unavailable")
        }
    }

    public func start() async throws -> RuntimeConnection {
        try Task.checkCancellation()
        try profile.prepare()
        let retirementDeadline = ContinuousClock.now.advanced(by: .seconds(120))
        while true {
            do {
                if let existing = try await status() { return existing }
                break
            } catch let error as RuntimeError where error.code == "SERVICE_STOPPING" {
                guard ContinuousClock.now < retirementDeadline else {
                    throw RuntimeError("STARTUP_TIMEOUT", "Previous runtime has not finished stopping")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        guard let launch else {
            throw RuntimeError("LAUNCH_UNAVAILABLE", "No runtime is running and no runtime launch configuration was provided")
        }
        guard launch.executable.isFileURL,
              launch.workingDirectory?.isFileURL != false else {
            throw RuntimeError("INVALID_LAUNCH_CONFIGURATION", "Runtime executable and working directory must be local file URLs")
        }
        let process = Process()
        process.executableURL = launch.executable
        // `start` reuses the Go manager's exclusive ownership, startup cleanup,
        // detached service lifetime, and simultaneous-launch recovery.
        process.arguments = ["start", "--data-dir", profile.dataDirectory.path]
        process.currentDirectoryURL = launch.workingDirectory
        var environment = ProcessInfo.processInfo.environment.merging(launch.environment) { _, selected in selected }
        // External harnesses may use Node. Remove inherited injection flags,
        // while preserving credentials, HOME, PATH, proxies and certificate settings.
        for key in ["NODE_OPTIONS", "NODE_PATH", "ELECTRON_RUN_AS_NODE"] { environment.removeValue(forKey: key) }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        do { try process.run() }
        catch { throw RuntimeError("LAUNCH_FAILED", "Unable to launch the runtime executable; verify the configured executable") }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(120))
        while clock.now < deadline {
            try Task.checkCancellation()
            if let connection = try await status() { return connection }
            // Another launcher may have won ownership while our helper exits.
            if !process.isRunning, try !profile.hasLiveOwner() {
                throw RuntimeError("LAUNCH_FAILED", "Runtime exited before becoming ready; inspect runtime/startup-error.json and runtime debug logs")
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw RuntimeError("STARTUP_TIMEOUT", "Runtime did not become ready within two minutes; no process was terminated")
    }

    public func stop(expectedEpoch: String? = nil) async throws {
        let clock = ContinuousClock()
        let startupDeadline = clock.now.advanced(by: .seconds(30))
        let connection: RuntimeConnection
        while true {
            try Task.checkCancellation()
            let current: RuntimeConnection?
            do { current = try await status() }
            catch let error as RuntimeError where error.code == "SERVICE_STOPPING" {
                current = try profile.readConnection()
            }
            if let current { connection = current; break }
            // A service owns the profile before publishing discovery and after
            // removing it. Missing discovery alone never means it has stopped.
            if try !profile.hasLiveOwner() { return }
            guard clock.now < startupDeadline else {
                throw RuntimeError("STOP_TIMEOUT", "The profile owner has not become reachable or released ownership; no process was terminated")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        if let expectedEpoch, connection.epoch != expectedEpoch { return }
        _ = try await RuntimeTransport().request(connection: connection, path: "/stop", method: "POST")
        let shutdownDeadline = clock.now.advanced(by: .seconds(30))
        while clock.now < shutdownDeadline {
            try Task.checkCancellation()
            let current = try profile.readConnection()
            if let current, current.epoch != connection.epoch { return }
            if let current, !current.isOwnerAlive { return }
            if current == nil, try !profile.hasLiveOwner() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RuntimeError("STOP_TIMEOUT", "Runtime shutdown is still in progress; no process was forcibly terminated")
    }
}
