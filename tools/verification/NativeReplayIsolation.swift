import Foundation

private struct NativeReplayIsolationError: Error, CustomStringConvertible { let description: String }

/// Runs before Cocoa mounts anything. LaunchServices need not preserve the
/// launcher's cwd, and a timeout must be able to identify this exact app PID.
func prepareIsolatedNativeReplay() throws {
    let root = Bundle.main.bundleURL.deletingLastPathComponent().resolvingSymlinksInPath()
    guard root.lastPathComponent.hasPrefix("mokusei-native-replay-"),
          ["/private/var/folders/", "/var/folders/", "/private/tmp/", "/tmp/"].contains(where: root.path.hasPrefix) else {
        throw NativeReplayIsolationError(description: "Replay app must be staged in temporary storage: \(root.path)")
    }
    let workspace = root.appendingPathComponent("workspace", isDirectory: true)
    guard FileManager.default.changeCurrentDirectoryPath(workspace.path) else {
        throw NativeReplayIsolationError(description: "Could not enter the isolated replay workspace")
    }
    let arguments = Array(CommandLine.arguments.dropFirst())
    for argument in arguments where !argument.hasPrefix("--") {
        let path = URL(fileURLWithPath: argument).resolvingSymlinksInPath().path
        guard ["/private/var/folders/", "/var/folders/", "/private/tmp/", "/tmp/"].contains(where: path.hasPrefix) else {
            throw NativeReplayIsolationError(description: "Replay input/output must stay in temporary storage")
        }
    }
    guard let resources = Bundle.main.resourceURL else { throw NativeReplayIsolationError(description: "Missing packaged resource directory") }
    let bundles = try FileManager.default.contentsOfDirectory(at: resources,
        includingPropertiesForKeys: nil).filter { $0.pathExtension == "bundle" }
    guard !bundles.isEmpty, bundles.allSatisfy({ Bundle(url: $0) != nil }) else {
        throw NativeReplayIsolationError(description: "Missing staged SwiftPM bundles; refusing checkout fallback")
    }
    try JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier,
        "cwd": FileManager.default.currentDirectoryPath, "arguments": arguments,
        "resourceBundles": bundles.map(\.path)], options: [.prettyPrinted, .sortedKeys])
        .write(to: root.appendingPathComponent("runtime-isolation.json"), options: .atomic)
}
