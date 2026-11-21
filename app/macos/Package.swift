// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ChiefNative",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Chief", targets: ["Chief"]),
        .executable(name: "ChiefProbe", targets: ["ChiefProbe"]),
        .library(name: "ChiefCore", targets: ["ChiefCore"]),
        .library(name: "ChiefUI", targets: ["ChiefUI"]),
        .library(name: "ChiefPluginAPI", targets: ["ChiefPluginAPI"]),
        .library(name: "ChiefPluginUI", targets: ["ChiefPluginUI"]),
        .library(name: "ChiefComposition", targets: ["ChiefComposition"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
        .package(url: "https://github.com/swiftlang/swift-cmark.git", exact: "0.9.0"),
        .package(url: "https://github.com/karwa/swift-url.git", exact: "0.4.2")
    ],
    targets: [
        .target(name: "ChiefCore", path: "Sources/Core", exclude: ["README.md"]),
        .target(name: "ChiefPluginAPI", dependencies: ["ChiefCore"], path: "Sources/Shared/PluginAPI", exclude: ["README.md"]),
        .target(name: "ChiefPluginUI", dependencies: [
            "ChiefCore", "ChiefPluginAPI",
            .product(name: "Markdown", package: "swift-markdown"),
            .product(name: "cmark-gfm", package: "swift-cmark"),
            .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            .product(name: "WebURL", package: "swift-url")
        ], path: "Sources/Shared/PluginUI", exclude: ["README.md", "Shaders", "Resources/Palette.xcassets"], resources: [.process("Resources")],
            plugins: [.plugin(name: "CloudMetalCompiler")]),
        .target(name: "ChiefHarnessCodex", dependencies: ["ChiefCore", "ChiefPluginAPI", "ChiefPluginUI"], path: "Sources/Plugins/Harnesses/Codex"),
        .target(name: "ChiefHarnessPi", dependencies: ["ChiefCore", "ChiefPluginAPI", "ChiefPluginUI"], path: "Sources/Plugins/Harnesses/Pi"),
        .target(name: "ChiefHarnessClaude", dependencies: ["ChiefCore", "ChiefPluginAPI", "ChiefPluginUI"], path: "Sources/Plugins/Harnesses/Claude"),
        .target(name: "ChiefHarnessOpenCode", dependencies: ["ChiefCore", "ChiefPluginAPI", "ChiefPluginUI"], path: "Sources/Plugins/Harnesses/OpenCode"),
        .target(name: "ChiefApplications", dependencies: ["ChiefCore", "ChiefPluginAPI", "ChiefPluginUI", .product(name: "WebURL", package: "swift-url")], path: "Sources/Plugins/Applications"),
        .target(name: "ChiefSidecardConversation", dependencies: ["ChiefCore", "ChiefPluginAPI", "ChiefPluginUI"], path: "Sources/Plugins/Sidecards/Conversation"),
        .target(name: "ChiefSidecardBrowser", dependencies: ["ChiefCore", "ChiefPluginAPI", "ChiefPluginUI"], path: "Sources/Plugins/Sidecards/Browser"),
        .target(name: "ChiefUI", dependencies: ["ChiefCore", "ChiefPluginAPI", "ChiefPluginUI", "ChiefSidecardBrowser", .product(name: "WebURL", package: "swift-url")], path: "Sources/Host", exclude: [
            "Overview/README.md", "MokuScene/README.md", "Settings/README.md", "Onboarding/README.md",
            "WindowNavigation/README.md", "Interaction/README.md", "Git/README.md"
        ]),
        .target(name: "ChiefComposition", dependencies: ["ChiefCore", "ChiefUI", "ChiefPluginAPI", "ChiefPluginUI", "ChiefHarnessCodex", "ChiefHarnessPi", "ChiefHarnessClaude", "ChiefHarnessOpenCode", "ChiefApplications", "ChiefSidecardConversation", "ChiefSidecardBrowser"], path: "Sources/Composition"),
        .executableTarget(name: "Chief", dependencies: ["ChiefComposition", "ChiefCore", "ChiefUI", "ChiefPluginUI"], path: "Sources/App",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "ChiefProbe", dependencies: ["ChiefCore"], path: "Sources/Tools/Probe"),
        .testTarget(name: "ChiefProperties", dependencies: ["ChiefUI", "ChiefCore", "ChiefPluginAPI", "ChiefPluginUI", "ChiefApplications"], path: "Tests/Properties"),
        .plugin(name: "CloudMetalCompiler", capability: .buildTool())
    ],
    swiftLanguageModes: [.v6]
)
