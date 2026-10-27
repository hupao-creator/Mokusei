// Shared by the ordinary SwiftUI replay and the optional recording fixture.
import Foundation
import MachO

func prepareReplayEnvironment() {
    let directory = Bundle.main.bundleURL.deletingLastPathComponent()
    precondition(FileManager.default.changeCurrentDirectoryPath(directory.path), "Cannot enter replay fixture directory")
    let images = (0..<_dyld_image_count()).compactMap { index in
        _dyld_get_image_name(index).map { String(cString: $0) }
    }
    let evidence: [String: Any] = [
        "pid": ProcessInfo.processInfo.processIdentifier,
        "bundleID": Bundle.main.bundleIdentifier ?? "",
        "bundle": Bundle.main.bundleURL.path,
        "cwd": FileManager.default.currentDirectoryPath,
        "images": images,
    ]
    do {
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("launch.json"))
    } catch {
        preconditionFailure("Cannot record replay launch environment: \(error)")
    }
}
