import AppKit
import ImageIO
import MokuseiCore
import SwiftUI

@MainActor public enum NativeMokuMapLogoArtwork {
    private static let images: [JSONText: Image] = {
        var images: [JSONText: Image] = [:]
        for id in ["codex", "claude", "pi", "opencode"] {
            images[JSONText(id)] = load(id)
        }
        return images
    }()

    public static func image(for harnessID: JSONText) -> Image? { images[harnessID] }

    private static func load(_ id: String) -> Image? {
        let name = "moku-map-\(id)"
        let bundle = NativeResources.bundle
        guard let url = bundle.url(forResource: name, withExtension: "png")
                ?? bundle.url(forResource: name, withExtension: "png", subdirectory: "moku-map"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 512,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }

        let bitmap = NSBitmapImageRep(cgImage: thumbnail)
        let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
        let columns = (0..<width).filter { (bitmap.colorAt(x: $0, y: height / 2)?.alphaComponent ?? 0) > 0.5 }
        let rows = (0..<height).filter { (bitmap.colorAt(x: width / 2, y: $0)?.alphaComponent ?? 0) > 0.5 }
        guard let left = columns.first, let right = columns.last,
              let top = rows.first, let bottom = rows.last else { return nil }
        let circle = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        // Sample inside the illustrated highlight so the native glass owns the rim.
        let bounds = circle.insetBy(dx: circle.width * 0.012, dy: circle.height * 0.012).integral
        guard let tint = thumbnail.cropping(to: bounds) else { return nil }
        return Image(decorative: tint, scale: 1).renderingMode(.original)
    }
}
