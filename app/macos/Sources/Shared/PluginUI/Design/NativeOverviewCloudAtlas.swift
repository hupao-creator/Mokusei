import Foundation
import ImageIO
import OSLog

struct NativeOverviewCloudAsset: Hashable, Sendable {
    let style: NativeCloudLoopStyle
    let dark: Bool
    var name: String { "OverviewCloudLoop-\(style.rawValue)-\(dark ? "dark" : "light")" }
}

/// Immutable decoded pixels are shared across cards, never recreated per frame.
final class NativeOverviewCloudAtlas: Sendable {
    struct Metadata: Decodable, Sendable {
        let duration: Double
        let fps, count, width, height, padding, columns, rows: Int
    }
    let image: CGImage
    let metadata: Metadata
    let rectangles: [CGRect]
    var byteCost: Int { image.bytesPerRow * image.height }

    init(imageURL: URL, metadataURL: URL) throws {
        let metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: metadataURL))
        // A low-rate atlas must never silently replace the shipped 120 fps source.
        guard metadata.fps == 120, metadata.count == 960, metadata.duration == 8,
              metadata.width == 180, metadata.height == 110, metadata.padding == 1,
              metadata.columns == 24, metadata.rows == 40 else { throw CocoaError(.fileReadCorruptFile) }
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == 4368, image.height == 4480 else { throw CocoaError(.fileReadCorruptFile) }
        self.metadata = metadata; self.image = image
        let tileWidth = metadata.width + 2 * metadata.padding, tileHeight = metadata.height + 2 * metadata.padding
        rectangles = (0..<metadata.count).map { index in
            CGRect(x: Double(index % metadata.columns * tileWidth + metadata.padding) / Double(image.width),
                   y: Double(index / metadata.columns * tileHeight + metadata.padding) / Double(image.height),
                   width: Double(metadata.width) / Double(image.width), height: Double(metadata.height) / Double(image.height))
        }
    }
}

@MainActor
enum NativeOverviewCloudAssets {
    private static let cache: NSCache<NSString, NativeOverviewCloudAtlas> = {
        let value = NSCache<NSString, NativeOverviewCloudAtlas>()
        value.totalCostLimit = 160 * 1024 * 1024; value.countLimit = 2
        return value
    }()
    private static var pending: [NativeOverviewCloudAsset: Task<NativeOverviewCloudAtlas, Error>] = [:]
    private static let logger = Logger(subsystem: "com.mokusei.desktop", category: "OverviewCloud")

    static func load(_ asset: NativeOverviewCloudAsset) async throws -> NativeOverviewCloudAtlas {
        if let image = cache.object(forKey: asset.name as NSString) { return image }
        if let task = pending[asset] { return try await task.value }
        let bundle = NativeResources.bundle
        guard let imageURL = bundle.url(forResource: asset.name, withExtension: "png"),
              let metadataURL = bundle.url(forResource: "OverviewCloudLoop", withExtension: "json") else {
            logger.error("Missing pre-rendered cloud resource: \(asset.name, privacy: .public)")
            throw CocoaError(.fileNoSuchFile)
        }
        // One card's cancellation does not cancel a shared decode. Completed
        // tasks leave this table so they cannot retain every appearance forever.
        let task = Task.detached(priority: .userInitiated) {
            try NativeOverviewCloudAtlas(imageURL: imageURL, metadataURL: metadataURL)
        }
        pending[asset] = task
        defer { pending[asset] = nil }
        do {
            let image = try await task.value
            cache.setObject(image, forKey: asset.name as NSString, cost: image.byteCost)
            return image
        } catch {
            logger.error("Cannot decode cloud \(asset.name, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
    }
}
