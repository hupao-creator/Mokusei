import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Square thumbnail for an image attachment in the composer strip. A pending
/// attachment already carries a downsampled preview decoded at import time, so
/// the chip can show real pixels as soon as the preview's background decode
/// lands; the managed-file path decode is only the fallback for ready
/// attachments that arrived without a preview.
struct NativeComposerImageChip: View {
    let attachment: NativeComposerAttachment
    let containerRadius: CGFloat
    let onRemove: () -> Void
    let removeLabel: String
    @State private var thumbnail: CGImage?
    @State private var previewImage: CGImage?
    @State private var pathDecodeFailed = false
    @State private var removeHovered = false

    init(attachment: NativeComposerAttachment, containerRadius: CGFloat,
         onRemove: @escaping () -> Void, removeLabel: String) {
        self.attachment = attachment
        self.containerRadius = containerRadius
        self.onRemove = onRemove
        self.removeLabel = removeLabel
        // Only an O(1) cache lookup here, never a synchronous decode. A surface
        // switch (Dock ↔ full composer) rebuilds this view; cached pixels make
        // its first frame real instead of flashing the placeholder.
        _previewImage = State(initialValue: NativeComposerPreviewCache.image(
            for: attachment.preview?.identity))
    }

    private var stored: NativeComposerStoredAttachment? { attachment.attachment }
    private var pending: Bool { attachment.pending }
    private var name: String { attachment.name.string }
    private var preview: NativeComposerPreview? { attachment.preview }
    private var path: String? {
        guard let stored, stored.kind == .image else { return nil }
        let value = stored.path.string
        guard value.hasPrefix("/") else { return nil }
        return value
    }
    /// Drives the managed-file decode. It is `nil` whenever a preview exists, so
    /// a preview appearing (or disappearing) changes the task identity and the
    /// fallback decode re-runs instead of being stranded behind an early return.
    private var thumbnailRequest: String? {
        guard preview == nil else { return nil }
        return path
    }
    private var side: CGFloat { NativeComposerChipMetrics.imageSize }
    private var radius: CGFloat { NativeComposerChipMetrics.imageRadius(containerRadius: containerRadius) }

    /// Prefer the import-time preview; the managed-file thumbnail only fills in
    /// when no preview exists (e.g. a file-panel attachment). While a late
    /// preview is still decoding, the path thumbnail stays visible so the chip
    /// does not blink through a placeholder.
    private var displayImage: CGImage? {
        if preview != nil { return previewImage ?? thumbnail }
        return thumbnail
    }
    /// A ready image whose managed file failed to decode gets a visible broken
    /// state instead of looking like a silently empty thumbnail.
    private var failed: Bool {
        !pending && path != nil && preview == nil && pathDecodeFailed
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            thumbnailSurface
            removeButton.padding(3)
        }
        .frame(width: side, height: side)
        .task(id: preview?.identity) { await loadPreview() }
        .task(id: thumbnailRequest) { await loadThumbnail() }
        .help(name)
    }

    private var thumbnailSurface: some View {
        Group {
            if let image = displayImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius)
            .strokeBorder(failed
                ? NativePlatformPalette.thread.danger.swiftUI.opacity(0.5)
                : Color.primary.opacity(0.10), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: radius))
        .accessibilityLabel(name)
        .accessibilityIdentifier("composer-image-preview")
    }

    /// Keep the square footprint while staging or when a file cannot be decoded,
    /// so the strip never jumps between layouts. A decode failure swaps the glyph
    /// for a warning so the user can tell the image is broken, not still loading.
    private var placeholder: some View {
        ZStack {
            Color.primary.opacity(0.06)
            NativeIcon(name: failed ? "trianglealert" : "FileImage", size: 18, strokeWidth: 1.5)
                .foregroundStyle(failed
                    ? NativePlatformPalette.thread.danger.swiftUI.opacity(0.7)
                    : Color.primary.opacity(pending ? 0.42 : 0.62))
        }
    }

    private var removeButton: some View {
        Button(action: onRemove) {
            NativeIcon(name: "X", size: 9, strokeWidth: 2.2)
                // The scrim keeps the glyph legible over light or dark images;
                // it is intentionally independent of the window appearance.
                .foregroundStyle(.white)
                .frame(width: NativeComposerChipMetrics.removeButtonSize,
                       height: NativeComposerChipMetrics.removeButtonSize)
                .background(Color.black.opacity(removeHovered ? 0.72 : 0.55), in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.24), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { removeHovered = $0 }
        .help(removeLabel)
        .accessibilityLabel("\(removeLabel): \(name)")
        .accessibilityIdentifier("composer-image-remove")
    }

    @MainActor private func loadPreview() async {
        guard let preview else {
            previewImage = nil
            return
        }
        if let cached = NativeComposerPreviewCache.image(for: preview.identity) {
            previewImage = cached
            return
        }
        let image = await Task.detached(priority: .userInitiated) {
            NativeComposerPreviewCache.decode(preview.data)
        }.value
        guard !Task.isCancelled, self.preview?.identity == preview.identity else { return }
        if let image { NativeComposerPreviewCache.store(image, for: preview.identity) }
        previewImage = image
    }

    @MainActor private func loadThumbnail() async {
        // A preview already decoded at import time wins; never re-decode the
        // managed file just because its path changed during staging.
        guard preview == nil, let thumbnailRequest else {
            thumbnail = nil
            pathDecodeFailed = false
            return
        }
        let image = await NativeComposerThumbnailLoader.load(
            path: thumbnailRequest, maxPixelSize: Int(side * 2))
        guard !Task.isCancelled, preview == nil, path == thumbnailRequest else { return }
        thumbnail = image
        pathDecodeFailed = image == nil
    }
}

/// Decoded preview thumbnails keyed by the preview's content identity. The
/// composer is torn down and rebuilt when it moves between the Dock and the full
/// surface; a cached `CGImage` lets the rebuilt chip draw real pixels on its
/// first frame. `NSCache` is thread-safe, hence the `nonisolated(unsafe)`.
enum NativeComposerPreviewCache {
    // NSCache is thread-safe; the annotation only silences Sendable checking.
    nonisolated(unsafe) private static let images: NSCache<NSNumber, CGImage> = {
        let cache = NSCache<NSNumber, CGImage>()
        cache.countLimit = 64
        return cache
    }()

    static func image(for identity: Int?) -> CGImage? {
        guard let identity else { return nil }
        return images.object(forKey: NSNumber(value: identity))
    }

    static func store(_ image: CGImage, for identity: Int) {
        images.setObject(image, forKey: NSNumber(value: identity))
    }

    /// ImageIO decode. Callers run this off the main actor.
    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// ImageIO runs off the main actor and bounds decode memory to the displayed
/// thumbnail. Sources are managed attachment files; URLs are never resolved
/// over the network.
enum NativeComposerThumbnailLoader {
    static func load(path: String, maxPixelSize: Int) async -> CGImage? {
        let url = URL(fileURLWithPath: path)
        return await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize)
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }
}

/// Decodes a bounded, real-image PNG preview straight from the original paste /
/// drop bytes (or file URL) at import time. The result is value-typed PNG data,
/// so it is `Sendable` and never retains the full-resolution source.
enum NativeComposerPreviewGenerator {
    static let maxPixelSize = 112

    static func make(_ file: NativeComposerFile) async -> NativeComposerPreview? {
        await Task.detached(priority: .userInitiated) {
            guard let image = downsample(file, maxPixelSize: maxPixelSize) else { return nil }
            return encodePNG(image)
        }.value
    }

    static func downsample(_ file: NativeComposerFile, maxPixelSize: Int) -> CGImage? {
        let source: CGImageSource?
        switch file.source {
        case .file(let url): source = CGImageSourceCreateWithURL(url as CFURL, nil)
        case .bytes(let data): source = CGImageSourceCreateWithData(data as CFData, nil)
        case .hostPath: return nil
        }
        guard let source else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize)
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func encodePNG(_ image: CGImage) -> NativeComposerPreview? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length > 0 else { return nil }
        return NativeComposerPreview(data: data as Data)
    }
}
