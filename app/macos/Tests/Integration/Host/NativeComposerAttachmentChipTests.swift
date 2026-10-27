import AppKit
import Foundation
import MokuseiCore
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiPluginUI

@MainActor
@Suite(.serializedNative, .serialized)
struct NativeComposerAttachmentChipTests {
    @Test(arguments: [false, true])
    func hostFilePreviewPreservesReferenceAndRetiresWithDraft(retireBeforeCompletion: Bool) async throws {
        let started = StagingGate(), completion = StagingGate()
        let reference = RuntimeHostFileReference(hostID: "paired-host", path: "/host/project/report.pdf", revision: "file-generation")
        var received: RuntimeHostFileReference?
        var presented = false
        let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in
            Issue.record("Preview must not stage or submit a file"); return []
        }, openHostFile: { incoming, lifetime in
            received = incoming; started.open()
            await completion.suspend()
            try lifetime.checkCancellation()
            presented = true
        }, discardAttachments: { _ in }))
        #expect(draft.canPreviewHostFiles)
        let operation = Task { try await draft.openHostFile(reference) }
        await started.suspend()
        if retireBeforeCompletion { await draft.dispose() }
        completion.open()
        do {
            try await operation.value
            #expect(!retireBeforeCompletion)
        } catch is CancellationError { #expect(retireBeforeCompletion) }
        #expect(received == reference)
        #expect(presented == !retireBeforeCompletion)
        #expect(draft.attachments.isEmpty)
        await draft.dispose()
    }

    @Test func hostFilePreviewReportsFailureWithoutChangingDraft() async throws {
        let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, openHostFile: { _, _ in
            throw RuntimeError("FILE_CHANGED", "Select the changed host file again")
        }, discardAttachments: { _ in }))
        draft.text = "Unsent text remains on this device"
        do {
            try await draft.openHostFile(.init(hostID: "paired-host", path: "/host/report.pdf"))
            Issue.record("A failed host preview must reach its picker")
        } catch let failure as RuntimeError { #expect(failure.code == "FILE_CHANGED") }
        #expect(draft.text == "Unsent text remains on this device" && draft.attachments.isEmpty)
        await draft.dispose()
    }

    @Test func radiusIsConcentricWithTheHostAndCappedByChipHeight() {
        // Moku's 29pt capsule: 29 - 12 = 17pt concentric arc, drawn as the
        // 28pt chip's largest possible radius (a 14pt capsule).
        #expect(NativeComposerChipMetrics.radius(containerRadius: 29) == 14)
        // The full composer's 15pt container: 15 - 12 = 3pt.
        #expect(NativeComposerChipMetrics.radius(containerRadius: 15) == 3)
        // A container at or below the chip inset has no inner corner to follow.
        #expect(NativeComposerChipMetrics.radius(containerRadius: 12) == 0)
        #expect(NativeComposerChipMetrics.radius(containerRadius: 4) == 0)
        // A very large host still cannot exceed half the chip height.
        #expect(NativeComposerChipMetrics.radius(containerRadius: 100) == 14)
    }

    @Test func imagePreviewRadiusRemainsARoundedSquare() {
        #expect(NativeComposerChipMetrics.imageSize == 56)
        // Moku's capsule would otherwise derive a 17pt radius, past the point
        // where a 56pt square reads as a rounded tile.
        #expect(NativeComposerChipMetrics.imageRadius(containerRadius: 29) == 14)
        // The full composer's tight corner still keeps a visible 8pt rounding.
        #expect(NativeComposerChipMetrics.imageRadius(containerRadius: 15) == 8)
        #expect(NativeComposerChipMetrics.imageRadius(containerRadius: 4) == 8)
        #expect(NativeComposerChipMetrics.imageRadius(containerRadius: 100) == 14)
    }

    @Test func thumbnailLoaderDownsamplesManagedImage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("pasted-image.png")
        let png = try solidPNG(width: 300, height: 200, NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        try png.write(to: file)

        let thumbnail = try #require(await NativeComposerThumbnailLoader.load(
            path: file.path, maxPixelSize: 112))
        #expect(max(thumbnail.width, thumbnail.height) <= 112)
        #expect(thumbnail.width > 0 && thumbnail.height > 0)
        let missing = await NativeComposerThumbnailLoader.load(
            path: directory.appendingPathComponent("missing.png").path, maxPixelSize: 112)
        #expect(missing == nil)
    }

    @Test(.requiresDisplay, arguments: [ColorScheme.light, .dark])
    func imageAttachmentStripRendersDecodedThumbnail(scheme: ColorScheme) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("pasted-image.png")
        try solidPNG(width: 300, height: 200, NSColor(srgbRed: 0.9, green: 0.05, blue: 0.05, alpha: 1)).write(to: file)

        let attachment = NativeComposerAttachment(id: "image", name: "pasted-image.png",
            status: .ready(.init(id: "image", path: JSONText(file.path), name: "pasted-image.png",
                mimeType: "image/png", size: 1, kind: .image)))
        let strip = NativeComposerAttachmentChips(attachments: [attachment],
            containerRadius: 29, onRemove: { _ in })
            .environment(\.colorScheme, scheme)
        let window = SwiftUIReplay.window(strip, width: 320, height: 140)
        defer { window.close() }
        let host = try #require(window.contentView)

        // The fixture is solid red; wait (callback-style, no fixed 3s frame
        // budget) until the async ImageIO thumbnail lands.
        try await SwiftUIReplay.wait(timeout: .seconds(8)) { containsColor(in: host, Self.isRed) }
    }

    @Test func removingImageChipClearsDraftAndDiscardsStagedAttachment() async throws {
        let png = try solidPNG(width: 2, height: 2, NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        var discarded: [JSONText] = []
        let draft = NativeComposerDraft(services: .init(stageFiles: { files, _ in
            files.map { file in
                .init(id: "staged-image", path: "/tmp/staged-image.png", name: JSONText(file.name),
                    mimeType: JSONText(file.mimeType), size: file.size, kind: .image)
            }
        }, discardAttachments: { ids in discarded += ids }))
        await draft.importFiles([.init(data: png, name: "pasted-image.png", mimeType: "image/png")])
        #expect(draft.attachments.count == 1 && draft.attachments[0].pending == false)
        await draft.removeAttachment(draft.attachments[0].id)
        #expect(draft.attachments.isEmpty)
        #expect(discarded == ["staged-image"])
    }

    // MARK: - Pending previews

    @Test(.requiresDisplay, arguments: [ColorScheme.light, .dark])
    func pendingImageChipRendersDecodedPreview(scheme: ColorScheme) async throws {
        let red = try solidPNG(width: 300, height: 200, NSColor(srgbRed: 0.9, green: 0.05, blue: 0.05, alpha: 1))
        let preview = try #require(await NativeComposerPreviewGenerator.make(
            .init(data: red, name: "pasted-image.png", mimeType: "image/png")))
        #expect(max(preview.data.count, 0) > 0)

        let attachment = NativeComposerAttachment(id: "pending-image", name: "pasted-image.png",
            status: .pending(size: red.count, mimeType: "image/png"), preview: preview)
        let strip = NativeComposerAttachmentChips(attachments: [attachment],
            containerRadius: 29, onRemove: { _ in })
            .environment(\.colorScheme, scheme)
        let window = SwiftUIReplay.window(strip, width: 320, height: 140)
        defer { window.close() }
        let host = try #require(window.contentView)

        // The preview decodes off the main actor; wait until its pixels land.
        try await SwiftUIReplay.wait(timeout: .seconds(8)) { containsColor(in: host, Self.isRed) }
    }

    @Test(.requiresDisplay, arguments: [ColorScheme.light, .dark])
    func pendingImageChipWithoutPreviewFallsBackToPlaceholder(scheme: ColorScheme) async throws {
        let attachment = NativeComposerAttachment(id: "pending-image", name: "broken.png",
            status: .pending(size: 4, mimeType: "image/png"))
        let strip = NativeComposerAttachmentChips(attachments: [attachment],
            containerRadius: 29, onRemove: { _ in })
            .environment(\.colorScheme, scheme)
        let window = SwiftUIReplay.window(strip, width: 320, height: 140)
        defer { window.close() }
        let host = try #require(window.contentView)
        #expect(!containsColor(in: host, Self.isRed))
    }

    @Test(.requiresDisplay, arguments: [ColorScheme.light, .dark])
    func twoPendingImageChipsRenderIndependentPreviews(scheme: ColorScheme) async throws {
        let red = try solidPNG(width: 300, height: 200, NSColor(srgbRed: 0.9, green: 0.05, blue: 0.05, alpha: 1))
        let blue = try solidPNG(width: 200, height: 300, NSColor(srgbRed: 0.05, green: 0.05, blue: 0.9, alpha: 1))
        let redPreview = try #require(await NativeComposerPreviewGenerator.make(
            .init(data: red, name: "pasted-image.png", mimeType: "image/png")))
        let bluePreview = try #require(await NativeComposerPreviewGenerator.make(
            .init(data: blue, name: "pasted-image.png", mimeType: "image/png")))

        // Same display name, distinct identities: ForEach must not cross them.
        let attachments = [
            NativeComposerAttachment(id: "a", name: "pasted-image.png",
                status: .pending(size: red.count, mimeType: "image/png"), preview: redPreview),
            NativeComposerAttachment(id: "b", name: "pasted-image.png",
                status: .pending(size: blue.count, mimeType: "image/png"), preview: bluePreview)
        ]
        let strip = NativeComposerAttachmentChips(attachments: attachments,
            containerRadius: 29, onRemove: { _ in })
            .environment(\.colorScheme, scheme)
        let window = SwiftUIReplay.window(strip, width: 360, height: 140)
        defer { window.close() }
        let host = try #require(window.contentView)

        // Both previews decode independently in the background.
        try await SwiftUIReplay.wait(timeout: .seconds(8)) {
            containsColor(in: host, Self.isRed) && containsColor(in: host, Self.isBlue)
        }
    }

    @Test func importFilesBackfillsIndependentPreviewsForEachImage() async throws {
        let red = try solidPNG(width: 300, height: 200, NSColor(srgbRed: 0.9, green: 0.05, blue: 0.05, alpha: 1))
        let blue = try solidPNG(width: 200, height: 300, NSColor(srgbRed: 0.05, green: 0.05, blue: 0.9, alpha: 1))
        let draft = NativeComposerDraft(services: .init(stageFiles: { files, _ in
            files.enumerated().map { index, file in
                .init(id: JSONText("staged-\(index)"), path: JSONText("/attachments/\(file.name)"),
                    name: JSONText(file.name), mimeType: JSONText(file.mimeType), size: file.size,
                    kind: file.mimeType.hasPrefix("image/") ? .image : .file)
            }
        }, discardAttachments: { _ in }))
        await draft.importFiles([
            .init(data: red, name: "pasted-image.png", mimeType: "image/png"),
            .init(data: blue, name: "pasted-image.png", mimeType: "image/png")
        ])
        #expect(draft.attachments.count == 2)

        // Previews decode in the background and land independently.
        try await SwiftUIReplay.wait(timeout: .seconds(8)) {
            draft.attachments.allSatisfy { $0.preview != nil }
        }
        let first = try #require(draft.attachments[0].preview)
        let second = try #require(draft.attachments[1].preview)
        #expect(first != second)
        #expect(Set(draft.attachments.map(\.id)).count == 2)
        let firstColor = try centerColor(first.data)
        let secondColor = try centerColor(second.data)
        let firstRGB = try #require(firstColor)
        let secondRGB = try #require(secondColor)
        #expect(Self.isRed(firstRGB))
        #expect(Self.isBlue(secondRGB))
    }

    @Test(.requiresDisplay) func undecodableImageFallsBackToPlaceholderWithoutCrashing() async throws {
        let garbage = Data("not an image".utf8)
        #expect(await NativeComposerPreviewGenerator.make(
            .init(data: garbage, name: "broken.png", mimeType: "image/png")) == nil)
        #expect(await NativeComposerPreviewGenerator.make(
            .init(data: Data(), name: "empty.png", mimeType: "image/png")) == nil)

        let attachment = NativeComposerAttachment(id: "broken", name: "broken.png",
            status: .pending(size: garbage.count, mimeType: "image/png"))
        let window = SwiftUIReplay.window(NativeComposerAttachmentChips(
            attachments: [attachment], containerRadius: 29, onRemove: { _ in }), width: 320, height: 140)
        defer { window.close() }
        let host = try #require(window.contentView)
        #expect(!containsColor(in: host, Self.isRed))
    }

    @Test(.requiresDisplay) func readyImageWithUndecodablePathShowsFailureStateAfterDecode() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let corrupt = directory.appendingPathComponent("broken.png")
        try Data("definitely not an image".utf8).write(to: corrupt)

        let attachment = NativeComposerAttachment(id: "image", name: "broken.png",
            status: .ready(.init(id: "image", path: JSONText(corrupt.path), name: "broken.png",
                mimeType: "image/png", size: 1, kind: .image)))
        let window = SwiftUIReplay.window(NativeComposerAttachmentChips(
            attachments: [attachment], containerRadius: 29, onRemove: { _ in }), width: 320, height: 140)
        defer { window.close() }
        let host = try #require(window.contentView)

        // The managed-file decode is asynchronous. Wait for the failed state, then
        // assert the warning glyph / danger stroke actually appeared: a muted
        // salmon that the pure-red image matcher deliberately excludes. Grey
        // (still loading) has no red bias.
        try await SwiftUIReplay.wait(timeout: .seconds(8)) {
            containsColor(in: host, Self.isDangerTint)
        }
        #expect(!containsColor(in: host, Self.isRed))
    }

    @Test func attachmentEqualityIgnoresPreview() {
        let stored = NativeComposerStoredAttachment(id: "image", path: "/tmp/image.png",
            name: "image.png", mimeType: "image/png", size: 1, kind: .image)
        let without = NativeComposerAttachment(id: "image", name: "image.png", status: .ready(stored))
        let with = NativeComposerAttachment(id: "image", name: "image.png", status: .ready(stored),
            preview: NativeComposerPreview(data: Data("preview".utf8)))
        #expect(without == with)
        #expect(without.hashValue == with.hashValue)
        #expect(without != NativeComposerAttachment(id: "other", name: "image.png", status: .ready(stored)))
    }

    // MARK: - Preview racing a send

    /// The exact race from review: the user sends while staging has finished but
    /// the background preview decode has not. The decode fills `preview` during
    /// `await send`; the sent chip must still be cleared.
    @Test func previewLandingDuringSubmitStillClearsTheSentAttachment() async throws {
        let (draft, preview) = try await draftWithReadyPreviewlessImage(attachmentID: "staged")
        draft.text = "hello"
        #expect(draft.attachments.count == 1 && draft.attachments[0].preview == nil)

        var submissions: [NativeComposerSubmission] = []
        await draft.submit { submission in
            submissions.append(submission)
            // Simulate the decode finishing while the runtime admits the input.
            draft.fillPreview(preview, for: "staged")
            #expect(draft.attachments.first?.preview == preview)
        }

        #expect(submissions.count == 1)
        #expect(submissions[0].attachments.map(\.id) == ["staged"])
        #expect(draft.attachments.isEmpty)
        #expect(draft.text.isEmpty)

        // A follow-up send must not carry the image a second time.
        draft.text = "again"
        var second: NativeComposerSubmission?
        await draft.submit { second = $0 }
        #expect(second?.attachments.isEmpty == true)
    }

    @Test func previewLandingDuringClearStillRemovesTheAttachment() async throws {
        let (draft, preview) = try await draftWithReadyPreviewlessImage(attachmentID: "staged")
        #expect(draft.attachments.count == 1)

        await draft.clear {
            // A pending import can turn ready, or a preview can land, while the
            // clear awaits its receipt.
            draft.fillPreview(preview, for: "staged")
        }
        #expect(draft.attachments.isEmpty)
    }

    @Test func previewLandingAfterRemovalDoesNotResurrectTheAttachment() async throws {
        let (draft, preview) = try await draftWithReadyPreviewlessImage(attachmentID: "staged")
        await draft.removeAttachment("staged")
        #expect(draft.attachments.isEmpty)

        draft.fillPreview(preview, for: "staged")
        #expect(draft.attachments.isEmpty)
    }

    @Test func pendingToReadyReusesThePreviewDecodedDuringStaging() async throws {
        let png = try solidPNG(width: 120, height: 80, NSColor(srgbRed: 0.9, green: 0.05, blue: 0.05, alpha: 1))
        let ready = NativeComposerStoredAttachment(id: "staged", path: "/tmp/staged.png",
            name: "x.png", mimeType: "image/png", size: png.count, kind: .image)
        // The gate is sticky: staging may not have been entered yet when the
        // preview lands, so opening it must also work when the call arrives later.
        let staged = StagingGate()
        let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in
            await staged.suspend()
            return [ready]
        }, discardAttachments: { _ in }))

        let task = Task {
            await draft.importFiles([.init(data: png, name: "x.png", mimeType: "image/png")])
        }
        try await SwiftUIReplay.wait(timeout: .seconds(8)) { draft.attachments.first?.preview != nil }
        let preview = try #require(draft.attachments.first?.preview)
        #expect(draft.attachments[0].pending)

        staged.open()
        await task.value

        // Staging must carry the import-time preview across, not drop it and
        // re-decode the managed file.
        #expect(draft.attachments.count == 1)
        #expect(!draft.attachments[0].pending)
        #expect(draft.attachments[0].preview == preview)
    }

    // MARK: - Preview cache and surface switches

    @Test(.requiresDisplay, arguments: [ColorScheme.light, .dark])
    func remountingTheChipReusesCachedPixelsWithoutAPlaceholderFrame(scheme: ColorScheme) async throws {
        let red = try solidPNG(width: 300, height: 200, NSColor(srgbRed: 0.9, green: 0.05, blue: 0.05, alpha: 1))
        let preview = try #require(await NativeComposerPreviewGenerator.make(
            .init(data: red, name: "pasted-image.png", mimeType: "image/png")))
        let attachment = NativeComposerAttachment(id: "pending-image", name: "pasted-image.png",
            status: .pending(size: red.count, mimeType: "image/png"), preview: preview)
        let strip = NativeComposerAttachmentChips(attachments: [attachment],
            containerRadius: 29, onRemove: { _ in })
            .environment(\.colorScheme, scheme)

        let first = SwiftUIReplay.window(strip, width: 320, height: 140)
        let firstHost = try #require(first.contentView)
        try await SwiftUIReplay.wait(timeout: .seconds(8)) { containsColor(in: firstHost, Self.isRed) }
        first.close()

        // The Dock ↔ full-composer switch rebuilds the chip. The decode cache is
        // consulted while initializing its state, so the first frame has pixels.
        let second = SwiftUIReplay.window(strip, width: 320, height: 140)
        defer { second.close() }
        let secondHost = try #require(second.contentView)
        #expect(containsColor(in: secondHost, Self.isRed))
    }

    @Test func removingPendingAttachmentDuringStagingDoesNotResurrectOrSend() async throws {
        let png = try solidPNG(width: 4, height: 4, NSColor(srgbRed: 0.9, green: 0.05, blue: 0.05, alpha: 1))
        let ready = NativeComposerStoredAttachment(id: "staged", path: "/tmp/staged.png",
            name: "x.png", mimeType: "image/png", size: png.count, kind: .image)
        // Sticky gate: the pending chip may be observed before stageFiles runs,
        // yet opening early still releases the staging call when it arrives.
        let staged = StagingGate()
        var discarded: [JSONText] = []
        let draft = NativeComposerDraft(services: .init(stageFiles: { files, _ in
            await staged.suspend()
            return [ready]
        }, discardAttachments: { ids in discarded += ids }))

        let task = Task { await draft.importFiles([.init(data: png, name: "x.png", mimeType: "image/png")]) }
        try await SwiftUIReplay.wait { draft.attachments.count == 1 && draft.attachments[0].pending }
        // A pending attachment cannot be submitted.
        #expect(!draft.canSubmit)
        await draft.removeAttachment(draft.attachments[0].id)
        #expect(draft.attachments.isEmpty)

        staged.open()
        await task.value

        // The late-staged attachment must be discarded, never re-inserted.
        #expect(draft.attachments.isEmpty)
        #expect(discarded == ["staged"])
    }

    // MARK: - Helpers

    /// A draft holding one ready image that has not received its preview yet.
    /// `chooseFiles` adds stored attachments without starting a preview decode,
    /// which is exactly the state where a decode can land mid-send.
    private func draftWithReadyPreviewlessImage(attachmentID: JSONText) async throws
        -> (NativeComposerDraft, NativeComposerPreview) {
        let png = try solidPNG(width: 120, height: 80, NSColor(srgbRed: 0.9, green: 0.05, blue: 0.05, alpha: 1))
        let preview = try #require(await NativeComposerPreviewGenerator.make(
            .init(data: png, name: "x.png", mimeType: "image/png")))
        let ready = NativeComposerStoredAttachment(id: attachmentID,
            path: JSONText("/tmp/\(attachmentID.string).png"), name: "x.png",
            mimeType: "image/png", size: png.count, kind: .image)
        let draft = NativeComposerDraft(services: .init(
            chooseFiles: { _, _, _ in [ready] },
            stageFiles: { _, _ in [] },
            discardAttachments: { _ in }))
        await draft.chooseFiles(cwd: "/tmp")
        #expect(draft.attachments.count == 1)
        #expect(draft.attachments[0].preview == nil)
        return (draft, preview)
    }

    private func solidPNG(width: Int, height: Int, _ color: NSColor) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @discardableResult
    private func containsColor(in host: NSView, _ match: (NSColor) -> Bool) -> Bool {
        host.layoutSubtreeIfNeeded()
        host.window?.displayIfNeeded()
        guard let snapshot = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: snapshot)
        for y in 0..<snapshot.pixelsHigh {
            for x in 0..<snapshot.pixelsWide {
                if let color = snapshot.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), match(color) {
                    return true
                }
            }
        }
        return false
    }

    private func centerColor(_ data: Data) throws -> NSColor? {
        let rep = try #require(NSBitmapImageRep(data: data))
        return rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB)
    }

    private static func isRed(_ color: NSColor) -> Bool {
        color.redComponent > 0.75 && color.greenComponent < 0.3 && color.blueComponent < 0.3
    }

    /// The failed-decode warning glyph and stroke use the muted danger red at
    /// 0.5–0.7 opacity over the placeholder. After compositing it is a salmon
    /// with a clear red bias, unlike the neutral loading glyph and distinct from
    /// a real image's saturated red.
    private static func isDangerTint(_ color: NSColor) -> Bool {
        color.redComponent > 0.55
            && color.redComponent - color.greenComponent > 0.12
            && color.redComponent - color.blueComponent > 0.12
    }

    private static func isBlue(_ color: NSColor) -> Bool {
        color.blueComponent > 0.75 && color.redComponent < 0.3 && color.greenComponent < 0.3
    }
}

/// Test double for a staging call. `suspend()` and `open()` may happen in either
/// order: the `opened` flag is sticky and each side checks it under the same
/// lock while registering its continuation, so — unlike an optional
/// `CheckedContinuation?.resume()` — a release recorded before the call arrives
/// is not dropped and the import cannot hang forever.
private final class StagingGate: @unchecked Sendable {
    private let lock = NSLock()
    private var release: CheckedContinuation<Void, Never>?
    private var opened = false

    /// Holds the staging call until `open()`, or returns immediately if the
    /// gate was already opened.
    func suspend() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
            } else {
                release = continuation
                lock.unlock()
            }
        }
    }

    /// Releases this staging call or the next one to arrive.
    func open() {
        lock.lock()
        opened = true
        let continuation = release
        release = nil
        lock.unlock()
        continuation?.resume()
    }
}
