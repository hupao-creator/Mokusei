import AppKit
import Foundation
import MokuseiCore
import MokuseiPluginAPI

/// Capability injection for a particular draft/thread. The composer never owns
/// a general runtime client or chooses another thread's authority.
@MainActor
public struct NativeComposerServices {
    public typealias ChooseFiles = (JSONText, Int, PluginLifetime) async throws -> [NativeComposerStoredAttachment]
    public typealias StageFiles = ([NativeComposerFile], PluginLifetime) async throws -> [NativeComposerStoredAttachment]
    public typealias AttachmentPolicy = (PluginLifetime) async throws -> RuntimeAttachmentPolicy
    public typealias HostDirectory = (RuntimeHostFileReference?, PluginLifetime) async throws -> RuntimeHostDirectory
    public typealias PreviewAttachment = (NativeComposerStoredAttachment, PluginLifetime) async throws -> Data?
    public typealias OpenHostFile = (RuntimeHostFileReference, PluginLifetime) async throws -> Void
    public let chooseFiles: ChooseFiles
    public let stageFiles: StageFiles
    public let discardAttachments: ([JSONText]) async throws -> Void
    public let attachmentPolicy: AttachmentPolicy?
    public let hostDirectory: HostDirectory?
    public let previewAttachment: PreviewAttachment?
    public let openHostFile: OpenHostFile?

    public init(chooseFiles: ChooseFiles? = nil, stageFiles: @escaping StageFiles,
                attachmentPolicy: AttachmentPolicy? = nil, hostDirectory: HostDirectory? = nil,
                previewAttachment: PreviewAttachment? = nil, openHostFile: OpenHostFile? = nil,
                discardAttachments: @escaping ([JSONText]) async throws -> Void) {
        self.stageFiles = stageFiles
        self.attachmentPolicy = attachmentPolicy; self.hostDirectory = hostDirectory; self.previewAttachment = previewAttachment
        self.openHostFile = openHostFile
        self.discardAttachments = discardAttachments
        self.chooseFiles = chooseFiles ?? { cwd, limit, lifetime in
            try lifetime.checkCancellation()
            guard limit > 0 else { throw PluginContractError("附件数量不能超过 20 个") }
            // POSIX APIs cannot represent malformed UTF-16 paths. Reject at
            // this explicit native boundary instead of silently repairing one.
            guard Array(cwd.string.utf16) == cwd.codeUnits else {
                throw PluginContractError("The working directory cannot be represented as a native file path")
            }
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = true
            panel.resolvesAliases = true
            if !cwd.codeUnits.isEmpty { panel.directoryURL = URL(fileURLWithPath: cwd.string, isDirectory: true) }
            let cancellation = lifetime.onCancel { panel.cancel(nil) }
            defer { lifetime.removeHandler(cancellation) }
            let result = await withCheckedContinuation { continuation in
                if let window = NSApp.keyWindow {
                    panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
                } else {
                    panel.begin { continuation.resume(returning: $0) }
                }
            }
            try lifetime.checkCancellation()
            guard result == .OK else { return [] }
            guard panel.urls.count <= limit else { throw PluginContractError("附件数量不能超过 20 个") }
            return try await stageFiles(panel.urls.map(NativeComposerFile.init(url:)), lifetime)
        }
    }
}
