import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// SwiftUI paste/drop providers are decoded before the draft stages any attachments.
@MainActor enum NativeComposerPaste {
    /// Snapshot before yielding: another copy must not change an in-flight paste.
    /// Plain text alone belongs to TextEditor's native paste/IME handling.
    static func attachmentProviders(from pasteboard: NSPasteboard) -> [NSItemProvider] {
        let items = pasteboard.pasteboardItems ?? []
        let attachments: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]
        guard items.contains(where: { $0.availableType(from: attachments) != nil }) else { return [] }
        return items.map { item in
            let provider = NSItemProvider()
            for type in attachments + [.string] {
                guard let bytes = item.data(forType: type) else { continue }
                provider.registerDataRepresentation(forTypeIdentifier: type.rawValue, visibility: .all) { completion in
                    completion(bytes, nil); return nil
                }
            }
            return provider
        }
    }
    struct Content {
        var files: [NativeComposerFile] = []
        var text: String?
        func replacingText(in original: String, selection: NSRange) -> String {
            guard let text else { return original }
            guard let range = Range(selection, in: original) else { return original + text }
            var result = original; result.replaceSubrange(range, with: text); return result
        }
    }
    static func load(_ providers: [NSItemProvider]) async -> Content {
        var result = Content()
        var text: [String] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let data = await data(provider, type: .fileURL), let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
                result.files.append(.init(url: url))
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.png.identifier), let bytes = await data(provider, type: .png) {
                result.files.append(.init(data: bytes, name: "pasted-image.png", mimeType: "image/png"))
            } else if provider.hasItemConformingToTypeIdentifier(UTType.tiff.identifier), let bytes = await data(provider, type: .tiff),
                      bytes.count > NativeComposerDraft.maximumClipboardBytes || validTIFF(bytes) {
                result.files.append(.clipboard(tiff: bytes))
            } else if let type = provider.registeredTypeIdentifiers.compactMap({ UTType($0) }).first(where: {
                // A rejected clipboard TIFF must not reenter as an ordinary
                // file and bypass raster preparation/attachment admission.
                !$0.conforms(to: .tiff) && ($0.conforms(to: .image) || $0.conforms(to: .pdf))
            }), let file = await file(provider, type: type) {
                result.files.append(file)
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier),
               let bytes = await data(provider, type: .utf8PlainText), let value = String(data: bytes, encoding: .utf8) { text.append(value) }
        }
        if !text.isEmpty { result.text = text.joined(separator: "\n") }
        return result
    }
    private static func validTIFF(_ bytes: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0 && (CGImageSourceGetType(source) as String?) == UTType.tiff.identifier
    }
    private static func data(_ provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in continuation.resume(returning: data) }
        }
    }
    private static func file(_ provider: NSItemProvider, type: UTType) async -> NativeComposerFile? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { continuation.resume(returning: nil); return }
                // Item-provider URLs expire when this callback returns. Copy
                // on disk, then hold ownership until the upload completes.
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mokusei-import-\(UUID().uuidString)", isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                    let destination = directory.appendingPathComponent(url.lastPathComponent)
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: NativeComposerFile(url: destination, removeOnRelease: true))
                } catch {
                    try? FileManager.default.removeItem(at: directory)
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
