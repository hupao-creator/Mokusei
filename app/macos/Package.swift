// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MokuseiNative",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Mokusei", targets: ["Mokusei"]),
        .executable(name: "MokuseiProbe", targets: ["MokuseiProbe"]),
        .library(name: "MokuseiCore", targets: ["MokuseiCore"]),
        .library(name: "MokuseiUI", targets: ["MokuseiUI"]),
        .library(name: "MokuseiPluginAPI", targets: ["MokuseiPluginAPI"]),
        .library(name: "MokuseiPluginUI", targets: ["MokuseiPluginUI"]),
        .library(name: "MokuseiComposition", targets: ["MokuseiComposition"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
        .package(url: "https://github.com/swiftlang/swift-cmark.git", exact: "0.9.0"),
        .package(url: "https://github.com/karwa/swift-url.git", exact: "0.4.2"),
        .package(url: "https://github.com/livekit/webrtc-xcframework.git", exact: "150.7871.02")
    ],
    targets: [
        .target(name: "MokuseiCore", path: "Sources/Core", exclude: ["README.md"]),
        .target(name: "MokuseiPluginAPI", dependencies: ["MokuseiCore"], path: "Sources/Shared/PluginAPI", exclude: ["README.md"]),
        .target(name: "MokuseiPluginUI", dependencies: [
            "MokuseiCore", "MokuseiPluginAPI",
            .product(name: "Markdown", package: "swift-markdown"),
            .product(name: "cmark-gfm", package: "swift-cmark"),
            .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            .product(name: "WebURL", package: "swift-url")
        ], path: "Sources/Shared/PluginUI", exclude: ["README.md", "Shaders", "Resources/Palette.xcassets"], resources: [.process("Resources")],
            plugins: [.plugin(name: "CloudMetalCompiler")]),
        .target(name: "MokuseiHarnessCodex", dependencies: ["MokuseiCore", "MokuseiPluginAPI", "MokuseiPluginUI"], path: "Sources/Plugins/Harnesses/Codex"),
        .target(name: "MokuseiHarnessPi", dependencies: ["MokuseiCore", "MokuseiPluginAPI", "MokuseiPluginUI"], path: "Sources/Plugins/Harnesses/Pi"),
        .target(name: "MokuseiHarnessClaude", dependencies: ["MokuseiCore", "MokuseiPluginAPI", "MokuseiPluginUI"], path: "Sources/Plugins/Harnesses/Claude"),
        .target(name: "MokuseiHarnessOpenCode", dependencies: ["MokuseiCore", "MokuseiPluginAPI", "MokuseiPluginUI"], path: "Sources/Plugins/Harnesses/OpenCode"),
        .target(name: "MokuseiApplications", dependencies: ["MokuseiCore", "MokuseiPluginAPI", "MokuseiPluginUI", .product(name: "WebURL", package: "swift-url")], path: "Sources/Plugins/Applications"),
        .target(name: "MokuseiSidecardConversation", dependencies: ["MokuseiCore", "MokuseiPluginAPI", "MokuseiPluginUI"], path: "Sources/Plugins/Sidecards/Conversation"),
        .target(name: "MokuseiSidecardBrowser", dependencies: ["MokuseiCore", "MokuseiPluginAPI", "MokuseiPluginUI"], path: "Sources/Plugins/Sidecards/Browser"),
        .target(name: "MokuseiSidecardVoice", dependencies: ["MokuseiCore", "MokuseiPluginAPI", "MokuseiPluginUI"], path: "Sources/Plugins/Sidecards/Voice"),
        .target(name: "MokuseiVoice", dependencies: ["MokuseiCore", "MokuseiPluginAPI", .product(name: "LiveKitWebRTC", package: "webrtc-xcframework")], path: "Sources/Voice", exclude: ["README.md"]),
        .target(name: "MokuseiUI", dependencies: ["MokuseiCore", "MokuseiPluginAPI", "MokuseiPluginUI", "MokuseiVoice", .product(name: "WebURL", package: "swift-url")], path: "Sources/Host", exclude: [
            "Overview/README.md", "MokuScene/README.md", "Settings/README.md", "Onboarding/README.md",
            "WindowNavigation/README.md", "Interaction/README.md", "Git/README.md"
        ]),
        .target(name: "MokuseiComposition", dependencies: ["MokuseiCore", "MokuseiUI", "MokuseiPluginAPI", "MokuseiPluginUI", "MokuseiHarnessCodex", "MokuseiHarnessPi", "MokuseiHarnessClaude", "MokuseiHarnessOpenCode", "MokuseiApplications", "MokuseiSidecardConversation", "MokuseiSidecardBrowser", "MokuseiSidecardVoice"], path: "Sources/Composition"),
        .executableTarget(name: "Mokusei", dependencies: ["MokuseiComposition", "MokuseiCore", "MokuseiUI", "MokuseiPluginUI"], path: "Sources/App",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "MokuseiProbe", dependencies: ["MokuseiCore"], path: "Sources/Tools/Probe"),
        .target(name: "MokuseiTestSupport", path: "Tests/Support", exclude: ["README.md"]),
        .target(name: "MokuseiNativeInputSupport", path: "Tests/NativeInputSupport", exclude: ["README.md"],
            publicHeadersPath: "include", linkerSettings: [.linkedFramework("AppKit")]),
        .testTarget(name: "MokuseiSettingsIntegrationTests", dependencies: [
            "MokuseiTestSupport", "MokuseiNativeInputSupport",
            "MokuseiCore", "MokuseiUI", "MokuseiPluginAPI", "MokuseiPluginUI",
            "MokuseiHarnessCodex", "MokuseiHarnessPi", "MokuseiHarnessClaude", "MokuseiHarnessOpenCode", "MokuseiSidecardBrowser", "MokuseiSidecardConversation", "MokuseiVoice", "MokuseiApplications"
        ], path: "Tests/Integration/Host"),
        .testTarget(name: "MokuseiGitIntegrationTests", dependencies: ["MokuseiTestSupport", "MokuseiUI", "MokuseiCore", "MokuseiPluginAPI", "MokuseiPluginUI", "MokuseiHarnessCodex", "MokuseiHarnessPi", "MokuseiHarnessClaude", "MokuseiHarnessOpenCode"], path: "Tests/Integration/Threads"),
        .testTarget(name: "MokuseiCoreTests", dependencies: ["MokuseiCore"], path: "Tests/Core"),
        .plugin(name: "CloudMetalCompiler", capability: .buildTool())
    ],
    swiftLanguageModes: [.v6]
)
