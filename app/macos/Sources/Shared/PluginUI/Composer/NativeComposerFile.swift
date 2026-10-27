import Foundation
import ImageIO
import MokuseiCore
import UniformTypeIdentifiers

/// Local sources always mean this device's bytes. Host paths carry the stable
/// host identity, so raw file paths cannot impersonate authorized references.
public struct NativeComposerFile: Sendable {
    public enum Source: Sendable {
        case file(URL)
        case bytes(Data)
        case hostPath(RuntimeHostFileReference)
    }
    public let source: Source
    public let name: String
    public let size: Int
    public let mimeType: String
    let clipboardTIFF: Bool
    private let access: NativeComposerFileAccess?

    public init(url: URL) {
        self.init(url: url, removeOnRelease: false)
    }

    init(url: URL, removeOnRelease: Bool) {
        clipboardTIFF = false
        access = NativeComposerFileAccess(url: url, removeOnRelease: removeOnRelease)
        source = .file(url)
        name = url.lastPathComponent
        size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let ext = url.pathExtension.lowercased()
        let portableTypes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
                             "tif": "image/tiff", "tiff": "image/tiff", "webp": "image/webp", "txt": "text/plain", "pdf": "application/pdf"]
        mimeType = UTType(filenameExtension: ext)?.preferredMIMEType ?? portableTypes[ext] ?? "application/octet-stream"
    }

    public init(data: Data, name: String, mimeType: String) {
        clipboardTIFF = false; access = nil
        source = .bytes(data); self.name = name; size = data.count; self.mimeType = mimeType
    }
    public init(hostFile: RuntimeHostFileReference, name: String, size: Int, mimeType: String) {
        clipboardTIFF = false; access = nil
        source = .hostPath(hostFile); self.name = name; self.size = size; self.mimeType = mimeType
    }
    private init(tiff: Data) {
        access = nil
        source = .bytes(tiff); name = "pasted-image.tiff"; size = tiff.count
        mimeType = "image/tiff"; clipboardTIFF = true
    }
    static func clipboard(tiff: Data) -> Self { Self(tiff: tiff) }
}

/// The security scope is retained with the value through thumbnailing and
/// upload. Provider copies are removed when the final owner releases them.
private final class NativeComposerFileAccess: @unchecked Sendable {
    private let url: URL
    private let scoped: Bool
    private let removeOnRelease: Bool
    init(url: URL, removeOnRelease: Bool) {
        self.url = url; self.removeOnRelease = removeOnRelease
        scoped = url.startAccessingSecurityScopedResource()
    }
    deinit {
        if scoped { url.stopAccessingSecurityScopedResource() }
        if removeOnRelease { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }
}
