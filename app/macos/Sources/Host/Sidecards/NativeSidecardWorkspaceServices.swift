import Foundation
import MokuseiCore
import MokuseiPluginAPI

/// Runtime authority stays at composition. A workspace only receives commands
/// bound by its owner, and preserves the exact execution identity in each receipt.
@MainActor
public struct NativeSidecardWorkspaceServices {
    public let send: (JSONText, JSONValue) async throws -> SidecardSendReceipt
    public let stageAttachments: ([URL]) async throws -> [SidecardStagedAttachment]
    public let discardAttachments: ([JSONText]) async throws -> Void
    public let openExternal: (JSONText) async throws -> Void
    public let attachmentImport: SidecardAttachmentImport?
    public let voice: SidecardVoiceCapability?
    public let compose: (JSONText, JSONText) -> Void
    public let composer: (JSONText, SidecardComposerRequest?) -> Void

    public init(send: @escaping (JSONText, JSONValue) async throws -> SidecardSendReceipt,
                stageAttachments: @escaping ([URL]) async throws -> [SidecardStagedAttachment],
                discardAttachments: @escaping ([JSONText]) async throws -> Void,
                openExternal: @escaping (JSONText) async throws -> Void,
                voice: SidecardVoiceCapability? = nil, attachmentImport: SidecardAttachmentImport? = nil,
                compose: @escaping (JSONText, JSONText) -> Void = { _, _ in },
                composer: @escaping (JSONText, SidecardComposerRequest?) -> Void = { _, _ in }) {
        self.send = send; self.stageAttachments = stageAttachments
        self.discardAttachments = discardAttachments; self.openExternal = openExternal
        self.attachmentImport = attachmentImport
        self.voice = voice
        self.compose = compose
        self.composer = composer
    }
}
