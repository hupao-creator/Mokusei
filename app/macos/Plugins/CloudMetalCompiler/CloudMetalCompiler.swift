import PackagePlugin
import Foundation

/// Build the macOS Metal library and native adaptive palette bundle.
@main
struct CloudMetalCompiler: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let source = target.directoryURL.appending(path: "Shaders/CloudLoading.metal")
        let palette = target.directoryURL.appending(path: "Resources/Palette.xcassets")
        try validatePalette(palette, sources: context.package.directoryURL.appending(path: "Sources"))
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
}
