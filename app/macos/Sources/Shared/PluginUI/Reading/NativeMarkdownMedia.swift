import AppKit
import Foundation
import ImageIO
import SwiftUI

public typealias NativeMarkdownMediaResolver = @Sendable (URL) async throws -> Data

private struct NativeMarkdownMediaResolverKey: EnvironmentKey {
    static let defaultValue: NativeMarkdownMediaResolver? = nil
}

public extension EnvironmentValues {
    var nativeMarkdownMediaResolver: NativeMarkdownMediaResolver? {
        get { self[NativeMarkdownMediaResolverKey.self] }
        set { self[NativeMarkdownMediaResolverKey.self] = newValue }
    }
}

public enum NativeMarkdownMediaError: Error, LocalizedError, Sendable {
    case invalidImage
    case unsupportedURL
    case response(Int)
    case tooLarge
    public var errorDescription: String? {
        switch self {
        case .invalidImage: "无法读取图片格式。"
        case .unsupportedURL: "此图片需要宿主提供附件地址解析。"
        case .response(let status): "服务器返回 HTTP \(status)。"
        case .tooLarge: "图片超过读取上限。"
        }
    }
}

typealias MarkdownMediaError = NativeMarkdownMediaError

actor MarkdownMediaCache {
    static let shared = MarkdownMediaCache()
    // URLSession owns HTTP freshness and revalidation. A URL-only body cache
    // would bypass no-store/no-cache and reuse stale media across documents.
    private let singleLimit = 24 * 1024 * 1024

    func load(_ url: URL) async throws -> Data {
        try Task.checkCancellation()
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw MarkdownMediaError.unsupportedURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (stream, response) = try await URLSession.shared.bytes(for: request)
        if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            throw MarkdownMediaError.response(response.statusCode)
        }
        guard response.expectedContentLength <= singleLimit else { throw MarkdownMediaError.tooLarge }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in stream {
            guard data.count < singleLimit else { throw MarkdownMediaError.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }

    @MainActor static func decode(_ data: Data) -> NativePlatformImage? {
        // Bound decoded raster allocation independently from compressed size.
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Double,
           let height = properties[kCGImagePropertyPixelHeight] as? Double,
           width * height > 40_000_000 { return nil }
        guard data.count <= 24 * 1024 * 1024 else { return nil }
        return NativePlatformImage(data: data)
    }
}

/// Local files bypass host attachment resolvers and the network cache. Retain
/// only the bounded raster in the mounted document, so changed files are read
/// again on remount rather than hidden behind a URL-only global cache.
enum MarkdownLocalImage {
    static func load(_ url: URL) async throws -> CGImage {
        try await Task.detached(priority: .userInitiated) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw MarkdownMediaError.invalidImage }
            guard let size = values.fileSize, size <= 64 * 1024 * 1024 else { throw MarkdownMediaError.tooLarge }
        }.value
        try Task.checkCancellation()
        guard let image = await NativeComposerThumbnailLoader.load(path: url.path, maxPixelSize: 2048) else {
            throw MarkdownMediaError.invalidImage
        }
        try Task.checkCancellation()
        return image
    }
}

public enum NativeMarkdownSummary {
    public static func plainText(_ text: String, limit: Int = 1024) async -> String {
        guard limit > 0 else { return "" }
        guard let document = try? await NativeMarkdownParser.shared.parse(text) else { return "" }
        var result = ""
        func append(_ value: String) {
            guard result.count < limit else { return }
            if !result.isEmpty { result += " " }
            result += value.prefix(max(0, limit - result.count))
        }
        func visit(_ blocks: [MarkdownBlock]) {
            for block in blocks where result.count < limit {
                switch block {
                case .paragraph(let spans), .heading(_, let spans): append(spans.map(\.text).joined())
                case .quote(let children), .footnote(_, _, let children): visit(children)
                case .list(let items): for item in items { visit(item.blocks) }
                case .code(_, let source): append(source)
                case .table(let rows, _): for row in rows { append(row.map { $0.map(\.text).joined() }.joined(separator: " ")) }
                case .rule: break
                }
            }
        }
        visit(document.blocks)
        return String(result.prefix(limit))
    }
}
