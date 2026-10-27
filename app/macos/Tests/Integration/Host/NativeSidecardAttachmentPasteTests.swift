import AppKit
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import MokuseiSidecardConversation

@MainActor @Suite(.serializedNative, .serialized)
struct NativeSidecardAttachmentPasteTests {
    enum Content: CaseIterable { case png, tiff, files, mixed, text }

    private func presentation(stage: @escaping ([SidecardAttachmentSource], PluginLifetime) async throws -> [SidecardImportedAttachment],
                              send: @escaping (JSONValue) async throws -> SidecardSendReceipt,
                              discard: @escaping ([JSONText]) async throws -> Void = { _ in },
                              limit: Int = 20, lifetime: PluginLifetime) throws -> ConversationSidecardPresentation {
        let thread = try HarnessThread(id: "paste", harnessID: "fixture", revision: 0, sessionState: .null,
            observation: .init(), cwd: "/tmp", settings: .object([:]), createdAt: 0, updatedAt: 0, title: "Paste", tags: [])
        let actions = HarnessThreadActions(interrupt: {}, respond: { _ in }, invokeHarnessExtension: { _, _ in .null },
            forkThread: { _ in "fork" }, openExternal: { _ in }, openFollowUp: { _ in })
        let context = SidecardContext(thread: thread, conversationIndex: nil, actions: actions, readingTarget: nil,
            executionDisabled: false, expanded: true, transitioning: false, suppressed: false,
            conversation: { _, _ in AnyView(EmptyView()) }, voice: nil, open: { 0 }, close: {}, selectionRevision: { 0 },
            onIntent: { _ in {} }, send: send, stageAttachments: { _ in [] }, discardAttachments: discard,
            backToOverview: {}, attachmentImport: .init(stage: stage, policy: { _ in
                RuntimeAttachmentPolicy(imageBytes: 1_000_000, pdfBytes: 1_000_000, fileBytes: 1_000_000,
                    messageBytes: 2_000_000, messageCount: limit)
            }))
        return ConversationSidecardPresentation(context: context, lifetime: lifetime)
    }

    private func png(_ type: NSBitmapImageRep.FileType = .png) throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try #require(rep.representation(using: type, properties: [:]))
    }

    private func paste(in window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        NSApp.sendEvent(event)
    }

    @Test(.requiresDisplay, arguments: Content.allCases)
    func shortcutDisplaysRemovesAndSendsAttachments(content: Content) async throws {
        let lifetime = PluginLifetime()
        defer { lifetime.cancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var staged = 0, sent: [JSONValue] = [], discarded: [JSONText] = []
        let card = try presentation(stage: { sources, _ in
            try sources.map { source in
                staged += 1
                let name: String, mime: String, size: Int, path: URL
                switch source {
                case .file(let url): name = url.lastPathComponent; mime = "text/plain"; size = 5; path = url
                case .bytes(let bytes, let filename, let type):
                    name = filename; mime = type; size = bytes.count
                    path = directory.appendingPathComponent("\(staged)-\(filename)")
                    try bytes.write(to: path)
                }
                return .init(id: JSONText("file-\(staged)"), path: JSONText(path.path), name: JSONText(name),
                    mimeType: JSONText(mime), size: size, kind: mime.hasPrefix("image/") ? .image : .file)
            }
        }, send: { input in sent.append(input); return .init(executionID: "accepted") },
            discard: { discarded += $0 }, lifetime: lifetime)
        card.changeDraft("before replace after")
        let window = SwiftUIReplay.window(ConversationExecutionPane(presentation: card)
            .background(Color.white).environment(\.colorScheme, .light), width: 420, height: 400)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { SwiftUIReplay.editor(in: root) != nil }
        let editor = try #require(SwiftUIReplay.editor(in: root))
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let first = NSPasteboardItem()
        var items = [first]
        switch content {
        case .png, .mixed:
            first.setData(try png(), forType: .png)
            first.setData(try png(.tiff), forType: .tiff) // One clipboard item must yield one attachment.
            if content == .mixed { first.setString("说明文字", forType: .string) }
        case .tiff: first.setData(try png(.tiff), forType: .tiff)
        case .files:
            for index in 0..<2 {
                let url = directory.appendingPathComponent("notes \(index).txt")
                try Data("notes".utf8).write(to: url)
                let item = index == 0 ? first : NSPasteboardItem()
                item.setString(url.absoluteString, forType: .fileURL)
                item.setString(url.lastPathComponent, forType: .string)
                item.setData(try png(), forType: .png) // Finder preview must not duplicate the file.
                if index > 0 { items.append(item) }
            }
        case .text: first.setString("普通文本 👋", forType: .string)
        }
        board.clearContents(); board.writeObjects(items)
        if content == .png {
            let other = SwiftUIReplay.window(NativeComposerTextInput(value: .constant("other"), placeholder: "Other", onSubmit: {}),
                width: 300, height: 100)
            try await SwiftUIReplay.wait { SwiftUIReplay.editor(in: other.contentView!) != nil }
            let otherEditor = try #require(SwiftUIReplay.editor(in: other.contentView!))
            other.makeFirstResponder(otherEditor)
            try paste(in: other)
            try await Task.sleep(for: .milliseconds(100))
            #expect(staged == 0 && card.attachments.attachments.isEmpty)
            other.close()
            window.makeKeyAndOrderFront(nil)
        }
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 7, length: 7))
        try paste(in: window)
        if content == .text {
            // The XCTest runner has no app Edit-menu dispatcher; invoke the native action left by the bridge.
            editor.paste(nil)
            try await SwiftUIReplay.wait { card.draft == "before 普通文本 👋 after" }
            #expect(staged == 0 && card.attachments.attachments.isEmpty)
        } else {
            let count = content == .files ? 2 : 1
            try await SwiftUIReplay.wait { staged == count && !card.attachments.importing }
            #expect(card.attachments.attachments.count == count)
            #expect(card.draft == (content == .mixed ? "before 说明文字 after" : "before replace after"))
            #expect(card.canSend)
            let removed = try #require(card.attachments.attachments.first)
            let removedID = try #require(removed.attachment?.id)
            await card.attachments.removeAttachment(removed.id)
            #expect(discarded == [removedID])
            #expect(card.attachments.attachments.count == count - 1)
            // A second deliberate paste adds one batch, with no duplicate native/SwiftUI delivery.
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(editor)
            try paste(in: window)
            try await SwiftUIReplay.wait { staged == count * 2 && !card.attachments.importing }
            #expect(card.attachments.attachments.count == count * 2 - 1)
            #expect(card.attachments.error == nil)
            if content != .files {
                try await SwiftUIReplay.wait { card.attachments.attachments.allSatisfy { $0.preview != nil } }
            }
            if content != .mixed { card.changeDraft("") } // Attachment-only send is admitted.
        }
        let expectedIDs = card.attachments.attachments.compactMap(\.attachment).map(\.id)
        let expectedText = NativeComposerSubmissionPolicy.trimmedText(card.draft)
        await card.send()
        #expect(sent.count == 1)
        let parts = try #require(sent.first?["parts"]?.arrayValue)
        #expect(parts.compactMap { $0["file"]?["id"]?.stringValue } == expectedIDs.map(\.string))
        #expect(parts.compactMap { $0["text"]?.stringValue } == (expectedText.isEmpty ? [] : [expectedText]))
        #expect(!parts.contains { $0["file"]?["id"] == .string(discarded.first ?? "removed") })
        #expect(card.attachments.attachments.isEmpty && card.draft.isEmpty && !card.canSend)
        await card.send()
        #expect(sent.count == 1)
    }

    @Test func pendingRemovalAndLimitsUseSharedDraftPolicy() async throws {
        let lifetime = PluginLifetime()
        defer { lifetime.cancel() }
        var receipt: CheckedContinuation<[SidecardImportedAttachment], Never>?
        var discarded: [JSONText] = [], sends = 0
        let card = try presentation(stage: { _, _ in await withCheckedContinuation { receipt = $0 } },
            send: { _ in sends += 1; return .init(executionID: "sent") }, discard: { discarded += $0 }, limit: 1, lifetime: lifetime)
        card.changeDraft("keep text")
        let file = NativeComposerFile(data: try png(), name: "paste.png", mimeType: "image/png")
        let importing = Task { await card.importFiles([file]) }
        try await SwiftUIReplay.wait { receipt != nil }
        #expect(!card.canSend)
        await card.send()
        #expect(sends == 0)
        await card.importFiles([file])
        #expect(card.attachments.error == "附件正在处理中，请稍候")
        await card.attachments.removeAttachment(try #require(card.attachments.attachments.first?.id))
        receipt?.resume(returning: [.init(id: "late", path: "/staged/paste.png", name: "paste.png", mimeType: "image/png", size: 10, kind: .image)])
        await importing.value
        #expect(card.attachments.attachments.isEmpty && discarded == ["late"])
        await card.importFiles([file, file])
        #expect(card.attachments.error == "附件数量超过主机限制")
        #expect(card.draft == "keep text" && sends == 0)
    }
}
