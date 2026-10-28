import AppKit
import UniformTypeIdentifiers
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
import MokuseiUI
@testable import MokuseiPluginUI

@MainActor
@Suite(.serializedNative, .serialized)
struct NativeComposerPasteTests {
    enum Content: CaseIterable { case png, tiff, imageFile, copiedFiles, mixed, text }

    private func editor(in view: NSView) -> NSTextView? { SwiftUIReplay.editor(in: view) }

    private func image(_ type: NSBitmapImageRep.FileType) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try #require(bitmap.bitmapData)
        pixels.initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        return try #require(bitmap.representation(using: type, properties: [:]))
    }

    private func provider(_ values: [(UTType, Data)]) -> NSItemProvider {
        let result = NSItemProvider()
        for (type, bytes) in values {
            result.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in completion(bytes, nil); return nil }
        }
        return result
    }
    @Test(.requiresDisplay, arguments: Content.allCases, [false, true])
    func shortcutPastesIntoMoku(content: Content, control: Bool) async throws {
        var received: [NativeComposerFile] = []
        let draft = NativeComposerDraft(services: .init(stageFiles: { files, _ in
            received += files
            return files.enumerated().map { index, file in
                .init(id: JSONText("paste-\(index)"), path: JSONText("/attachments/\(file.name)"), name: JSONText(file.name),
                    mimeType: JSONText(file.mimeType), size: file.size, kind: file.mimeType.hasPrefix("image/") ? .image : .file)
            }
        }, discardAttachments: { _ in }))
        draft.text = "before replace after"
        let window = SwiftUIReplay.window(NativeMokuHistoryComposer(draft: draft, cwd: "/tmp",
            onSend: { _ in }, onCancel: {}), width: 560, height: 220)
        defer { window.close() }
        try await SwiftUIReplay.wait { editor(in: window.contentView!) != nil }
        let input = try #require(editor(in: window.contentView!))
        // Exercise the standard Edit menu key equivalent as well as keyDown.
        let savedMenu = NSApp.mainMenu
        let menu = NSMenu(), edit = NSMenu()
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = edit; menu.addItem(item)
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        NSApp.mainMenu = menu
        defer { NSApp.mainMenu = savedMenu }
        let board = NSPasteboard.general
        let saved: [NSPasteboardItem] = board.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        defer { board.clearContents(); board.writeObjects(saved) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("copied image.png")
        let document = directory.appendingPathComponent("notes.txt")
        try image(.png).write(to: file); try Data("notes".utf8).write(to: document)
        let first = NSPasteboardItem()
        var items = [first]
        switch content {
        case .png, .mixed:
            first.setData(try image(.png), forType: .png)
            first.setData(try image(.tiff), forType: .tiff)
            if content == .mixed { first.setString("说明文字", forType: .string) }
        case .tiff: first.setData(try image(.tiff), forType: .tiff)
        case .imageFile, .copiedFiles:
            first.setString(file.absoluteString, forType: .fileURL)
            first.setString(file.lastPathComponent, forType: .string)
            first.setData(try image(.png), forType: .png) // URL wins over a Finder preview.
            if content == .copiedFiles {
                let second = NSPasteboardItem()
                second.setString(document.absoluteString, forType: .fileURL); items.append(second)
            }
        case .text: first.setString("普通文本 👋", forType: .string)
        }
        board.clearContents(); board.writeObjects(items)
        window.makeFirstResponder(input)
        input.setSelectedRange(NSRange(location: 7, length: 7))
        let beforePaste = input.string
        try pasteKey(window: window, control: control)
        if content == .text {
            // Ctrl-V is a native macOS editing command for text-only clipboards.
            if !control {
                #expect(NativeComposerPaste.attachmentProviders(from: board).isEmpty)
                // The isolated AppKit host dispatches Edit > Paste itself.
                // A non-running test host may need the native action, but only
                // while the shortcut has left the original editor text intact.
                if !NSApp.isRunning, input.string.utf16.elementsEqual(beforePaste.utf16) {
                    input.paste(nil)
                }
                try await Task.sleep(for: .milliseconds(100))
                #expect(draft.text == "before 普通文本 👋 after")
                #expect(input.string == draft.text)
            }
            else { try await Task.sleep(for: .milliseconds(100)) }
            #expect(received.isEmpty && draft.attachments.isEmpty)
        } else {
            try await SwiftUIReplay.wait { !draft.importing && !received.isEmpty }
            #expect(received.count == (content == .copiedFiles ? 2 : 1))
            #expect(draft.attachments.count == received.count && draft.error == nil)
            #expect(draft.text == (content == .mixed ? "before 说明文字 after" : "before replace after"))
            #expect(input.string == draft.text)
            #expect(received.first?.mimeType == "image/png")
            if content == .imageFile || content == .copiedFiles {
                guard case .file(let url) = received.first?.source else { Issue.record("Expected file URL"); return }
                #expect(url == file)
            } else {
                guard case .bytes(let data) = received.first?.source else { Issue.record("Expected image bytes"); return }
                #expect(NSBitmapImageRep(data: data)?.pixelsWide == 2)
            }
            try await Task.sleep(for: .milliseconds(100))
            #expect(received.count == (content == .copiedFiles ? 2 : 1)) // No native/SwiftUI double import.
        }
    }
    @Test(.requiresDisplay, arguments: [false, true])
    func immediateAttachmentPasteRetainsNewlyAcquiredFocus(control: Bool) async throws {
        let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in
            [.init(id: "focus-file", path: "/tmp/focus-file", name: "image.png", mimeType: "image/png", size: 1, kind: .image)]
        }, discardAttachments: { _ in }))
        let window = SwiftUIReplay.window(NativeMokuHistoryComposer(draft: draft, cwd: "/tmp",
            suppressInitialFocus: true, onSend: { _ in }, onCancel: {}), width: 560, height: 220)
        defer { window.close() }
        try await SwiftUIReplay.wait { editor(in: window.contentView!) != nil }
        let input = try #require(editor(in: window.contentView!))
        window.makeFirstResponder(nil)
        try await Task.sleep(for: .milliseconds(100))
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let bytes = item.data(forType: type) { copy.setData(bytes, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        board.clearContents(); board.setData(try image(.png), forType: .png)
        // No text/selection edit may publish focus before this shortcut.
        #expect(window.makeFirstResponder(input))
        try pasteKey(window: window, control: control)
        try await SwiftUIReplay.wait { !draft.importing && draft.attachments.count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.firstResponder === input)
        #expect(editor(in: window.contentView!) === input)
        #expect(draft.text.isEmpty && draft.error == nil)
    }
    @Test(.requiresDisplay, arguments: [20, 200])
    func filePasteReservesDraftBeforeImmediateReturn(count: Int) async throws {
        var sends = 0
        let draft = NativeComposerDraft(services: .init(stageFiles: { files, _ in
            files.enumerated().map { index, file in
                .init(id: JSONText("reserved-\(index)"), path: JSONText("/tmp/reserved-\(index)"),
                    name: JSONText(file.name), mimeType: JSONText(file.mimeType), size: file.size, kind: .file)
            }
        }, discardAttachments: { _ in }))
        draft.text = "Keep this request until the paste is resolved"
        let window = SwiftUIReplay.window(NativeMokuHistoryComposer(draft: draft, cwd: "/tmp",
            onSend: { _ in sends += 1 }, onCancel: {}), width: 560, height: 220)
        defer { window.close() }
        try await SwiftUIReplay.wait { editor(in: window.contentView!) != nil }
        let input = try #require(editor(in: window.contentView!))
        window.makeFirstResponder(input)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.txt")
        try Data("fixture".utf8).write(to: file)
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let bytes = item.data(forType: type) { copy.setData(bytes, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        board.clearContents()
        board.writeObjects((0..<count).map { _ in
            let item = NSPasteboardItem(); item.setString(file.absoluteString, forType: .fileURL); return item
        })
        input.paste(nil)
        #expect(draft.importing && !draft.canSubmit)
        input.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)))
        #expect(sends == 0)
        try await SwiftUIReplay.wait { !draft.importing }
        #expect(sends == 0 && !draft.text.isEmpty)
        #expect(draft.attachments.count == (count == 20 ? 20 : 0))
        #expect((draft.error != nil) == (count > 20))
    }

    @discardableResult
    private func pasteKey(window: NSWindow, control: Bool) throws -> NSEvent {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: control ? .control : .command, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: control ? "\u{16}" : "v",
            charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        NSApp.sendEvent(event)
        return event
    }
    @Test(.requiresDisplay, arguments: [false, true])
    func attachmentShortcutLeavesMarkedTextAndOtherEditorsAlone(control: Bool) async throws {
        let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in
            Issue.record("Marked text or another editor must not import into Moku"); return []
        }, discardAttachments: { _ in }))
        let window = SwiftUIReplay.window(NativeMokuHistoryComposer(draft: draft, cwd: "/tmp",
            onSend: { _ in }, onCancel: {}), width: 560, height: 220)
        defer { window.close() }
        try await SwiftUIReplay.wait { editor(in: window.contentView!) != nil }
        let input = try #require(editor(in: window.contentView!))
        let board = NSPasteboard.general
        let saved: [NSPasteboardItem] = board.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        defer { board.clearContents(); board.writeObjects(saved) }
        board.clearContents(); board.setData(try image(.png), forType: .png)
        input.setMarkedText("拼音", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(input.hasMarkedText())
        try pasteKey(window: window, control: control)
        #expect(input.string == "拼音")
        try await Task.sleep(for: .milliseconds(100))
        #expect(draft.attachments.isEmpty && !draft.importing)
        input.unmarkText()

        let other = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 220))
        // Same window, different editor: the monitor must not use Moku's draft.
        window.contentView!.addSubview(other)
        window.makeFirstResponder(other)
        try pasteKey(window: window, control: control)
        try await Task.sleep(for: .milliseconds(100))
        #expect(draft.attachments.isEmpty && !draft.importing)
    }
    @Test(arguments: Content.allCases)
    func pasteProvidersStageAttachmentsAndPreserveText(content: Content) async throws {
        var received: [NativeComposerFile] = []
        let draft = NativeComposerDraft(services: .init(stageFiles: { files, _ in
            received += files
            return files.enumerated().map { index, file in
                .init(id: JSONText("staged-\(index)"), path: JSONText("/attachments/\(file.name)"), name: JSONText(file.name),
                      mimeType: JSONText(file.mimeType), size: file.size, kind: file.mimeType.hasPrefix("image/") ? .image : .file)
            }
        }, discardAttachments: { _ in }))
        draft.text = "replace"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try image(.png), tiff = try image(.tiff)
        let file = directory.appendingPathComponent("copied image.png")
        let document = directory.appendingPathComponent("notes.txt")
        try png.write(to: file); try Data("notes".utf8).write(to: document)
        let providers: [NSItemProvider]
        switch content {
        case .png: providers = [provider([(.png, png), (.tiff, tiff)])]
        case .tiff: providers = [provider([(.tiff, tiff)])]
        case .mixed: providers = [provider([(.png, png), (.tiff, tiff), (.utf8PlainText, Data("说明文字".utf8))])]
        case .text: providers = [provider([(.utf8PlainText, Data("普通文本 👋".utf8))])]
        case .imageFile: providers = [provider([(.fileURL, file.dataRepresentation)])]
        case .copiedFiles: providers = [provider([(.fileURL, file.dataRepresentation)]), provider([(.fileURL, document.dataRepresentation)])]
        }
        let paste = await NativeComposerPaste.load(providers)
        draft.text = paste.replacingText(in: draft.text, selection: NSRange(location: 0, length: draft.text.utf16.count))
        await draft.importFiles(paste.files)
        if content == .text {
            #expect(draft.text == "普通文本 👋" && received.isEmpty)
        } else {
            #expect(draft.text == (content == .mixed ? "说明文字" : "replace"))
            #expect(received.count == (content == .copiedFiles ? 2 : 1))
            #expect(draft.attachments.count == received.count && draft.error == nil)
            #expect(received.first?.mimeType == "image/png")
            if content == .imageFile || content == .copiedFiles {
                guard case .file(let url) = received.first?.source else { Issue.record("Expected local source"); return }
                #expect(url == file)
            } else {
                guard case .bytes(let bytes) = received.first?.source else { Issue.record("Expected image bytes"); return }
                #expect(NSBitmapImageRep(data: bytes)?.pixelsWide == 2)
            }
        }
    }
}
