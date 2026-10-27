import AppKit
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
import MokuseiPluginAPI
@testable import MokuseiPluginUI
@testable import MokuseiHarnessCodex
@testable import MokuseiSidecardBrowser
@testable import MokuseiUI

@MainActor @Suite(.serializedNative, .serialized)
struct NativePerformanceCacheTests {
    @Test func codexCacheOwnsRawAndFallbackAndCachesFailures() throws {
        let cache = CodexStateCache()
        let valid: JSONValue = .object(["schema": .text("mokusei.harness.codex.thread.v1"), "updatedAt": .number(1),
                                       "turns": .array([]), "backgroundTerminals": .array([])])
        for _ in 0..<10 { #expect(try cache.decode(valid).get().turns.isEmpty) }
        #expect(cache.decodeCount == 1)
        let invalid: JSONValue = .object(["schema": .text("invalid")])
        for _ in 0..<10 {
            if case .success = cache.decode(invalid) { Issue.record("Invalid state admitted") }
        }
        #expect(cache.decodeCount == 2)
        #expect(try cache.decode(valid).get().updatedAt == 1)
        #expect(cache.decodeCount == 3)
        #expect(try cache.decode(.null, createdAt: 42).get().updatedAt == 42)
        #expect(try cache.decode(.null, createdAt: 43).get().updatedAt == 43)
        #expect(cache.decodeCount == 5)
        // A remounted resource/scope starts its own owner, even at the same wire
        // revision. No static cache can leak a prior authority's decode.
        let remounted = CodexStateCache()
        _ = remounted.decode(valid)
        #expect(remounted.decodeCount == 1)
    }


    @Test func invalidTIFFFallsBackToTextAndPNGHasPriority() async throws {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.tiff.identifier, visibility: .all) { completion in completion(Data([1, 2, 3]), nil); return nil }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { completion in completion(Data("fallback".utf8), nil); return nil }
        let fallback = await NativeComposerPaste.load([provider])
        #expect(fallback.files.isEmpty && fallback.text == "fallback")
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in completion(Data([4, 5]), nil); return nil }
        let pasted = await NativeComposerPaste.load([provider])
        #expect(pasted.files.count == 1 && pasted.text == "fallback")
        let file = try #require(pasted.files.first)
        #expect(file.mimeType == "image/png" && !file.clipboardTIFF)
        if case .bytes(let bytes) = file.source { #expect(bytes == Data([4, 5])) }
    }

    @Test(arguments: Array(1...8)) func tiffOrientationMatchesLegacyPNGConversion(orientation: Int) async throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 3,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<3 { for x in 0..<2 {
            bitmap.setColor(NSColor(deviceRed: CGFloat(x), green: CGFloat(y) / 2, blue: 0, alpha: x == 0 && y == 0 ? 0 : 1), atX: x, y: y)
        } }
        let tiff = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(tiff, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(bitmap.cgImage), [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let legacy = try #require(NSBitmapImageRep(data: tiff as Data)?.representation(using: .png, properties: [:]))
        let prepared = try await NativeRasterPreparation.shared.prepare([.clipboard(tiff: tiff as Data)])
        let file = try #require(prepared.compactMap { $0 }.first)
        guard case .bytes(let png) = file.source else { Issue.record("Expected PNG bytes"); return }
        func orientationTag(_ data: Data) throws -> Int {
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            return (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        }
        #expect(try orientationTag(png) == orientationTag(legacy))
        let actual = try #require(NSBitmapImageRep(data: png)), expected = try #require(NSBitmapImageRep(data: legacy))
        #expect(actual.pixelsWide == expected.pixelsWide && actual.pixelsHigh == expected.pixelsHigh)
        for y in 0..<expected.pixelsHigh { for x in 0..<expected.pixelsWide {
            #expect(actual.colorAt(x: x, y: y) == expected.colorAt(x: x, y: y))
        } }
    }

    private func thread(_ revision: Int = 0) throws -> HarnessThread {
        try .init(id: "t", harnessID: "fixture", revision: revision, sessionState: .null,
                  observation: .init(), cwd: "/tmp", settings: .object([:]), createdAt: 0, updatedAt: 0, title: "T", tags: [])
    }

    @Test func materializationRetainsEnvelopeAndValidatesChangedContentAtFullDepth() throws {
        let cache = NativeThreadMaterializationCache(), original = try thread()
        let state: JSONValue = .object(["text": .text("😀")])
        for _ in 0..<10 {
            let result = try cache.thread(original, content: state)
            #expect(result.sessionState == state && result.json["sessionState"] == state)
        }
        #expect(cache.materializationCount == 1)
        #expect(throws: (any Error).self) { try cache.thread(original, content: .number(.infinity)) }
        #expect(throws: (any Error).self) { try cache.thread(original, content: .number(.infinity)) }
        #expect(cache.materializationCount == 2)
        var deep: JSONValue = .null
        for _ in 0..<JSONValue.maximumDepth { deep = .array([deep]) }
        try PluginJSONValidation.validate(deep)
        #expect(throws: (any Error).self) { try cache.thread(original, content: deep) }
        #expect(try cache.thread(thread(1), content: state).revision == 1)
        cache.clear()
        #expect(try cache.thread(original, content: state).sessionState == state)
    }

    @Test func nativeLineCacheMatchesTabsUnicodeAndFontChanges() {
        let cache = NativeLineWidthCache(), font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let paragraph = NSMutableParagraphStyle(); paragraph.defaultTabInterval = 32; paragraph.tabStops = []
        for text in ["context", "👩‍💻 e\u{301} 中文", "a\tb", ""] {
            let expected = (text as NSString).size(withAttributes: [.font: font, .paragraphStyle: paragraph]).width
            #expect(cache.width(text, font: font, paragraph: paragraph) == expected)
            #expect(cache.width(text, font: font, paragraph: paragraph) == expected)
        }
        #expect(cache.measurementCount == 4)
        paragraph.defaultTabInterval = 48
        _ = cache.width("a\tb", font: font, paragraph: paragraph)
        _ = cache.width("context", font: NSFont.systemFont(ofSize: 14))
        #expect(cache.measurementCount == 6)
    }

    @Test func annotationWriterPreservesOrderAndCleansCancelledBatch() async throws {
        let writer = BrowserAnnotationFiles()
        let bytes = [Data([1, 2]), Data([3, 4])]
        let batch = try await writer.write(bytes)
        #expect(batch.files.map(\.lastPathComponent) == ["annotation-1.png", "annotation-2.png"])
        #expect(try batch.files.map { try Data(contentsOf: $0) } == bytes)
        await writer.remove(batch.directory)
        #expect(!FileManager.default.fileExists(atPath: batch.directory.path))
        let task = Task { try Task.checkCancellation(); return try await writer.write(bytes) }
        task.cancel()
        do {
            let late = try await task.value
            await writer.remove(late.directory)
            Issue.record("Cancelled writer completed")
        } catch is CancellationError { }
    }

    @Test func disposedDraftCannotStagePreparedTIFF() async throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try #require(bitmap.bitmapData)
        bytes.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let tiff = try #require(bitmap.representation(using: .tiff, properties: [:]))
        let input = NativeComposerFile.clipboard(tiff: tiff)
        let prepared = try await NativeRasterPreparation.shared.prepare([input])
        let output = try #require(prepared.compactMap { $0 }.first)
        #expect(output.mimeType == "image/png")
        if case .bytes(let data) = output.source {
            let rep = try #require(NSBitmapImageRep(data: data))
            #expect(rep.pixelsWide == 2 && rep.pixelsHigh == 2 && rep.hasAlpha)
            #expect(rep.colorAt(x: 0, y: 0)?.alphaComponent == 0)
        }
        var stages = 0
        let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in stages += 1; return [] }, discardAttachments: { _ in }))
        let entered = Mutex(false), release = DispatchSemaphore(value: 0)
        let blocker = Task.detached { await NativeRasterPreparation.shared.holdForTesting({ entered.withLock { $0 = true } }, release) }
        defer { release.signal() }
        for _ in 0..<200 where !entered.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(entered.withLock { $0 })
        let importTask = Task { await draft.importFiles([input]) }
        for _ in 0..<200 where !draft.importing { await Task.yield() }
        #expect(draft.importing)
        await draft.dispose()
        release.signal()
        await importTask.value; await blocker.value
        #expect(stages == 0 && draft.attachments.isEmpty)
    }
}

extension NativePerformanceCacheTests {
    @Test func catalogAdmissionIsAtomicAndApplicationCacheTracksFullRawIdentity() throws {
        let catalog = NativeWorkspaceCatalog(), original = try thread()
        func application(_ title: String, type: JSONText = "report") -> JSONValue {
            .object(["id": .text("app"), "ref": ApplicationThreadRef(threadID: "app", typeID: type).json,
                "revision": .integer(1), "createdAt": .number(0), "updatedAt": .number(0), "title": .text(title), "archived": .bool(false),
                "tags": .object(["tags": .array([]), "semanticTags": .array([]), "tagEmojis": .object([:]), "directoryTags": .array([])]),
                "presentations": .array([]), "view": .null])
        }
        func snapshot(_ revision: Int, threads: [JSONValue], apps: [JSONValue]) -> JSONValue {
            .object(["revision": .integer(revision), "settingsRevision": .integer(0), "defaultCwd": .text("/tmp"),
                "settings": .object([:]), "executions": .array([]), "threads": .array(threads), "applicationThreads": .array(apps)])
        }
        let ref = ApplicationThreadRef(threadID: "app", typeID: "report")
        try catalog.install(snapshot(1, threads: [original.json], apps: [application("first")]))
        for _ in 0..<10 { #expect(try catalog.applicationEntry(ref).title == "first") }
        #expect(catalog.applicationAdmissionCount == 1)
        #expect(throws: (any Error).self) { try catalog.install(snapshot(2, threads: [original.json, original.json], apps: [])) }
        #expect(catalog.revision == 1 && catalog.thread("t") == original)
        try catalog.install(snapshot(2, threads: [original.json], apps: [application("changed")]))
        #expect(try catalog.applicationEntry(ref).title == "changed") // same revision, changed raw
        #expect(catalog.applicationAdmissionCount == 2)
        try catalog.install(snapshot(3, threads: [], apps: [application("replacement", type: "git")]))
        #expect(throws: (any Error).self) { try catalog.applicationEntry(ref) }
        #expect(catalog.thread("t") == nil)
        #expect(try catalog.applicationEntry(.init(threadID: "app", typeID: "git")).title == "replacement")
        catalog.invalidateApplicationEntries()
        _ = try catalog.applicationEntry(.init(threadID: "app", typeID: "git"))
        #expect(catalog.applicationAdmissionCount == 4)
    }
}

extension NativeRasterPreparation {
    func holdForTesting(_ entered: @Sendable () -> Void, _ release: DispatchSemaphore) {
        entered()
        _ = release.wait(timeout: .now() + 5)
    }
}
