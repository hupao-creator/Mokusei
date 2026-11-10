// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MarkdownFrameworkComparison",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../../../../app/macos"),
        .package(url: "https://github.com/gonzalezreal/textual", revision: "01b51875a5406eefc95f52a058cb059e7bc94dc4"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", revision: "8371aeb32f35795a9e559029fb08613355733626")
    ],
    targets: [
        .executableTarget(name: "MarkdownFrameworkComparison", dependencies: [
            .product(name: "MokuseiPluginUI", package: "macos"),
            .product(name: "Textual", package: "textual"),
            .product(name: "MarkdownUI", package: "swift-markdown-ui")
        ], path: "Sources")
    ]
)
