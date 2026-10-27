import Darwin
import Foundation
import MokuseiCore
import Synchronization

/// System termination can bypass the SwiftUI Quit command. Launch a small,
/// headless copy to finish cooperative shutdown after this process has exited.
/// Explicit Quit disarms it after the workspace has stopped successfully.
final class NativeRuntimeExitCleanup: Sendable {
    private let completed = Mutex(false)
    private let quittingEpoch = Mutex<String?>(nil)
    private let profile: RuntimeProfile
    private let executable: URL

    init(profile: RuntimeProfile, executable: URL) {
        self.profile = profile; self.executable = executable
        atexit_b { [self] in
            guard !completed.withLock({ $0 }) else { return }
            let epoch = quittingEpoch.withLock { $0 } ?? (try? profile.readConnection())?.epoch ?? ""
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--finish-runtime", profile.dataDirectory.path, epoch]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() }
            catch { Self.record(error, directory: profile.dataDirectory) }
        }
    }
    // Capture before asynchronous cleanup: discovery may already belong to a
    // reopened application by the time this process reaches atexit.
    func captureEpoch() {
        let epoch = (try? profile.readConnection())?.epoch ?? ""
        quittingEpoch.withLock { $0 = epoch }
    }
    func disarm() { completed.withLock { $0 = true } }
    func record(_ error: Error) { Self.record(error, directory: profile.dataDirectory) }

    static func finish(directory: URL, epoch: String) async {
        let lease: RuntimeProfileClientLease
        do { lease = try await acquireCleanupLease(directory) }
        catch {
            // Admission failed before any profile-local access. In particular,
            // do not recreate a retired profile just to record this failure.
            FileHandle.standardError.write(Data("Runtime cleanup admission failed: \(error.localizedDescription)\n".utf8))
            return
        }
        defer { withExtendedLifetime(lease) {} }
        do {
            let profile = lease.profile
            // Never stop a replacement owner started after the old application exited.
            try await RuntimeProcessManager(profile: profile).stop(expectedEpoch: epoch)
        } catch { record(error, directory: lease.profile.dataDirectory) }
    }

    private static func acquireCleanupLease(_ directory: URL) async throws -> RuntimeProfileClientLease {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var reportedWait = false
        while true {
            try Task.checkCancellation()
            do { return try RuntimeProfileClientLease(dataDirectory: directory) }
            catch let error as RuntimeError where error.code == "PROFILE_MAINTENANCE" && ContinuousClock.now < deadline {
                // Another profile's short admission or fresh operation must not
                // make the exit helper abandon its owned runtime immediately.
                // Failed acquisition has released every descriptor before wait.
                if !reportedWait {
                    FileHandle.standardError.write(Data("[native-exit] waiting for profile admission\n".utf8))
                    reportedWait = true
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
    }
    private static func record(_ error: Error, directory: URL) {
        let folder = directory.appendingPathComponent("diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(error.localizedDescription.utf8).write(to: folder.appendingPathComponent("runtime-shutdown-error.log"), options: .atomic)
    }
}
