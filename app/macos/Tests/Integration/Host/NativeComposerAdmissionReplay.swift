import AppKit
import Foundation
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
import MokuseiPluginAPI
@testable import MokuseiPluginUI

@MainActor @Suite(.serializedNative, .serialized)
struct NativeComposerAdmissionReplay {
    @Test(arguments: [0, 19], [false, true])
    func excessTIFFNeverMakesPersistedDraftUnreadable(existingCount: Int, disposeDuringImport: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = NativeComposerDraftPersistence(storageDirectory: directory, scope: "admission")
        let policy = RuntimeAttachmentPolicy(imageBytes: 1_000_000, pdfBytes: 1_000_000,
            fileBytes: 1_000_000, messageBytes: 10_000_000, messageCount: 20)
        var suspended = false
        var response: CheckedContinuation<RuntimeAttachmentPolicy, Never>?
        var stageCalls = 0
        let services = NativeComposerServices(stageFiles: { files, _ in
            stageCalls += 1
            return files.map { .init(id: JSONText(UUID().uuidString), path: "/fixture", name: JSONText($0.name),
                mimeType: JSONText($0.mimeType), size: $0.size, kind: .file) }
        }, attachmentPolicy: { _ in
            if suspended { return await withCheckedContinuation { response = $0 } }
            return policy
        }, discardAttachments: { _ in })
        let draft = NativeComposerDraft(services: services, persistence: persistence)
        draft.text = "Keep this unsent text"
        if existingCount > 0 {
            await draft.importFiles(Array(repeating: .init(data: Data([1]), name: "existing", mimeType: "text/plain"), count: existingCount))
        }
        let beforeStages = stageCalls
        suspended = true
        let image = try tiff()
        let importing = Task { await draft.importFiles(Array(repeating: image, count: 21 - existingCount)) }
        for _ in 0..<200 where response == nil { try await Task.sleep(for: .milliseconds(5)) }
        defer { response?.resume(returning: policy) }
        #expect(response != nil)
        #expect(!draft.canSubmit)
        await draft.submit { _ in Issue.record("Preparing attachments must fence submission") }
        #expect(draft.attachments.count == existingCount)
        let stored = try RuntimeDraftStore(storageDirectory: directory, scope: "admission").load()
        #expect(stored?["attachments"]?.arrayValue?.count == existingCount)
        if disposeDuringImport { await draft.dispose() }
        response?.resume(returning: policy); response = nil
        await importing.value
        #expect(stageCalls == beforeStages)
        await draft.dispose()
        let reopened = NativeComposerDraft(services: services, persistence: persistence)
        #expect(reopened.text == "Keep this unsent text")
        #expect(reopened.attachments.count == existingCount && reopened.error == nil)
        await reopened.dispose()
    }

    @Test func invalidTIFFDoesNotConsumeTheLastAttachmentSlot() async throws {
        let draft = NativeComposerDraft(services: .init(stageFiles: { files, _ in
            files.map { .init(id: JSONText(UUID().uuidString), path: "/fixture", name: JSONText($0.name),
                mimeType: JSONText($0.mimeType), size: $0.size, kind: .file) }
        }, attachmentPolicy: { _ in
            .init(imageBytes: 1_000_000, pdfBytes: 1_000_000, fileBytes: 1_000_000,
                messageBytes: 10_000_000, messageCount: 20)
        }, discardAttachments: { _ in }))
        await draft.importFiles(Array(repeating: .init(data: Data([1]), name: "existing", mimeType: "text/plain"), count: 19))
        await draft.importFiles([.clipboard(tiff: Data([1, 2, 3])), try tiff()])
        #expect(draft.attachments.count == 20 && draft.error == nil)
        #expect(draft.attachments.allSatisfy { $0.attachment != nil })
        await draft.dispose()
    }

    @Test func successfulClearRetiresUnpublishedImport() async throws {
        var response: CheckedContinuation<RuntimeAttachmentPolicy, Never>?
        var stages = 0
        let policy = RuntimeAttachmentPolicy(imageBytes: 1_000_000, pdfBytes: 1_000_000,
            fileBytes: 1_000_000, messageBytes: 10_000_000, messageCount: 20)
        let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in
            stages += 1; return []
        }, attachmentPolicy: { _ in await withCheckedContinuation { response = $0 } }, discardAttachments: { _ in }))
        draft.text = "Clear this draft and its pending import"
        let image = try tiff()
        let importing = Task { await draft.importFiles([image]) }
        for _ in 0..<200 where response == nil { try await Task.sleep(for: .milliseconds(5)) }
        defer { response?.resume(returning: policy) }
        #expect(response != nil && !draft.canSubmit)
        await draft.clear {}
        response?.resume(returning: policy); response = nil
        await importing.value
        #expect(draft.text.isEmpty && draft.attachments.isEmpty && stages == 0)
        await draft.dispose()
    }

    @Test(arguments: [false, true])
    func clearConsumesItsImportEvenWhenImportFinishesFirst(useChooser: Bool) async throws {
        var imported: CheckedContinuation<[NativeComposerStoredAttachment], Error>?
        var cleared: CheckedContinuation<Void, Never>?
        var removed: Set<JSONText> = []
        let old = stored("old"), new = stored("new")
        var importCount = 0
        let load: () async throws -> [NativeComposerStoredAttachment] = {
            importCount += 1
            if importCount == 1 { return try await withCheckedThrowingContinuation { imported = $0 } }
            return [new]
        }
        let draft = NativeComposerDraft(services: .init(chooseFiles: { _, _, _ in try await load() },
            stageFiles: { _, _ in try await load() }, discardAttachments: { removed.formUnion($0) }))
        draft.text = "clear me"
        let importing = Task {
            if useChooser { await draft.chooseFiles(cwd: "/tmp") }
            else { await draft.importFiles([.init(data: Data([1]), name: "old", mimeType: "text/plain")]) }
        }
        defer { imported?.resume(throwing: CancellationError()); cleared?.resume() }
        try await wait { imported != nil }
        let clearing = Task { await draft.clear { await withCheckedContinuation { cleared = $0 } } }
        try await wait { cleared != nil }
        imported?.resume(returning: [old]); imported = nil
        await importing.value
        await draft.importFiles([.init(data: Data([2]), name: "new", mimeType: "text/plain")])
        draft.text = "keep later edits"
        cleared?.resume(); cleared = nil
        await clearing.value
        #expect(draft.text == "keep later edits")
        #expect(draft.attachments.compactMap(\.attachment).map(\.id) == [new.id])
        #expect(removed == [old.id])
        await draft.dispose()
    }

    @Test(arguments: [false, true], ["success", "import failure", "cleanup failure"])
    func retiredImportCannotChangeItsSuccessor(useChooser: Bool, outcome: String) async throws {
        var responses: [CheckedContinuation<[NativeComposerStoredAttachment], Error>] = []
        var removed: Set<JSONText> = []
        let load: () async throws -> [NativeComposerStoredAttachment] = {
            try await withCheckedThrowingContinuation { responses.append($0) }
        }
        let draft = NativeComposerDraft(services: .init(chooseFiles: { _, _, _ in try await load() },
            stageFiles: { _, _ in try await load() }, discardAttachments: {
                removed.formUnion($0)
                if outcome == "cleanup failure" { throw PluginContractError("obsolete cleanup failure") }
            }))
        let importing = Task {
            if useChooser { await draft.chooseFiles(cwd: "/tmp") }
            else { await draft.importFiles([.init(data: Data([1]), name: "old", mimeType: "text/plain")]) }
        }
        defer { for response in responses { response.resume(throwing: CancellationError()) } }
        try await wait { responses.count == 1 }
        await draft.clear {}
        #expect(!draft.importing && draft.attachments.isEmpty)
        draft.text = "new text"
        let successor = Task { await draft.chooseFiles(cwd: "/tmp") }
        try await wait { responses.count == 2 }
        let oldResponse = responses.removeFirst()
        if outcome == "import failure" { oldResponse.resume(throwing: PluginContractError("obsolete import failure")) }
        else { oldResponse.resume(returning: [stored("old")]) }
        await importing.value
        #expect(draft.importing && !draft.canSubmit && draft.error == nil)
        #expect(draft.attachments.isEmpty)
        responses.removeFirst().resume(returning: [stored("new")])
        await successor.value
        #expect(draft.canSubmit && !draft.importing)
        #expect(draft.attachments.compactMap(\.attachment).map(\.id) == ["new"])
        #expect(removed == (outcome == "import failure" ? [] : ["old"]))
        await draft.dispose()
    }

    @Test(arguments: ["unchanged", "edit before disposal", "edit after reopening"])
    func clearReceiptConsumesImportProgressAcrossReopening(edit: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = NativeComposerDraftPersistence(storageDirectory: directory, scope: "clear-reopen")
        let policy = RuntimeAttachmentPolicy(imageBytes: 1_000_000, pdfBytes: 1_000_000,
            fileBytes: 1_000_000, messageBytes: 10_000_000, messageCount: 20)
        var ready: CheckedContinuation<RuntimeAttachmentPolicy, Never>?
        var cleared: CheckedContinuation<Void, Never>?
        let services = NativeComposerServices(chooseFiles: { _, _, _ in [stored("new")] },
            stageFiles: { _, _ in [stored("old")] },
            attachmentPolicy: { _ in await withCheckedContinuation { ready = $0 } }, discardAttachments: { _ in })
        let draft = NativeComposerDraft(services: services, persistence: persistence)
        draft.text = "clear old text"
        let mentioned = NativeComposerDirectory(name: "project", path: "/project")
        draft.insertDirectory(mentioned)
        let importing = Task { await draft.importFiles([.init(data: Data([1]), name: "old", mimeType: "text/plain")]) }
        defer { ready?.resume(returning: policy); cleared?.resume() }
        try await wait { ready != nil }
        let clearing = Task { await draft.clear { await withCheckedContinuation { cleared = $0 } } }
        try await wait { cleared != nil }
        ready?.resume(returning: policy); ready = nil
        await importing.value
        if edit == "edit before disposal" {
            draft.text = "new local edit"
            draft.removeDirectory(mentioned.path)
            draft.insertDirectory(mentioned)
            await draft.chooseFiles(cwd: "/tmp")
        }
        await draft.dispose()
        let reopened = NativeComposerDraft(services: services, persistence: persistence)
        if edit == "edit after reopening" { reopened.text = "new owner edit" }
        cleared?.resume(); cleared = nil
        await clearing.value
        if edit == "edit after reopening" {
            #expect(reopened.text == "new owner edit" && reopened.attachments.count == 1)
        } else {
            #expect(reopened.text == (edit == "unchanged" ? "" : "new local edit"))
            #expect(reopened.attachments.compactMap(\.attachment).map(\.id) == (edit == "unchanged" ? [] : ["new"]))
            #expect(reopened.directories == (edit == "unchanged" ? [] : [mentioned]))
            #expect(reopened.error == nil)
        }
        await reopened.dispose()
        let restored = NativeComposerDraft(services: services, persistence: persistence)
        #expect(restored.text == reopened.text && restored.attachments == reopened.attachments && restored.error == nil)
        await restored.dispose()
    }

    @Test func failedClearKeepsItsImport() async throws {
        var response: CheckedContinuation<[NativeComposerStoredAttachment], Never>?
        let draft = NativeComposerDraft(services: .init(chooseFiles: { _, _, _ in
            await withCheckedContinuation { response = $0 }
        }, stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
        draft.text = "retain on clear failure"
        let importing = Task { await draft.chooseFiles(cwd: "/tmp") }
        defer { response?.resume(returning: []) }
        try await wait { response != nil }
        await draft.clear { throw PluginContractError("clear rejected") }
        #expect(draft.importing && !draft.canSubmit)
        response?.resume(returning: [stored("old")]); response = nil
        await importing.value
        #expect(draft.text == "retain on clear failure" && draft.attachments.count == 1)
        #expect(draft.error == "clear rejected")
        await draft.dispose()
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    private func stored(_ id: JSONText) -> NativeComposerStoredAttachment {
        .init(id: id, path: "/fixture", name: id, mimeType: "text/plain", size: 1, kind: .file)
    }

    private func tiff() throws -> NativeComposerFile {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(bitmap.bitmapData).initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        return .clipboard(tiff: try #require(bitmap.representation(using: .tiff, properties: [:])))
    }
}
