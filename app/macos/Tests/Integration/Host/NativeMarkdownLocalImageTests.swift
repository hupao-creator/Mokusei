import AppKit
import ImageIO
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import UniformTypeIdentifiers
import MokuseiPluginUI

@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeMarkdownLocalImageTests {
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("thread 图片 " + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("截图 evidence.png")
        let context = try #require(CGContext(data: nil, width: 4000, height: 2000, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemTeal.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 4000, height: 2000))
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return file
    }

    private func texts(_ root: NSView) -> [NSTextView] {
        (root as? NSTextView).map { [$0] } ?? root.subviews.flatMap(texts)
    }

    private func attachments(_ root: NSView) -> [(NSTextView, NSTextAttachment, NSRange)] {
        texts(root).flatMap { view in
            var found: [(NSTextView, NSTextAttachment, NSRange)] = []
            view.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: view.textStorage?.length ?? 0)) { value, range, _ in
                if let attachment = value as? NSTextAttachment { found.append((view, attachment, range)) }
            }
            return found
        }
    }

    @Test func localImagesRenderInProductionMessageAndKeepLinks() async throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        for width: CGFloat in [360, 900] {
            var opened: [URL] = []
            let source = """
            [截图证据](<\(file.path)>) · [普通文件](/tmp/document.txt)

            ![标准图片](<\(file.path)>)

            [file URL](\(file.absoluteString))
            """
            let window = SwiftUIReplay.window(ScrollView {
                ThreadMessage(id: "local", author: .assistant, content: source, openExternal: { opened.append($0) },
                    resolveMedia: { _ in Issue.record("Local files must bypass host/network resolution"); return Data() })
                    .padding(20)
            }.background(Color.white), width: width, height: 1000)
            defer { window.close() }
            let root = try #require(window.contentView)
            try await SwiftUIReplay.wait(timeout: .seconds(10)) { attachments(root).count == 3 }
            for (view, attachment, range) in attachments(root) {
                #expect(attachment.bounds.width <= width - 40 + 1)
                #expect(attachment.bounds.height <= 480)
                #expect(abs(attachment.bounds.width / attachment.bounds.height - 2) < 0.01)
                // NSImage's snapshot representation reports Retina-scaled
                // metadata; inspect the actual backing raster instead.
                let raster = try #require(attachment.image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
                #expect(max(raster.width, raster.height) <= 2048)
                let link = try #require(view.textStorage?.attribute(.link, at: range.location, effectiveRange: nil) as? URL)
                #expect(link.path == file.path)
                #expect(view.delegate?.textView?(view, clickedOnLink: link, at: range.location) == true)
            }
            #expect(opened.count == 3)
            #expect(texts(root).contains { $0.string.contains("截图证据") && $0.string.contains("普通文件") })
            if let directory = ProcessInfo.processInfo.environment["MOKUSEI_LOCAL_IMAGES_ARTIFACTS"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                root.cacheDisplay(in: root.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("local-images-\(Int(width)).png"))
            }
        }
        // Exercise the production parser through both Markdown syntaxes;
        // host admission must govern both previews and native link targets.
        for host in ["LOCALHOST", "localhost", "", "remote-host"] {
            let allowed = host != "remote-host"
            let destination = file.absoluteString.replacingOccurrences(of: "file://", with: "file://" + host)
            var opened: [URL] = []
            let window = SwiftUIReplay.window(ThreadMessage(id: "host", author: .assistant, content: """
                [host link](\(destination))

                ![host image](\(destination))
                """, openExternal: { opened.append($0) }, resolveMedia: { _ in
                    Issue.record("File hosts must not reach host/network resolution")
                    return Data()
                }), width: 500)
            defer { window.close() }
            let root = try #require(window.contentView)
            try await SwiftUIReplay.wait {
                allowed ? attachments(root).count == 2 :
                    texts(root).contains { $0.string.contains("host image") }
            }
            #expect(attachments(root).count == (allowed ? 2 : 0))
            var targets: [URL] = []
            for view in texts(root) {
                view.textStorage?.enumerateAttribute(.link, in: NSRange(location: 0, length: view.textStorage?.length ?? 0)) { value, range, _ in
                    guard let url = value as? URL else { return }
                    targets.append(url)
                    #expect(view.delegate?.textView?(view, clickedOnLink: url, at: range.location) == true)
                }
            }
            #expect(targets.count == (allowed ? 3 : 0))
            #expect(targets.allSatisfy { $0 == file })
            #expect(opened == targets)
        }
        if let path = ProcessInfo.processInfo.environment["MOKUSEI_LOCAL_IMAGES_SOURCE"],
           let directory = ProcessInfo.processInfo.environment["MOKUSEI_LOCAL_IMAGES_ARTIFACTS"] {
            let window = SwiftUIReplay.window(ScrollView {
                ThreadMessage(id: "reported", author: .assistant,
                    content: "截图所示结果的本机图片：\n\n[截图证据](<\(path)>) · [隔离工作树](/tmp)")
                    .padding(32)
            }.background(Color.white), width: 900, height: 800)
            defer { window.close() }
            let root = try #require(window.contentView)
            try await SwiftUIReplay.wait { attachments(root).count == 1 }
            let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("reported-orbit.png"))
        }
    }

    @Test func invalidFilesKeepTheirTextAndNavigation() async throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let invalid = file.deletingLastPathComponent().appendingPathComponent("not-image.png")
        try Data("plain text".utf8).write(to: invalid)
        let unreadable = file.deletingLastPathComponent().appendingPathComponent("unreadable.png")
        try FileManager.default.copyItem(at: file, to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
        let large = file.deletingLastPathComponent().appendingPathComponent("large.png")
        #expect(FileManager.default.createFile(atPath: large.path, contents: nil))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 65 * 1024 * 1024)
        try handle.close()
        let window = SwiftUIReplay.window(NativeMarkdownView(text: """
            [非图片](<\(invalid.path)>) [不存在](/tmp/missing-local-image-\(UUID()).png)

            ![失败后保留替代文字](<\(invalid.path)>)

            [不可读](<\(unreadable.path)>) [超限](<\(large.path)>) [目录](<\(file.deletingLastPathComponent().path)>)

            [远程文件](file://remote-host/tmp/image.png) [危险](javascript:alert)
            """), width: 500)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { texts(root).contains { $0.string.contains("失败后保留替代文字") } }
        try await Task.sleep(for: .milliseconds(300))
        #expect(attachments(root).isEmpty)
        var links: [URL] = []
        for view in texts(root) {
            view.textStorage?.enumerateAttribute(.link, in: NSRange(location: 0, length: view.textStorage?.length ?? 0)) { value, _, _ in
                if let url = value as? URL { links.append(url) }
            }
        }
        #expect(links.count == 6)
        #expect(links.allSatisfy { $0.isFileURL && ($0.host == nil || $0.host == "") })
    }

    @Test func streamingDoesNotResolveLocalImages() async throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let source = "![streaming](<\(file.path)>)"
        let window = SwiftUIReplay.window(ThreadMessage(id: "stream", author: .assistant, content: source, streaming: true))
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { texts(root).contains { $0.string == source } }
        #expect(attachments(root).isEmpty)
    }
}
