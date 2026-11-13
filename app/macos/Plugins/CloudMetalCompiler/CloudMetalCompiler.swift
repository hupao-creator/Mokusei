import PackagePlugin
import Foundation
import CryptoKit

/// Build the macOS Metal library and native adaptive palette bundle.
@main
struct CloudMetalCompiler: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let source = target.directoryURL.appending(path: "Shaders/CloudLoading.metal")
        let palette = target.directoryURL.appending(path: "Resources/Palette.xcassets")
        try validatePalette(palette, sources: context.package.directoryURL.appending(path: "Sources"))
        try validateCloudAssets(package: context.package.directoryURL, target: target.directoryURL)
        var commands: [Command] = []
        for sdk in ["macosx"] {
            let library = context.pluginWorkDirectoryURL.appending(path: "CloudLoading-\(sdk).metallib")
            let cache = context.pluginWorkDirectoryURL.appending(path: "ModuleCache-\(sdk)")
            let deployment = "-mmacosx-version-min=26.0"
            commands.append(.buildCommand(
                displayName: "Compile \(sdk) cloud loading Metal shader",
                executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: ["-sdk", sdk, "metal", "-std=metal3.0", deployment,
                            "-fmodules-cache-path=\(cache.path)", source.path, "-o", library.path],
                inputFiles: [source], outputFiles: [library]
            ))

        }
        let generated = context.pluginWorkDirectoryURL.appending(path: "Palette-macosx")
        let contents = generated.appending(path: "PaletteResources-macosx.bundle/Contents")
        let resources = contents.appending(path: "Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "com.mokusei.ui.palette", "CFBundlePackageType": "BNDL",
                    "CFBundleVersion": "1", "CFBundleDevelopmentRegion": "en"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        let infoURL = contents.appending(path: "Info.plist")
        if (try? Data(contentsOf: infoURL)) != data { try data.write(to: infoURL) }
        commands.append(.prebuildCommand(
            displayName: "Compile adaptive SwiftUI palette",
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["-sdk", "macosx", "actool", palette.path, "--compile", resources.path,
                        "--platform", "macosx", "--minimum-deployment-target", "26.0"],
            outputFilesDirectory: generated
        ))
        return commands
    }

    private func validatePalette(_ palette: URL, sources: URL) throws {
        let pattern = try NSRegularExpression(pattern: #"\bpair\(\s*0x([0-9a-fA-F]+),\s*0x([0-9a-fA-F]+)"#)
        guard let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else { throw CocoaError(.fileReadNoSuchFile) }
        for case let file as URL in files {
            guard file.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: file, encoding: .utf8) as NSString
            for match in pattern.matches(in: source as String, range: NSRange(location: 0, length: source.length)) {
                let light = UInt32(source.substring(with: match.range(at: 1)), radix: 16)!
                let dark = UInt32(source.substring(with: match.range(at: 2)), radix: 16)!
                let name = "palette-\(String(light, radix: 16))-\(String(dark, radix: 16)).colorset/Contents.json"
                guard FileManager.default.fileExists(atPath: palette.appending(path: name).path) else {
                    throw NSError(domain: "MokuseiPalette", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing adaptive palette asset: \(name)"])
                }
            }
        }
    }

    private func validateCloudAssets(package: URL, target: URL) throws {
        struct Manifest: Decodable {
            let version: Int
            let inputSHA256: [String: String]
            let assetSHA256: [String: String]
        }
        let directory = target.appending(path: "Resources/OverviewCloud")
        let manifest = try JSONDecoder().decode(Manifest.self,
            from: Data(contentsOf: directory.appending(path: "OverviewCloudSources.json")))
        let root = package.deletingLastPathComponent().deletingLastPathComponent()
        let expectedInputs: Set<String> = [
            "tools/assets/overview-cloud/Bake.swift", "tools/assets/overview-cloud/generate.py",
            "app/macos/Sources/Shared/PluginUI/Shaders/CloudLoading.metal",
            "app/macos/Sources/Shared/PluginUI/Design/NativeCloudField.swift",
            "app/macos/Sources/Shared/PluginUI/Design/NativeCloudLoopStyle.swift"]
        let expectedAssets = Set(["OverviewCloudLoop.json"] + ["blueIndigo", "coral", "spectrum", "neutral"].flatMap { style in
            ["light", "dark"].map { "OverviewCloudLoop-\(style)-\($0).png" }
        })
        guard manifest.version == 1, Set(manifest.inputSHA256.keys) == expectedInputs,
              Set(manifest.assetSHA256.keys) == expectedAssets else { throw staleCloudAssets() }
        for (base, records) in [(root, manifest.inputSHA256), (directory, manifest.assetSHA256)] {
            for (relative, expected) in records {
                let data = try Data(contentsOf: base.appending(path: relative), options: .mappedIfSafe)
                let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard actual == expected else { throw staleCloudAssets() }
            }
        }
    }

    private func staleCloudAssets() -> NSError {
        NSError(domain: "MokuseiCloudAssets", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "Stale Overview cloud assets; run python3 tools/assets/overview-cloud/generate.py"])
    }
}
